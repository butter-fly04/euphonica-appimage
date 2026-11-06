#!/usr/bin/env bash
# Print the newest version tag from an upstream Git repository.
#
# Usage: packaging/latest-tag.sh <git-url>
#
# Uses git's own protocol rather than a forge API, so it works the same for
# GitLab (Apostrophe) and GitHub (Junction/Euphonica) and is not subject to
# REST API rate limits.
set -euo pipefail

repo="${1:?usage: $0 <git-url>}"

tags="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "$repo" \
  | sed -e 's#.*refs/tags/##' \
  | grep -E '^v?[0-9]+\.' || true)"

if [ -z "$tags" ]; then
  echo "error: no version tags found in $repo" >&2
  exit 1
fi

# Semver-aware ordering.  This handles tags such as v1.13 (not v1.9),
# v2.1.3a, v2.2.0-beta1.3 and v0.99.8-beta-1.  A stable tag sorts after a
# prerelease of the same version, and prerelease identifiers are compared
# naturally (beta-10 > beta-2).  Plain `sort -V` gets the stable/prerelease
# case wrong.
python3 - "$tags" <<'PY'
import re
import sys


def key(tag):
    match = re.match(r"^v?(\d+(?:\.\d+)*)(.*)$", tag)
    if not match:
        return None

    core, suffix = match.groups()
    numbers = tuple(int(part) for part in core.split("."))

    if not suffix:
        # Stable release: sorts after every prerelease with the same core.
        return numbers, 1, ()

    def identifier(part):
        if part.isdigit():
            return 0, int(part), ""
        return 1, 0, part

    prerelease = suffix.lstrip(".-")
    parts = tuple(
        identifier(part) for part in re.split(r"[.-]", prerelease) if part
    )
    return numbers, 0, parts


candidates = []
for tag in sys.argv[1].splitlines():
    order = key(tag)
    if order is not None:
        candidates.append((order, tag))

if not candidates:
    raise SystemExit("error: no parseable version tags")

print(max(candidates)[1])
PY
