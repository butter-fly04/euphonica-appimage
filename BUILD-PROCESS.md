# Euphonica AppImage — Complete Build Process (Fedora 44)

This document describes the final, verified build process for the Euphonica
AppImage, including the minimal MPD server that is bundled for Standalone Mode.
It covers the host driver, the Podman image, the Rust and MPD builds, path
relocation, the trimmed PipeWire client payload, packaging, and validation.

- **Application:** Euphonica 0.99.8 (Rust, GTK4/libadwaita MPD client)
- **Upstream commit:** `1372877f3640a5a21543f69e72109b985bfbc629`
- **Bundled MPD:** 0.24.15, built from source with a minimal feature set
- **Build target:** Fedora 44, x86_64
- **Artifact:** `dist/Euphonica-0.99.8-fedora44-x86_64.AppImage`
- **Size:** 42 MB (`43,473,400` bytes)
- **SHA-256:** `2a00d86648654a4a5083fb7363a8f446693a134ac1133d008af2873c49004ff1`
- **Compression:** SquashFS, zstd level 19
- **Host policy:** everything runs in rootless Podman; the host is not
  modified and no host packages are installed.

---

## 1. Repository layout

```
build.sh                     Host driver: checkout, image, container run
.github/workflows/build.yml  CI: resolve tag, build, test, release
packaging/
  Containerfile.fedora44     Self-contained Fedora 44 build image
  inner-build.sh             Rust + MPD build and AppDir assembly
  latest-tag.sh              Finds the newest upstream version tag
  bundle-libs.py             ELF dependency closure (without glibc/NSS)
  patch-config.py            Verifies relocated paths; patches desktop file
  AppRun                     Runtime environment and launcher
  test-appimage.sh           Clean-container checks + Broadway GUI smoke test
src/                         Euphonica checkout (created by build.sh)
tools/                       appimagetool-x86_64.AppImage and runtime-x86_64
work/fedora44/               Source copy, Cargo/Meson/MPD builds, AppDir
dist/                        Output AppImage
```

`src/`, `work/`, `tools/` and `dist/` are generated and git-ignored.

---

## 2. Prerequisites

- A host with rootless Podman
- Network access to Fedora mirrors, GitHub and crates.io
- Roughly 4–6 GB free for the build image, Rust target directory, MPD build
  tree and the output AppImage

The build image is self-contained and starts from `quay.io/fedora/fedora:44`.
No separately prepared Apostrophe image is required. `BASE_IMAGE` can still be
overridden to layer on an existing Fedora 44 image.

---

## 3. Reproducing the build

```bash
cd euphonica
./build.sh fedora44
```

Useful variants:

```bash
EUPHONICA_TAG=v0.99.8-beta-1 ./build.sh fedora44   # build a tagged release
BASE_IMAGE=localhost/apostrophe-build:fedora44 \
  ./build.sh fedora44                              # reuse a local base image
FORCE_IMAGE=1 ./build.sh fedora44                  # rebuild the Podman image
APPIMAGE_COMPRESS_LEVEL=22 ./build.sh fedora44     # slightly smaller/slower
packaging/test-appimage.sh dist/Euphonica-*-fedora44-x86_64.AppImage
```

The build is retry-friendly:

- the Meson build directory is reused with `meson setup --reconfigure`;
- `CARGO_HOME` is persisted at `work/fedora44/cargo-home`;
- the MPD build directory is reused;
- the MPD source tarball is cached under `work/fedora44/downloads/`;
- `appimagetool` and the AppImage runtime are cached under `tools/`.

---

## 4. Host-side driver (`build.sh`)

`build.sh` performs host orchestration only:

1. Selects Fedora 44 and image names.
2. Clones `https://github.com/htkhiem/euphonica.git` into `src/`, re-cloning
   when a requested `EUPHONICA_TAG` differs from the existing checkout.
