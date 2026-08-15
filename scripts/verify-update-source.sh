#!/usr/bin/env bash
# Verify an update commit against the repository's pinned release signer.
set -euo pipefail

repo="${1:-.}"
ref="${2:-HEAD}"
trusted_fingerprint="${CAELESTIA_TRUSTED_SIGNER:-968479A1AFF927E37D1A566BB5690EEEBB952194}"
key_url="https://github.com/web-flow.gpg"

for cmd in git gpg curl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[FATAL] Verification requires $cmd" >&2
        exit 1
    }
done

verify_home="$(mktemp -d "${TMPDIR:-/tmp}/caelestia-verify.XXXXXX")"
trap 'rm -rf -- "$verify_home"' EXIT HUP INT TERM
chmod 700 "$verify_home"

curl -fsSL --proto '=https' --tlsv1.2 "$key_url" -o "$verify_home/trusted.asc"
imported_fingerprints="$(gpg --homedir "$verify_home" --batch --with-colons --import-options show-only --import "$verify_home/trusted.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }')"
grep -Fxq "$trusted_fingerprint" <<< "$imported_fingerprints" || {
    echo "[FATAL] Trusted signer fingerprint mismatch" >&2
    exit 1
}
gpg --homedir "$verify_home" --batch --import "$verify_home/trusted.asc" >/dev/null 2>&1

status="$(GNUPGHOME="$verify_home" git -C "$repo" -c gpg.program=gpg \
    verify-commit --raw "$ref" 2>&1 || true)"
valid_fingerprint="$(printf '%s\n' "$status" | sed -n 's/^\[GNUPG:\] VALIDSIG \([0-9A-F]*\) .*/\1/p' | head -n1)"
[[ "$valid_fingerprint" == "$trusted_fingerprint" ]] || {
    echo "[FATAL] Commit $ref is not signed by trusted signer $trusted_fingerprint" >&2
    exit 1
}

printf '[OK] Trusted update commit: %s (%s)\n' "$(git -C "$repo" rev-parse "$ref")" "$trusted_fingerprint"
