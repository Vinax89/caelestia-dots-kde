#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/package-snapshot.sh"
[[ -n "${PACKAGE_BEFORE:-}" && -f "$PACKAGE_BEFORE" ]] || exit 0
[[ -n "${PACKAGE_MANIFEST:-}" ]] || exit 1
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
caelestia_snapshot_packages "$work/after"
comm -13 "$PACKAGE_BEFORE" "$work/after" > "$work/new"
if [[ -f "$PACKAGE_MANIFEST" ]]; then
    cat "$PACKAGE_MANIFEST" >> "$work/new"
fi
sort -u "$work/new" > "$work/owned"
# Retain only ownership of packages still installed.
comm -12 "$work/owned" "$work/after" > "$PACKAGE_MANIFEST.tmp"
mv -- "$PACKAGE_MANIFEST.tmp" "$PACKAGE_MANIFEST"