3. Creates `work/fedora44/`, `dist/`, `tools/` and `work/fedora44/downloads/`.
4. Downloads `appimagetool` and the type-2 runtime into `tools/` when missing.
5. Copies the checkout to `work/fedora44/src` (without `.git`) so Meson's
   generated `config.rs` and Cargo's target directory never leak between runs.
6. Reuses `localhost/euphonica-build:fedora44` when present; rebuilds it from
   `packaging/Containerfile.fedora44` when `FORCE_IMAGE=1` or when missing.
7. Runs `packaging/inner-build.sh` with the repository mounted at `/work`.
8. Prints the artifacts in `dist/`.

---

## 5. Build image (`packaging/Containerfile.fedora44`)

```dockerfile
ARG BASE_IMAGE=quay.io/fedora/fedora:44
FROM ${BASE_IMAGE}
```

The image is self-contained so a fresh CI runner can build it without any
locally prepared base image. It installs the common GTK4/libadwaita/GLib build
stack plus Euphonica's dependencies:

| Package | Purpose |
|---|---|
| `rust`, `cargo` | Euphonica is Rust (edition 2024) |
| `clang-libs` | bindgen needs `libclang` for `pipewire-sys` / `libspa-sys` |
| `pipewire-devel` | PipeWire device enumeration and MPD PipeWire output |
| `alsa-lib-devel` | ALSA output/device enumeration |
| `libsecret-devel` | MPD password storage in the keyring |
| `openssl-devel` | reqwest/native-tls for metadata providers |
| `sqlite-devel` | library metadata cache and MPD stickers |
| `libwebp-devel` | album-art decoding |
| `flac-devel`, `libvorbis-devel`, `opus-devel`, `mpg123-devel` | MPD decoders |
| `libid3tag-devel` | MPD ID3 tag reader |
| `soxr-devel` | MPD soxr resampler |
| `zlib-devel` | MPD compressed database |

---

## 6. Build sequence inside the container (`inner-build.sh`)

Stages, in order:

1. `build_app`
2. `build_mpd`
3. `patch_paths`
4. `bundle_data`
5. `bundle_elf`
6. `install_metadata`
7. `make_appimage`

### 6.0 bindgen / libclang setup

`libspa-sys` and `pipewire-sys` use bindgen. In this image only `clang-libs` is
installed (no `clang` driver), so bindgen cannot always infer Fedora's clang
resource directory. The script locates the builtin headers and exports:

```bash
BINDGEN_EXTRA_CLANG_ARGS="-resource-dir <clang resource dir>"
```

This fixed two successive failures:

1. `Unable to find libclang` — resolved by installing `clang-libs`.
2. `fatal error: 'stdbool.h' file not found` — resolved by the resource-dir
   export above.

### 6.1 Build and install Euphonica (`build_app`)

Before Cargo runs, the disposable source copy's `src/meson.build` is modified
so Meson's generated `config.rs` contains fixed, relocatable paths:

```
PKGDATADIR = /tmp/.euphonica-data
LOCALEDIR  = /tmp/.euph-locale
```

The replacement is done at **compile time**, not by patching the linked binary.
This is important: rustc may fold parts of string literals into immediates, so
an in-place post-link replacement is not guaranteed to change the value the
program actually uses (an earlier build produced the corrupted path
`/tmp/.euphonica-nica` this way, even though `strings` showed the expected
text).

The script asserts that both replacements were applied.

Then:

```bash
meson setup --reconfigure "$BUILD" "$SRC" \
  --prefix=/usr --buildtype=release -Dprofile=default

ln -sfn "$WORK/cargo-home" "$BUILD/cargo-home"
ninja -C "$BUILD"
DESTDIR="$APPDIR" ninja -C "$BUILD" install
```

Meson tells Cargo to use `<builddir>/cargo-home`; the symlink redirects that to
the persistent `work/fedora44/cargo-home` so rebuilds do not download every
crate again.

### 6.2 Build a minimal MPD (`build_mpd`)

