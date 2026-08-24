#!/usr/bin/env bash
# 00a-system-update.sh - System update script

set -euo pipefail

# Re-take the "packages installed before Caelestia" snapshot once the system
# upgrade below has finished.
#
# The uninstaller removes exactly the packages that appeared between that
# snapshot and the end of the install. A full `pacman -Syu` / `dnf upgrade` /
# `apt-get upgrade` can pull in new dependencies of completely unrelated
# packages, and snapshotting before it attributed every one of them to
# Caelestia -- then offered them to `pacman -Rns` on uninstall.
resnapshot_packages() {
    local lib="${BUNDLE_DIR:-}/scripts/lib/package-snapshot.sh"
    if [[ -n "${PACKAGE_BEFORE:-}" && -r "$lib" ]]; then
        # shellcheck source=lib/package-snapshot.sh
        . "$lib"
        caelestia_snapshot_packages "$PACKAGE_BEFORE"
        echo "[INFO]  Package baseline re-taken after the system update."
    fi
}
trap resnapshot_packages EXIT

if [[ "${SKIP_SYSTEM_UPDATE:-false}" == "true" ]]; then
    echo "[INFO]  Skipping full system update (SKIP_SYSTEM_UPDATE=true)."
    exit 0
fi

if [[ "${BASE_DISTRO:-unknown}" == "arch" ]]; then
    if [[ -n "${CONFIRM_ARG:-}" ]]; then
        sudo pacman -Syu --noconfirm
    else
        sudo pacman -Syu
    fi
elif [[ "${BASE_DISTRO:-unknown}" == "fedora" ]]; then
    if [[ -n "${CONFIRM_ARG:-}" ]]; then
        sudo dnf upgrade --refresh -y
    else
        sudo dnf upgrade --refresh
    fi
elif [[ "${BASE_DISTRO:-unknown}" == "debian" ]]; then
    if [[ -n "${CONFIRM_ARG:-}" ]]; then
        sudo apt-get update && sudo apt-get upgrade -y
    else
        sudo apt-get update && sudo apt-get upgrade
    fi
else
    echo "[WARN] Distro not set properly, skipping system update."
fi
