#!/usr/bin/env python3
"""Copy the recursive ELF dependency closure into an AppDir.

Deliberately never copies glibc, the ELF loader, or the NSS modules that must
match the host kernel/libc.  The AppImage therefore links against the host
glibc while shipping the GTK/libadwaita, PipeWire, codec and MPD stack.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

BLACKLIST = re.compile(
    r"^(libc\.|libm\.|libpthread\.|libdl\.|librt\.|libresolv\.|libnss_|"
    r"libutil\.|libanl\.|libBrokenLocale\.|libmvec\.|ld-linux|linux-vdso|"
    r"libc_malloc_debug)"
)

# Libraries that are dlopen()ed and therefore do not show up in the ldd output
# of an executable.  The PipeWire SPA plugins and the dconf GIO module are
# already inside the AppDir and are scanned there; these seeds are only needed
# for libraries loaded by name from outside the bundle.
DLOPEN_SEEDS: list[str] = []


def run(cmd: list[str]) -> str:
    return subprocess.run(
        cmd, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    ).stdout


def ldd_deps(path: Path) -> list[Path]:
    try:
        out = subprocess.run(
            ["ldd", str(path)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout
    except OSError:
        return []

    deps: list[Path] = []
    for line in out.splitlines():
        m = re.search(r"=>\s+(/\S+)\s+\(", line)
        if not m:
            m = re.search(r"^\s*(/\S+)\s+\(", line)
        if m:
            deps.append(Path(m.group(1)))
    return deps


def find_soname(name: str) -> Path | None:
    try:
        out = run(["ldconfig", "-p"])
    except subprocess.CalledProcessError:
        return None
    candidates = []
    for line in out.splitlines():
        if "=>" not in line:
            continue
        soname, _, path = line.strip().partition(" => ")
        soname = soname.strip()
        path = path.strip()
        if soname.startswith(name) and path.startswith("/"):
            candidates.append(Path(path))
    if not candidates:
        return None
    return sorted(candidates, key=lambda p: (len(p.name), str(p)))[0]


def soname_of(path: Path) -> str | None:
    try:
        return run(["patchelf", "--print-soname", str(path)]).strip() or None
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def is_elf(path: Path) -> bool:
    try:
        with path.open("rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def looks_like_library(path: Path) -> bool:
    return ".so" in path.name


def copy_lib(src: Path, libdir: Path, copied: set[Path], queue: list[Path]) -> None:
    src = src.resolve()
    if not src.is_file():
        return
    if BLACKLIST.match(src.name):
        return
    if src in copied:
        return

    copied.add(src)
    dst = libdir / src.name
    if not dst.exists():
        shutil.copy2(src, dst)
        os.chmod(dst, 0o755 if os.access(src, os.X_OK) else 0o644)

    soname = soname_of(dst)
    if soname and soname != dst.name:
        link = libdir / soname
        if not link.exists():
            link.symlink_to(dst.name)

    queue.append(dst)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("appdir", type=Path)
    ap.add_argument("--seed-elf-dir", action="append", default=[])
    args = ap.parse_args()

    appdir = args.appdir.resolve()
    libdir = appdir / "usr" / "lib"
    libdir.mkdir(parents=True, exist_ok=True)

    copied: set[Path] = set()
    queue: list[Path] = []

    for root in [appdir, *[Path(p) for p in args.seed_elf_dir]]:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            if not looks_like_library(path) and not (
                path.stat().st_mode & 0o111
            ):
                continue
            if is_elf(path):
                for dep in ldd_deps(path):
                    copy_lib(dep, libdir, copied, queue)

    for name in DLOPEN_SEEDS:
        p = find_soname(name)
        if p is None:
            print(f"warning: {name} not found via ldconfig", file=sys.stderr)
            continue
        copy_lib(p, libdir, copied, queue)

    seen_queue: set[Path] = set()
    while queue:
        lib = queue.pop(0)
        if lib in seen_queue:
            continue
        seen_queue.add(lib)
        for dep in ldd_deps(lib):
            copy_lib(dep, libdir, copied, queue)

    print(f"bundled {len(copied)} ELF libraries into {libdir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
