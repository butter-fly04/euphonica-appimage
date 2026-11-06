#!/usr/bin/env bash
# Runs inside the Fedora build container.  Builds Euphonica and a minimal MPD,
# assembles a relocatable AppDir, bundles the runtime closure and produces an
# AppImage.
set -euo pipefail

: "${DISTRO:?}"
: "${NAME:?}"
: "${SRC:?}"
: "${WORK:?}"
: "${OUT:?}"
: "${PACKAGING:?}"
: "${TOOLS:?}"

export LC_ALL=C.UTF-8
export APPIMAGE_EXTRACT_AND_RUN=1
export CARGO_NET_RETRY=10

# bindgen (used by pipewire-sys/libspa-sys) links libclang, which does not
# always infer Fedora's clang resource directory when no clang driver binary is
# installed.  Point it at the builtin C headers explicitly.
clang_hdr="$(find /usr/lib/clang -path '*/include/stdbool.h' -print -quit 2>/dev/null || true)"
if [ -n "$clang_hdr" ]; then
  export BINDGEN_EXTRA_CLANG_ARGS="-resource-dir $(dirname "$(dirname "$clang_hdr")")"
fi

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning: %s\033[0m\n' "$*" >&2; }

APPDIR="$WORK/AppDir"
BUILD="$WORK/build"
MPD_VERSION="0.24.15"
MPD_TARBALL="$WORK/downloads/mpd-$MPD_VERSION.tar.gz"
MPD_SRC="$WORK/mpd-src"
MPD_BUILD="$WORK/mpd-build"
MPD_SHA256="448172fcd26aa6eb8bfe95c998cf7bd612ae6beaf5ba54f2cbf984d0249d3de4"

copy_tree() {
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  cp -a "$src"/. "$dst"/
}

find_tool() {
  local name
  for name in "$@"; do
    if command -v "$name" >/dev/null 2>&1; then
      command -v "$name"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Build and install Euphonica
# ---------------------------------------------------------------------------
build_app() {
  log "Configuring Euphonica"
  rm -rf "$APPDIR"
  mkdir -p "$APPDIR" "$WORK/cargo-home"

  # Relocate the two compile-time paths used by the Rust code.  Doing this
  # before Cargo runs is much safer than patching the linked binary: rustc may
  # fold parts of a string literal into immediates, so an in-place replacement
  # of the finished binary is not guaranteed to change the value the program
  # actually uses.
  python3 - "$SRC/src/meson.build" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace(
    "conf.set_quoted('LOCALEDIR', get_option('prefix') / get_option('localedir'))",
    "conf.set_quoted('LOCALEDIR', '/tmp/.euph-locale')",
)
text = text.replace(
    "conf.set_quoted('PKGDATADIR', pkgdatadir)",
    "conf.set_quoted('PKGDATADIR', '/tmp/.euphonica-data')",
)
assert "'/tmp/.euphonica-data'" in text, "PKGDATADIR replacement failed"
assert "'/tmp/.euph-locale'" in text, "LOCALEDIR replacement failed"
path.write_text(text, encoding="utf-8")
PY

  if [ -d "$BUILD" ]; then
    meson setup --reconfigure "$BUILD" "$SRC" \
      --prefix=/usr \
      --buildtype=release \
      -Dprofile=default
  else
    meson setup "$BUILD" "$SRC" \
      --prefix=/usr \
      --buildtype=release \
      -Dprofile=default
  fi

  # Meson tells Cargo to use <builddir>/cargo-home.  Redirect that to a
  # persistent directory so a rebuild does not download every crate again.
  rm -rf "$BUILD/cargo-home"
  ln -sfn "$WORK/cargo-home" "$BUILD/cargo-home"

  log "Compiling Euphonica"
  ninja -C "$BUILD"

  log "Installing Euphonica into AppDir"
  DESTDIR="$APPDIR" ninja -C "$BUILD" install
}

# ---------------------------------------------------------------------------
# Build a minimal MPD for Standalone Mode
# ---------------------------------------------------------------------------
fetch_mpd() {
  if [ ! -s "$MPD_TARBALL" ]; then
    log "Downloading MPD $MPD_VERSION"
    mkdir -p "$(dirname "$MPD_TARBALL")"
    curl -fL --retry 3 -o "$MPD_TARBALL" \
      "https://github.com/MusicPlayerDaemon/MPD/archive/refs/tags/v$MPD_VERSION.tar.gz"
  fi
  echo "$MPD_SHA256  $MPD_TARBALL" | sha256sum -c -

  if [ ! -f "$MPD_SRC/meson.build" ]; then
    log "Extracting MPD $MPD_VERSION"
    rm -rf "$MPD_SRC" "$WORK/MPD-$MPD_VERSION"
    tar -xzf "$MPD_TARBALL" -C "$WORK"
    mv "$WORK/MPD-$MPD_VERSION" "$MPD_SRC"
  fi
}

build_mpd() {
  fetch_mpd
  log "Configuring minimal MPD"

  # Only the pieces Euphonica actually uses are enabled:
  #   decoders: FLAC, Vorbis, Opus, MP3
  #   tag:      ID3
  #   resampler: SoXr
  #   outputs:  PipeWire (default), ALSA, FIFO (spectrum analyser)
  #   storage:  SQLite (stickers/ratings), zlib
  # Everything else (FFmpeg, fluidSynth, wildmidi, HTTP streams, UPnP,
  # WebDAV, D-Bus, systemd, ...) is disabled to keep the closure small.
  #
  # Keep syslog enabled: MPD's log_init() falls back to syslog when no
  # log_file is configured (Euphonica does not generate one).  Without it
  # MPD aborts with "config parameter 'log_file' not found".
  local -a mpd_opts=(
    --prefix=/usr --buildtype=release
    -Ddocumentation=disabled -Dmanpages=false -Dhtml_manual=false -Ddoxygen=false
    -Dsyslog=enabled -Dio_uring=disabled -Ddaemon=false -Dsystemd=disabled
    -Dtest=false -Dfuzzer=false
    -Ddatabase=true -Dupnp=disabled -Dlibmpdclient=disabled -Dneighbor=false
    -Dudisks=disabled -Dwebdav=disabled
    -Dcdio_paranoia=disabled -Dcurl=disabled -Dmms=disabled -Dnfs=disabled
    -Dsmbclient=disabled -Dqobuz=disabled
    -Dbzip2=disabled -Diso9660=disabled -Dzzip=disabled
    -Did3tag=enabled -Dchromaprint=disabled
    -Dadplug=disabled -Daudiofile=disabled -Dfaad=disabled -Dffmpeg=disabled
    -Dflac=enabled -Dfluidsynth=disabled -Dgme=disabled -Dmad=disabled
    -Dmikmod=disabled -Dmodplug=disabled -Dopenmpt=disabled -Dmpcdec=disabled
    -Dmpg123=enabled -Dopus=enabled -Dsidplay=disabled -Dsndfile=disabled
    -Dtremor=disabled -Dvorbis=enabled -Dwavpack=disabled -Dwildmidi=disabled
    -Dvorbisenc=disabled -Dlame=disabled -Dtwolame=disabled -Dshine=disabled
    -Dwave_encoder=true
    -Dlibsamplerate=disabled -Dsoxr=enabled
    -Dalsa=enabled -Dao=disabled -Dfifo=true -Dhttpd=false -Djack=disabled
    -Dopenal=disabled -Doss=disabled -Dpipe=false -Dpipewire=enabled
    -Dpulse=disabled -Drecorder=false -Dshout=disabled -Dsnapcast=false
    -Dsndio=disabled -Dsolaris_output=disabled
    -Ddbus=disabled -Dexpat=disabled -Dicu=disabled -Diconv=disabled
    -Dnlohmann_json=disabled -Dpcre=disabled -Dsqlite=enabled -Dzlib=enabled
    -Dzeroconf=disabled -Dipv6=disabled
  )

  if [ -d "$MPD_BUILD" ]; then
    meson setup --reconfigure "$MPD_BUILD" "$MPD_SRC" "${mpd_opts[@]}"
  else
    meson setup "$MPD_BUILD" "$MPD_SRC" "${mpd_opts[@]}"
  fi

  log "Compiling MPD"
  ninja -C "$MPD_BUILD"

  log "Installing MPD into AppDir"
  DESTDIR="$APPDIR" ninja -C "$MPD_BUILD" install

  # Keep only the server binary.  Man pages, systemd units and completions are
  # not used by an AppImage.
  rm -rf "$APPDIR/usr/share/man" \
         "$APPDIR/usr/share/doc" \
         "$APPDIR/usr/share/zsh" \
         "$APPDIR/usr/share/bash-completion" \
         "$APPDIR/usr/lib/systemd" \
         "$APPDIR/usr/share/systemd" \
         "$APPDIR/etc"

  if [ -f "$APPDIR/usr/bin/mpd" ]; then
    strip --strip-unneeded "$APPDIR/usr/bin/mpd" || true
  else
    echo "error: MPD was not installed" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Relocatable compile-time paths
# ---------------------------------------------------------------------------
patch_paths() {
  log "Making installed paths relocatable"
  python3 "$PACKAGING/patch-config.py" "$APPDIR"

  # The AppImage is not D-Bus activated from /usr/share/dbus-1/services.
  find "$APPDIR/usr/share/dbus-1/services" -type f -delete 2>/dev/null || true
  rmdir "$APPDIR/usr/share/dbus-1/services" 2>/dev/null || true
  rmdir "$APPDIR/usr/share/dbus-1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# GObject data: schemas, icons, GIO modules, PipeWire configuration
# ---------------------------------------------------------------------------
bundle_data() {
  log "Bundling GSettings schemas"
  copy_tree /usr/share/glib-2.0/schemas "$APPDIR/usr/share/glib-2.0/schemas"
  glib-compile-schemas --targetdir="$APPDIR/usr/share/glib-2.0/schemas" \
    "$APPDIR/usr/share/glib-2.0/schemas"

  log "Bundling icons and themes"
  # Euphonica's own icons were installed by Meson.  Only the index is needed
  # from the rest of hicolor.
  install -Dm644 /usr/share/icons/hicolor/index.theme \
    "$APPDIR/usr/share/icons/hicolor/index.theme"
  copy_tree /usr/share/icons/Adwaita "$APPDIR/usr/share/icons/Adwaita"
  copy_tree /usr/share/icons/Adwaita-dark "$APPDIR/usr/share/icons/Adwaita-dark"
  rm -rf "$APPDIR/usr/share/icons/Adwaita/cursors" \
         "$APPDIR/usr/share/icons/Adwaita-dark/cursors"

  log "Bundling GIO modules"
  install -d "$APPDIR/usr/lib64/gio/modules"
  if [ -f /usr/lib64/gio/modules/libdconfsettings.so ]; then
    cp -a /usr/lib64/gio/modules/libdconfsettings.so \
      "$APPDIR/usr/lib64/gio/modules/"
  else
    warn "GIO module libdconfsettings.so not found"
  fi
  # No giomodule.cache: it is generated at runtime by GLib's directory scan,
  # which keeps absolute build paths out of the bundle.

  log "Bundling PipeWire client configuration"
  # libpipewire loads client.conf from its compiled-in config directory and
  # SPA plugins/modules from libdir/spa-0.2 and libdir/pipewire-0.3.  Ship only
  # the client-side pieces (the server and its ALSA/Bluetooth plugins belong to
  # the host) and point the environment at them from AppRun.
  copy_tree /usr/share/pipewire "$APPDIR/usr/share/pipewire"
  copy_tree /usr/lib64/spa-0.2 "$APPDIR/usr/lib64/spa-0.2"

  # The bundled client only needs audio; drop the videoconvert factory mapping
  # so a video conversion request cannot reference a plugin we removed.
  if [ -f "$APPDIR/usr/share/pipewire/client.conf" ]; then
    sed -i '/^[[:space:]]*video\.convert\.\*/d' \
      "$APPDIR/usr/share/pipewire/client.conf"
  fi

  # client.conf's context.spa-libs needs only these two factories.  Dropping
  # the server-side plugins avoids pulling in fftw, Bluetooth, V4L2, ...
  find "$APPDIR/usr/lib64/spa-0.2" -mindepth 1 -maxdepth 1 -type d \
    ! -name support ! -name audioconvert -exec rm -rf {} +

  # Modules named by the bundled client.conf.  libpipewire-module-rt is
  # optional (ifexists/nofail); the rest are needed to connect and stream.
  install -d "$APPDIR/usr/lib64/pipewire-0.3"
  local mod
  for mod in \
      libpipewire-module-rt \
      libpipewire-module-protocol-native \
      libpipewire-module-client-node \
      libpipewire-module-client-device \
      libpipewire-module-adapter \
      libpipewire-module-metadata \
      libpipewire-module-session-manager; do
    if [ -f "/usr/lib64/pipewire-0.3/$mod.so" ]; then
      cp -a "/usr/lib64/pipewire-0.3/$mod.so" "$APPDIR/usr/lib64/pipewire-0.3/"
    else
      warn "PipeWire module $mod not found"
    fi
  done

  log "Bundling Euphonica translations"
  if [ -d /usr/share/locale ]; then
    local f rel
    while IFS= read -r -d '' f; do
      rel="${f#/usr/share/locale/}"
      install -Dm644 "$f" "$APPDIR/usr/share/locale/$rel"
    done < <(find /usr/share/locale -path '*/LC_MESSAGES/euphonica.mo' -print0)
  fi
}

# ---------------------------------------------------------------------------
# ELF closure and RPATHs
# ---------------------------------------------------------------------------
set_rpaths() {
  log "Setting relocatable RPATHs"
  local f dir rel_lib rel_lib64 is_so
  while IFS= read -r -d '' f; do
    case "$f" in
      "$APPDIR"/usr/lib/*) continue ;;
    esac
    if ! readelf -d "$f" 2>/dev/null | grep -q 'NEEDED'; then
      continue
    fi
    is_so=0
    case "$f" in
      *.so|*.so.*) is_so=1 ;;
    esac
    if [ "$is_so" = 0 ] && \
       ! readelf -l "$f" 2>/dev/null | grep -q 'INTERP'; then
      continue
    fi
    dir="$(dirname "$f")"
    rel_lib="$(realpath --relative-to="$dir" "$APPDIR/usr/lib")"
    rel_lib64="$(realpath --relative-to="$dir" "$APPDIR/usr/lib64")"
    patchelf --set-rpath "\$ORIGIN/$rel_lib:\$ORIGIN/$rel_lib64" "$f" \
      || warn "could not set RPATH on $f"
  done < <(find "$APPDIR/usr/bin" "$APPDIR/usr/libexec" \
                "$APPDIR/usr/lib64" \
                -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) \
                -print0 2>/dev/null)
}

bundle_elf() {
  log "Bundling ELF dependency closure"
  python3 "$PACKAGING/bundle-libs.py" "$APPDIR"
  set_rpaths
}

# ---------------------------------------------------------------------------
# AppImage metadata and packaging
# ---------------------------------------------------------------------------
install_metadata() {
  log "Preparing AppImage metadata"
  local desktop icon png
  desktop="$APPDIR/usr/share/applications/io.github.htkhiem.Euphonica.desktop"
  icon="$APPDIR/usr/share/icons/hicolor/scalable/apps/io.github.htkhiem.Euphonica.svg"

  if [ -f "$desktop" ]; then
    cp "$desktop" "$APPDIR/"
  else
    warn "no desktop file installed"
  fi

  if [ -f "$icon" ]; then
    cp "$icon" "$APPDIR/io.github.htkhiem.Euphonica.svg"
    png="io.github.htkhiem.Euphonica.png"
    if command -v rsvg-convert >/dev/null 2>&1; then
      rsvg-convert -w 256 -h 256 "$icon" -o "$APPDIR/$png"
    elif command -v convert >/dev/null 2>&1; then
      convert -background none "$icon" -resize 256x256 "$APPDIR/$png"
    else
      warn "no SVG-to-PNG converter; .DirIcon will be SVG"
      png="io.github.htkhiem.Euphonica.svg"
    fi
    ln -sfn "$png" "$APPDIR/.DirIcon"
  else
    warn "application icon not found"
  fi

  install -Dm755 "$PACKAGING/AppRun" "$APPDIR/AppRun"
}

fetch_appimagetool() {
  local tool="$TOOLS/appimagetool-x86_64.AppImage"
  if [ ! -s "$tool" ]; then
    log "Downloading appimagetool" >&2
    curl -fL --retry 3 -o "$tool" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$tool"
  fi
  printf '%s\n' "$tool"
}

make_appimage() {
  log "Building AppImage"
  local version tool outfile comp
  local -a squashfs_args runtime_args
  version="$(grep -m1 -E "^[[:space:]]*version[[:space:]]*:" "$SRC/meson.build" \
    | sed -E "s/.*version[[:space:]]*:[[:space:]]*'([^']+)'.*/\1/")"
  [ -n "$version" ] || version="unknown"
  tool="$(fetch_appimagetool)"
  outfile="$OUT/Euphonica-${version}-${NAME}-x86_64.AppImage"

  runtime_args=()
  if [ -s "$TOOLS/runtime-x86_64" ]; then
    runtime_args+=(--runtime-file "$TOOLS/runtime-x86_64")
  else
    warn "no cached AppImage runtime; appimagetool will try to download it"
  fi

  comp="${APPIMAGE_COMPRESS:-zstd}"
  squashfs_args=()
  if [ "$comp" = "zstd" ]; then
    squashfs_args+=(--comp zstd
      --mksquashfs-opt=-Xcompression-level
      --mksquashfs-opt="${APPIMAGE_COMPRESS_LEVEL:-19}")
  else
    squashfs_args+=(--comp "$comp")
  fi

  rm -f "$outfile"
  ARCH=x86_64 "$tool" "${runtime_args[@]}" "${squashfs_args[@]}" \
    "$APPDIR" "$outfile"
  chmod +x "$outfile"
  echo "$outfile"
}

build_app
build_mpd
patch_paths
bundle_data
bundle_elf
install_metadata
make_appimage

log "Build complete"
