#!/usr/bin/env bash
# package-snapshot.sh - shared package-inventory helper.
#
# The uninstaller removes exactly the packages listed in $PACKAGE_MANIFEST,
# which is the difference between a "before" and an "after" inventory. That
# difference is only meaningful if the "before" snapshot is taken *after*
# everything that installs packages for reasons unrelated to Caelestia --
# specifically the mirror refresh and the full system upgrade, both of which can
# pull in new dependencies of unrelated packages. Snapshotting first attributed
# every one of those to Caelestia and offered them up for removal.
#
# Sourced by scripts/setup.sh and scripts/00a-system-update.sh; both re-take the
# snapshot at the latest point they can, so the last writer wins.
set -euo pipefail

# Write the current set of installed package names, one per line, sorted, to $1.
caelestia_snapshot_packages() {
    local out="$1"
    local distro="${BASE_DISTRO:-unknown}"

    case "$distro" in
        arch)
            pacman -Qq 2>/dev/null | sort -u > "$out" || : > "$out"
            ;;
        fedora)
            dnf repoquery --installed --qf '%{name}' 2>/dev/null | sort -u > "$out" || : > "$out"
            ;;
        debian)
            dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u > "$out" || : > "$out"
            ;;
        *)
            : > "$out"
            ;;
    esac
}
