#!/usr/bin/env python3
"""Fail when a hardcoded repository slug drifts from .github/version.env.

Several components cannot read version.env at runtime -- the updater and the
update checker are installed into ~/.local/bin and run before any checkout
exists, so they carry a compiled-in default. That default is only safe if
something keeps it in sync with the canonical value, which is this script.

Every occurrence of an owner-plus-repository-name slug in a tracked text file
must equal REPO from .github/version.env.

This file is excluded from its own scan: it describes the pattern it matches,
the same way check_shell_quality.sh skips itself in the curl-pipe check.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERSION_ENV = ROOT / ".github" / "version.env"

RED = "\033[0;31m"
GREEN = "\033[0;32m"
BOLD = "\033[1m"
RESET = "\033[0m"

# Any owner/caelestia-dots-kde pair, however it is spelled (URL, API path,
# bare slug). The owner is whatever precedes the repository name.
SLUG_RE = re.compile(r"(?<![\w./-])([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)/caelestia-dots-kde\b")

# Binary and vendored trees that never contain a slug worth checking.
SKIP_PREFIXES = ("src/dots/", "src/plasma-wallpaper-application/",
                 "src/yet-another-monochrome-icon-set/")
SKIP_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".svg", ".mp4", ".wav",
                 ".ttf", ".pyc", ".knsv")

# json.hpp is vendored; check_repo_identity has nothing to say about it.
# This script is skipped too -- it documents the slug pattern it looks for.
SKIP_NAMES = ("json.hpp", "check_repo_identity.py")


def canonical_repo() -> str:
    for line in VERSION_ENV.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if sep and key.strip() == "REPO":
            slug = value.strip().strip('"').strip("'")
            if slug:
                return slug
    raise SystemExit(f"{RED}[ERR]{RESET}  REPO is missing from .github/version.env")


def tracked_files() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, cwd=ROOT, check=True
    )
    return [f for f in result.stdout.splitlines() if f]


def main() -> int:
    expected = canonical_repo()
    print(f"{BOLD}=== Repository Identity Check ==={RESET}")
    print(f"Canonical REPO from .github/version.env: {expected}")

    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+", expected):
        print(f"{RED}[ERR]{RESET}  REPO is not a valid owner/name slug: {expected!r}")
        return 1

    violations: list[str] = []
    scanned = 0

    for rel in tracked_files():
        if rel.startswith(SKIP_PREFIXES) or rel.endswith(SKIP_SUFFIXES):
            continue
        if Path(rel).name in SKIP_NAMES:
            continue

        path = ROOT / rel
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue

        scanned += 1
        for line_no, line in enumerate(text.splitlines(), 1):
            for match in SLUG_RE.finditer(line):
                found = match.group(0)
                if found != expected:
                    violations.append(
                        f"{rel}:{line_no}: found {found!r}, expected {expected!r}"
                    )

    print(f"Scanned {scanned} tracked text file(s).")

    if violations:
        print(f"\n{BOLD}{RED}{len(violations)} repository identity violation(s):{RESET}")
        for v in violations:
            print(f"{RED}[ERR]{RESET}  {v}")
        print(
            "\nUpdate the offending default, or change REPO in .github/version.env "
            "if the canonical repository really moved."
        )
        return 1

    print(f"{GREEN}[OK]{RESET}   All repository references match the canonical slug.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
