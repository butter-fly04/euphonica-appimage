#!/usr/bin/env bash
# Host-side driver. All builds happen in a rootless Podman container.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO="${1:-fedora44}"
EUPHONICA_TAG="${EUPHONICA_TAG:-}"
BASE_IMAGE="${BASE_IMAGE:-quay.io/fedora/fedora:44}"

case "$DISTRO" in
  fedora44)
    BUILD_IMAGE="${BUILD_IMAGE:-localhost/euphonica-build:fedora44}"
    CONTAINERFILE="$ROOT/packaging/Containerfile.fedora44"
    ;;
  *)
    echo "usage: $0 [fedora44]" >&2
    exit 2
    ;;
esac

SRC="$ROOT/src"
WORK="$ROOT/work/$DISTRO"
SRCCOPY="$WORK/src"
OUT="$ROOT/dist"
TOOLS="$ROOT/tools"

# ---------------------------------------------------------------------------
# Source checkout
# ---------------------------------------------------------------------------
current=""
if [ -d "$SRC/.git" ]; then
  current="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
elif [ -e "$SRC" ]; then
  echo "==> Removing non-git source directory $SRC"
  rm -rf "$SRC"
fi

if [ -d "$SRC/.git" ] && [ -n "$EUPHONICA_TAG" ] && [ "$current" != "$EUPHONICA_TAG" ]; then
  echo "==> Existing checkout is ${current:-not an exact tag}; re-cloning $EUPHONICA_TAG"
  rm -rf "$SRC"
fi

if [ ! -d "$SRC/.git" ]; then
  echo "==> Cloning Euphonica ${EUPHONICA_TAG:-default branch}"
  if [ -n "$EUPHONICA_TAG" ]; then
    git clone --depth 1 --branch "$EUPHONICA_TAG" \
      https://github.com/htkhiem/euphonica.git "$SRC"
  else
    git clone --depth 1 \
      https://github.com/htkhiem/euphonica.git "$SRC"
  fi
else
  echo "==> Reusing existing checkout at $SRC (${current:-not an exact tag})"
fi

mkdir -p "$WORK" "$OUT" "$TOOLS" "$WORK/downloads"

# ---------------------------------------------------------------------------
# AppImage tooling
# ---------------------------------------------------------------------------
TOOL="$TOOLS/appimagetool-x86_64.AppImage"
if [ ! -s "$TOOL" ]; then
  echo "==> Downloading appimagetool"
  curl -fL --retry 3 -o "$TOOL" \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
  chmod +x "$TOOL"
fi

# Keep the type-2 runtime next to appimagetool. Without --runtime-file,
# appimagetool downloads it on every packaging run, which makes the build
# depend on GitHub availability at the very end.
RUNTIME="$TOOLS/runtime-x86_64"
if [ ! -s "$RUNTIME" ]; then
  echo "==> Downloading AppImage runtime"
  curl -fL --retry 5 --retry-delay 3 -o "$RUNTIME" \
    "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64"
  chmod +x "$RUNTIME"
fi

# Keep the pristine checkout; build from a disposable copy so Meson's generated
# config.rs and Cargo's target directory never leak between runs.
rm -rf "$SRCCOPY"
cp -a "$SRC" "$SRCCOPY"
rm -rf "$SRCCOPY/.git"

# ---------------------------------------------------------------------------
# Build image
# ---------------------------------------------------------------------------
if [ "${FORCE_IMAGE:-0}" != "1" ] && podman image exists "$BUILD_IMAGE"; then
  echo "==> Reusing build image $BUILD_IMAGE (FORCE_IMAGE=1 to rebuild)"
else
  echo "==> Creating build image $BUILD_IMAGE from $BASE_IMAGE"
  podman build --network=host \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    -t "$BUILD_IMAGE" -f "$CONTAINERFILE" "$ROOT/packaging"
fi

# ---------------------------------------------------------------------------
# Container build
# ---------------------------------------------------------------------------
echo "==> Building in $BUILD_IMAGE"
podman run --rm \
  --network=host \
  --security-opt label=disable \
  -v "$ROOT:/work:Z" \
  -e DISTRO="$DISTRO" \
  -e NAME="$DISTRO" \
  -e SRC="/work/work/$DISTRO/src" \
  -e WORK="/work/work/$DISTRO" \
  -e OUT="/work/dist" \
  -e PACKAGING="/work/packaging" \
  -e TOOLS="/work/tools" \
  "$BUILD_IMAGE" \
  /bin/bash "/work/packaging/inner-build.sh"

echo "==> Done. Artifacts:"
ls -lh "$OUT"
