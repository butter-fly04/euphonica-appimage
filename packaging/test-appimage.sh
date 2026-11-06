#!/usr/bin/env bash
# Smoke-test a Euphonica AppImage.
#
# The first half runs in a clean container (TEST_IMAGE, default Fedora 44;
# CI also uses ubuntu:26.04) and checks the bundled MPD and the ELF/data
# closure.
# The second half, when a Broadway display daemon is available on the host,
# starts the actual GUI headlessly for a few seconds.
#
# Usage: packaging/test-appimage.sh dist/Euphonica-*.AppImage
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${TEST_IMAGE:-quay.io/fedora/fedora:44}"
APPIMAGE="${1:-}"
[ -n "$APPIMAGE" ] && [ -f "$APPIMAGE" ] || {
  echo "usage: $0 <path-to-AppImage>" >&2
  exit 2
}

APPIMAGE="$(readlink -f "$APPIMAGE")"

echo "==> Clean-container checks (no GTK/Rust/MPD packages installed)"
podman run --rm \
  --network=host \
  --security-opt label=disable \
  -v "$APPIMAGE:/test.AppImage:ro,Z" \
  "$IMAGE" \
  /bin/bash -c '
    set -eu
    cd /tmp
    rm -rf squashfs-root
    /test.AppImage --appimage-extract >/dev/null

    # Match AppRun: bundled libraries live in usr/lib and usr/lib64.
    export LD_LIBRARY_PATH="$PWD/squashfs-root/usr/lib:$PWD/squashfs-root/usr/lib64"

    echo "--- mpd --version"
    ./squashfs-root/usr/bin/mpd --version

    echo "--- ELF closure"
    if ldd ./squashfs-root/usr/bin/euphonica 2>&1 | grep "not found"; then
      echo "missing libraries in euphonica" >&2
      exit 1
    fi
    if ldd ./squashfs-root/usr/bin/mpd 2>&1 | grep "not found"; then
      echo "missing libraries in mpd" >&2
      exit 1
    fi

    echo "--- relocated paths"
    grep -aq "/tmp/.euphonica-data" ./squashfs-root/usr/bin/euphonica
    grep -aq "/tmp/.euph-locale" ./squashfs-root/usr/bin/euphonica

    echo "--- bundled data"
    test -f ./squashfs-root/usr/share/euphonica/euphonica.gresource
    test -d ./squashfs-root/usr/share/euphonica/flags
    test -f ./squashfs-root/usr/share/glib-2.0/schemas/gschemas.compiled

    echo "--- bundled MPD startup"
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/music" "$tmp/playlists"
    cat > "$tmp/mpd.conf" <<EOF
music_directory "$tmp/music"
playlist_directory "$tmp/playlists"
db_file "$tmp/mpd.db"
state_file "$tmp/mpd.state"
sticker_file "$tmp/mpd_stickers.db"
bind_to_address "127.0.0.1"
port "16601"
log_level "error"
audio_output {
    type "null"
    name "test"
}
EOF
    ./squashfs-root/usr/bin/mpd --no-daemon "$tmp/mpd.conf" \
      >"$tmp/mpd.log" 2>&1 &
    mpd_pid=$!
    trap "kill \$mpd_pid 2>/dev/null || true; rm -rf \$tmp" EXIT
    connected=0
    for i in $(seq 1 50); do
      if bash -c "exec 3<>/dev/tcp/127.0.0.1/16601" 2>/dev/null; then
        connected=1
        break
      fi
      sleep 0.2
    done
    if [ "$connected" != 1 ]; then
      echo "MPD did not accept a TCP connection" >&2
      cat "$tmp/mpd.log" >&2
      exit 1
    fi
    exec 3<>/dev/tcp/127.0.0.1/16601
    IFS= read -r greeting <&3 || true
    printf "MPD greeting: %s\n" "$greeting"
    printf "status\nclose\n" >&3
    IFS= read -r status_line <&3 || true
    printf "MPD status: %s\n" "$status_line"
    exec 3>&-
    case "$greeting" in
      "OK MPD "*) ;;
      *) echo "unexpected MPD greeting" >&2; exit 1 ;;
    esac
  '

echo "==> Clean-container checks passed"

# ---------------------------------------------------------------------------
# Headless GUI smoke test (host side, using Broadway)
# ---------------------------------------------------------------------------
if command -v gtk4-broadwayd >/dev/null 2>&1 && \
   command -v dbus-run-session >/dev/null 2>&1; then
  echo "==> Headless GUI smoke test (Broadway)"
  LOG="$(mktemp)"
  dbus-run-session -- bash -c '
    set -u
    gtk4-broadwayd :97 >/tmp/euphonica-broadwayd.log 2>&1 &
    bw=$!
    trap "kill $bw 2>/dev/null || true" EXIT
    sleep 1
    export GDK_BACKEND=broadway BROADWAY_DISPLAY=:97
    export APPIMAGE_EXTRACT_AND_RUN=1
    timeout 12 "$1" --minimized
    rc=$?
    # 124 means the application stayed alive until the timeout.
    if [ "$rc" != 124 ]; then
      echo "GUI process exited with $rc" >&2
      exit 1
    fi
  ' _ "$APPIMAGE" >"$LOG" 2>&1 || {
    rc=$?
    echo "GUI smoke test failed" >&2
    cat "$LOG" >&2
    rm -f "$LOG"
    exit "$rc"
  }
  if grep -q "panicked at" "$LOG"; then
    echo "GUI smoke test found a panic" >&2
    cat "$LOG" >&2
    rm -f "$LOG"
    exit 1
  fi
  echo "GUI smoke test passed (ran for 12 s)"
  rm -f "$LOG"
else
  echo "==> Skipping GUI smoke test (gtk4-broadwayd or dbus-run-session missing)"
fi

echo "==> Self-test passed"