Euphonica's Standalone Mode spawns `mpd --no-daemon <config>` from `PATH`.
Instead of using Fedora's `mpd` package (which pulls FFmpeg, fluidsynth and
other large dependencies), MPD **0.24.15** is built from source.

- Source tarball: `v0.24.15.tar.gz`
- SHA-256:
  `448172fcd26aa6eb8bfe95c998cf7bd612ae6beaf5ba54f2cbf984d0249d3de4`
- The tarball is verified with `sha256sum -c` on every build.

Enabled features:

- decoders: FLAC, Vorbis, Opus, MP3 (`mpg123`)
- tag reader: `id3tag`
- resampler: SoXr
- outputs: PipeWire (default), ALSA, FIFO (spectrum analyser)
- storage: SQLite stickers/ratings, zlib-compressed database
- `database=true`, `inotify`, TCP

Disabled: FFmpeg, fluidsynth, MIDI, HTTP streams, UPnP, WebDAV, D-Bus,
systemd, curl, NFS, SMB, Qobuz, Bluetooth-related extras, and the rest of MPD's
optional surface.

**Syslog must stay enabled** (`-Dsyslog=enabled`). Euphonica's generated MPD
config has no `log_file`, and MPD's `log_init()` falls back to syslog in that
case. With syslog disabled, MPD aborts with:

```
exception: config parameter 'log_file' not found
```

The MPD build directory is reused with `meson setup --reconfigure`. After
install, man pages, docs, shell completions, systemd units and `/etc` are
removed; the `mpd` binary is stripped.

### 6.3 Relocatable paths (`patch_paths` / `patch-config.py`)

`patch-config.py`:

- verifies that the Euphonica binary contains `/tmp/.euphonica-data` and
  `/tmp/.euph-locale`; it fails the build if the Meson patch did not take
  effect;
- sets `DBusActivatable=false` in the installed desktop file;
- removes any installed D-Bus activation service files, since the AppImage is
  launched directly by `AppRun`.

### 6.4 GObject/GTK and PipeWire data (`bundle_data`)

Bundled:

- **GSettings schemas** — copied and recompiled with `glib-compile-schemas`.
- **Icons/themes** — Euphonica's own icons come from Meson; from the rest of
  hicolor only `index.theme` is added. `Adwaita` and `Adwaita-dark` are copied
  with their `cursors` subtrees removed.
- **GIO modules** — `libdconfsettings.so` if the image provides it. The final
  image does not ship dconf, so GLib transparently uses its keyfile backend;
  Euphonica settings were verified to persist under
  `~/.config/glib-2.0/settings/keyfile`.
- **PipeWire client configuration** (`/usr/share/pipewire`), trimmed:
  - only the `support` and `audioconvert` SPA plugin directories (plus
    `libspa.so`) are kept;
  - the `video.convert.*` factory mapping is removed from `client.conf`;
  - only the client modules referenced by `client.conf` are copied:
    `rt`, `protocol-native`, `client-node`, `client-device`, `adapter`,
    `metadata`, `session-manager`.

  This removes the server-side SPA plugins and, in particular,
  `filter-graph`, which pulled in `libfftw3f` (about 3 MB) even though
  Euphonica's client never needs it.
- **Translations** — only `euphonica.mo` files.

### 6.5 ELF closure and RPATHs (`bundle_elf`)

`bundle-libs.py` copies the recursive `ldd` closure of every ELF file in the
AppDir into `$APPDIR/usr/lib`. The blacklist keeps host-critical libraries out:

```
libc.*  libm.*  libpthread.*  libdl.*  librt.*  libresolv.*
libnss_*  libutil.*  libanl.*  libBrokenLocale.*  libmvec.*
ld-linux*  linux-vdso*  libc_malloc_debug
```

`set_rpaths` then applies `$ORIGIN`-relative RPATHs to dynamic executables and
shared objects outside `usr/lib`. Objects in the flat `usr/lib` directory are
skipped. Static-PIE files without `PT_INTERP` are skipped.

