# Euphonica AppImage (Fedora 44)

Self-contained AppImage build of [Euphonica](https://github.com/htkhiem/euphonica),
a GTK4/libadwaita MPD client.

The build runs entirely in rootless Podman.  The host is never modified and no
host packages are installed.

See [BUILD-PROCESS.md](BUILD-PROCESS.md) for the complete end-to-end build
recipe, including the minimal MPD build and the path-relocation strategy.

## Build

```sh
./build.sh fedora44
```

The build image is self-contained and starts from `quay.io/fedora/fedora:44`.
Set `BASE_IMAGE` to reuse another Fedora 44 image (for example a local build
base), and `EUPHONICA_TAG` to build a tagged upstream release instead of the
default branch:

```sh
EUPHONICA_TAG=v0.99.8-beta-1 ./build.sh fedora44
```

The MPD source tarball and the `CARGO_HOME` registry are kept under
`work/fedora44/`, so rebuilding does not download them again.  Set
`FORCE_IMAGE=1` to rebuild the dependency image.

The result is written to:

```
dist/Euphonica-0.99.8-fedora44-x86_64.AppImage
```

## GitHub Actions

`.github/workflows/build.yml` runs on every push to `main`, weekly on a
schedule, and on demand. It resolves the newest Euphonica tag, builds and
smoke-tests the AppImage in rootless Podman, and publishes the AppImage plus
its SHA-256 as a GitHub release tagged with the upstream tag. Scheduled runs
skip tags that already have a release. The Cargo registry and MPD tarball are
cached between runs.

Use **Actions → Build Euphonica AppImage → Run workflow** to build a specific
tag or force a rebuild.

The workflow installs Podman on the disposable GitHub runner only. Local builds
still use your existing rootless Podman and do not modify the host.

## What is bundled

- Euphonica itself (Rust, release build with LTO and stripped symbols)
- GTK 4, libadwaita, GLib/GIO, Pango, Cairo and the rest of the ELF closure
- PipeWire client libraries, the client configuration, the `support` and
  `audioconvert` SPA plugins, and the client modules named by `client.conf`
- libsecret, OpenSSL, SQLite, libwebp, ALSA
- A **minimal MPD 0.24.15** built from source:
  - decoders: FLAC, Vorbis, Opus, MP3
  - tag reader: libid3tag
  - resampler: SoXr
  - outputs: PipeWire, ALSA, FIFO (for the spectrum analyser)
  - storage: SQLite stickers and zlib-compressed database
  - everything else (FFmpeg, fluidsynth, MIDI, HTTP/WebDAV, UPnP, D-Bus,
    systemd, ...) is disabled
- GSettings schemas, Adwaita icons, Euphonica's flags and translations

glibc, the ELF loader and the NSS modules are intentionally **not** bundled;
they come from the host, as required for AppImage compatibility.

## How it works

Euphonica is a normal GTK application, plus two compile-time paths that need
relocation:

- `PKGDATADIR = /usr/share/euphonica` (GResource and flag SVGs)
- `LOCALEDIR = /usr/share/locale`

The build changes Meson's values to fixed `/tmp` paths
(`/tmp/.euphonica-data`, `/tmp/.euph-locale`) before Rust compiles, and
`AppRun` points those symlinks at the current AppImage mount.  Doing the
relocation before compiling avoids patching a linked Rust binary, where string
literals may be partly folded into immediates.  The same symlink-ownership
guard as the Junction AppImage prevents clobbering another user's links.

`AppRun` prepends the bundle to `PATH`, so Euphonica's Standalone Mode finds
`mpd` inside the AppImage.  Client mode works without MPD.

## Test

```sh
packaging/test-appimage.sh dist/Euphonica-*.AppImage

# Minimum supported target
TEST_IMAGE=ubuntu:26.04 packaging/test-appimage.sh dist/Euphonica-*.AppImage
```

This extracts the AppImage in a clean container (`TEST_IMAGE`, default
`quay.io/fedora/fedora:44`) and checks:

- `mpd --version`
- no unresolved shared libraries in `euphonica` or `mpd`
- the relocated path strings and bundled GResource/schemas/flags
- that the bundled `mpd` starts and answers a TCP `status` command
- (on hosts with `gtk4-broadwayd` and `dbus-run-session`) that the real GUI
  starts headlessly under Broadway and stays running without panicking

The final AppImage is about 42 MB.

A graphical smoke test can be run on a machine with a session bus and GTK's
Broadway daemon:

```sh
dbus-run-session -- bash -c '
  gtk4-broadwayd :97 &
  GDK_BACKEND=broadway BROADWAY_DISPLAY=:97 APPIMAGE_EXTRACT_AND_RUN=1 \
    ./dist/Euphonica-*.AppImage
'
```
