#!/usr/bin/env python3
"""Verify Euphonica's relocated compile-time paths and patch desktop metadata.

inner-build.sh changes Meson's PKGDATADIR/LOCALEDIR to fixed /tmp paths before
Cargo compiles.  AppRun points those symlinks at the current AppImage mount.
This script only verifies the result; it does not modify the Rust binary.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

EXPECTED = [b"/tmp/.euphonica-data", b"/tmp/.euph-locale"]


def verify_binary(path: Path) -> None:
    data = path.read_bytes()
    for needle in EXPECTED:
        if needle not in data:
            raise SystemExit(
                f"error: {needle.decode()} not found in {path}; "
                "the Meson path patch was not applied"
            )
        print(f"found {needle.decode()} in {path.name}")


def patch_desktop(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    original = text
    text = text.replace("DBusActivatable=true", "DBusActivatable=false")
    if text != original:
        path.write_text(text, encoding="utf-8")
        return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("appdir", type=Path)
    args = ap.parse_args()

    appdir = args.appdir.resolve()
    binary = appdir / "usr/bin/euphonica"
    if not binary.exists():
        raise SystemExit(f"error: {binary} does not exist")
    verify_binary(binary)

    for desktop in appdir.glob("usr/share/applications/*.desktop"):
        if patch_desktop(desktop):
            print(f"patched {desktop}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