Notes on the final closure:

- `libgtk-4.so.1` directly links `libgstplay`, `libgstreamer`, `libgstvideo`,
  `libgstgl` and `libgstallocators`; these must stay.
- `libadwaita-1.so.0` links `libappstream.so.5`; it must stay.
- `libgdk_pixbuf-2.0.so.0` links `libglycin-2.so.0`; it must stay.

### 6.6 Metadata (`install_metadata`)

- Copies `io.github.htkhiem.Euphonica.desktop` to the AppDir root.
- Copies the SVG icon and rasterizes a 256×256 PNG with `rsvg-convert`
  (ImageMagick fallback).
- Creates `.DirIcon` as a symlink to the PNG.
- Installs `packaging/AppRun`.

### 6.7 AppImage packaging (`make_appimage`)

- Version is read from `meson.build`.
- Output: `Euphonica-0.99.8-fedora44-x86_64.AppImage`.
- The cached runtime is passed explicitly with an **absolute** path:

  ```bash
  appimagetool --runtime-file /abs/path/tools/runtime-x86_64 ...
  ```

  Relative paths make appimagetool fail with `no such file or directory`.
- Compression: zstd level 19.

---

## 7. Runtime design (`AppRun`)

`AppRun` resolves the mount from its own real path and exports:

- `PATH` with `$APPDIR/usr/bin` first, so Standalone Mode finds the bundled
  `mpd`
- `LD_LIBRARY_PATH` with `usr/lib` and `usr/lib64`
- `GSETTINGS_SCHEMA_DIR`
- `XDG_DATA_DIRS`
- `GIO_MODULE_DIR`
- `PIPEWIRE_CONFIG_DIR`, `SPA_PLUGIN_DIR`, `PIPEWIRE_MODULE_DIR` when the
  corresponding bundled directories exist

### 7.1 Fixed-path symlinks

The Rust binary's compile-time paths are:

```
/tmp/.euphonica-data  ->  $APPDIR/usr/share/euphonica
/tmp/.euph-locale     ->  $APPDIR/usr/share/locale
```

`AppRun` creates these with the shared `link_fixed` ownership guard: an
existing non-symlink or a link owned by another user aborts with a clear
message instead of redirecting the application to the wrong mount.

### 7.2 Launcher

```bash
exec "$APPDIR/usr/bin/euphonica" "$@"
```

Client mode works without MPD. Standalone Mode uses the bundled `mpd` through
`PATH`.

---

## 8. Testing

### 8.1 Clean-container checks

```bash
packaging/test-appimage.sh dist/Euphonica-*-fedora44-x86_64.AppImage
```

In a pristine `quay.io/fedora/fedora:44` container (no GTK/Rust/MPD packages),
the script extracts the AppImage and verifies:

- `mpd --version` shows the intended decoders, filters, tag plugins and outputs.
- `ldd` reports no unresolved libraries for `euphonica` or `mpd`, with
  `LD_LIBRARY_PATH` pointed at the extracted bundle.
- The relocated strings `/tmp/.euphonica-data` and `/tmp/.euph-locale` are
  present in the binary (`grep -a`; the base image has no `strings`).
- The GResource, flag SVGs and compiled schemas are present.
- The bundled MPD starts against a temporary config and answers a TCP
  `status` command with `OK MPD 0.24.0`.

The clean Fedora base has no `python3`, `strings`, `ps` or `gtk4-broadwayd`, so
the test avoids all of them and uses bash's `/dev/tcp` for the MPD check.

### 8.2 Headless GUI smoke test

When `gtk4-broadwayd` and `dbus-run-session` are available on the host, the
same script starts the real GUI under Broadway for 12 seconds and requires:

- the process to stay alive until the timeout (exit code 124);
- no `panicked at` line in the log.

It also passes `--minimized` so no window interaction is required.

