#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/pacman" <<'PM'
#!/usr/bin/env bash
if [[ "${QUERY_FAIL:-0}" == 1 ]]; then exit 1; fi
printf '%s\n' base existing newly-added previously-owned
PM
chmod +x "$work/bin/pacman"
export PATH="$work/bin:$PATH" BASE_DISTRO=arch
export PACKAGE_BEFORE="$work/before" PACKAGE_MANIFEST="$work/owned"
printf '%s\n' base existing previously-owned > "$PACKAGE_BEFORE"
printf '%s\n' previously-owned removed-package > "$PACKAGE_MANIFEST"
bash "$repo/scripts/record-package-manifest.sh"
printf '%s\n' newly-added previously-owned > "$work/expected"
cmp "$work/expected" "$PACKAGE_MANIFEST"
# Failed inventories must not overwrite ownership or create an empty baseline.
export QUERY_FAIL=1
if bash "$repo/scripts/record-package-manifest.sh"; then exit 1; fi
cmp "$work/expected" "$PACKAGE_MANIFEST"
source "$repo/scripts/lib/package-snapshot.sh"
if caelestia_snapshot_packages "$work/bad"; then exit 1; fi
[[ ! -e "$work/bad" ]]
BASE_DISTRO=unsupported
if caelestia_snapshot_packages "$work/bad"; then exit 1; fi
[[ ! -e "$work/bad" ]]