A full onboarding run was additionally verified with fresh `XDG_CONFIG_HOME`,
`XDG_DATA_HOME` and `XDG_CACHE_HOME`: no panics, no PipeWire/SPA/module
errors, and settings persisted through GLib's keyfile backend.

### 8.3 Manual checks used during development

```bash
# MPD alone inside a clean container
./squashfs-root/usr/bin/mpd --version

# Relocated paths
grep -a /tmp/.euphonica-data ./squashfs-root/usr/bin/euphonica

# Full GUI under Broadway on the host
dbus-run-session -- bash -c '
  gtk4-broadwayd :97 &
  GDK_BACKEND=broadway BROADWAY_DISPLAY=:97 \
    APPIMAGE_EXTRACT_AND_RUN=1 ./dist/Euphonica-*.AppImage
'
```

---

## 9. What is bundled, and what is not

Bundled:

- Euphonica (Rust, release build with LTO and stripped symbols)
- GTK 4, libadwaita, GLib/GIO, Pango, Cairo and the rest of the ELF closure
- GStreamer libraries required by `libgtk-4.so.1`
- PipeWire client library, client config, `support`/`audioconvert` SPA plugins,
  and the seven client modules named by `client.conf`
- libsecret, OpenSSL, SQLite, libwebp, ALSA
- Minimal MPD 0.24.15 (FLAC/Vorbis/Opus/MP3, ID3, SoXr, PipeWire/ALSA/FIFO,
  SQLite stickers, zlib)
- GSettings schemas, Adwaita icons, flags and translations

Not bundled:

- glibc, the ELF loader, NSS libraries (host-provided)
- the PipeWire server and its server-side SPA plugins
- FFmpeg, fluidsynth, MIDI, HTTP/WebDAV, UPnP, D-Bus and systemd support for MPD
- Mesa/Vulkan graphics drivers (host-provided)

---

## 10. Problems encountered and how the final build solves them

1. **bindgen could not find libclang** — install `clang-libs`.
2. **bindgen could not find `stdbool.h`** — export
   `BINDGEN_EXTRA_CLANG_ARGS=-resource-dir ...`.
3. **Post-link Rust path patching corrupted strings** — rustc folded part of
   the literal into immediates, producing `/tmp/.euphonica-nica`. The final
   build patches Meson's `PKGDATADIR`/`LOCALEDIR` before Cargo runs.
4. **MPD aborted with `config parameter 'log_file' not found`** — keep
   `-Dsyslog=enabled`; Euphonica does not generate a `log_file`.
5. **Fedora's `mpd` package pulled large audio/media stacks** — build a minimal
   MPD from a pinned source tarball instead.
6. **SPA `filter-graph` pulled in `libfftw3f` (~3 MB)** — keep only the
   `support` and `audioconvert` plugin directories and only the modules named
   by `client.conf`.
7. **appimagetool tried to download the runtime at the end of every build and
   failed** — cache `runtime-x86_64` and pass `--runtime-file` with an absolute
   path.
8. **No dconf package in the build image** — GLib falls back to its keyfile
   backend; settings were verified to persist. This is harmless for a portable
   AppImage and avoids depending on a host dconf service.
9. **Clean Fedora base lacks `python3`, `strings`, `ps`, `gtk4-broadwayd`** —
   the test uses `grep -a`, bash `/dev/tcp`, and an optional host-side Broadway
   test.

---

## 11. Final artifact

```
dist/Euphonica-0.99.8-fedora44-x86_64.AppImage
Size:    43,473,400 bytes (about 42 MB)
SHA-256: 2a00d86648654a4a5083fb7363a8f446693a134ac1133d008af2873c49004ff1
Format:  AppImage type 2, SquashFS + zstd level 19
```

Verified on Fedora 44:

- clean-container checks (MPD startup, ELF closure, relocated paths, bundled
  data) pass;
- the real GUI starts headlessly under Broadway and runs for 12 seconds without
  panics;
- the full onboarding flow runs with fresh XDG directories without errors.
