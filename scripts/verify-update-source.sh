#!/usr/bin/env bash
# Verify an update ref against the repository's pinned release signer.
#
# Two trust anchors are supported, in order of strength:
#
#   1. A maintainer release-signing key. Pin its full fingerprint in
#      CAELESTIA_RELEASE_SIGNER (or RELEASE_SIGNER in .github/version.env).
#      This identifies *who* produced the release.
#
#   2. GitHub's shared web-flow key. This only attests that the commit was
#      created through github.com -- it does not identify a signer, because
#      web-flow signs commits made by any account through the web UI or API.
#      It is the fallback when no maintainer key is pinned.
#
# In both cases the key material is fetched and then rejected unless its
# fingerprint matches the anchor, so where the material comes from does not
# have to be trusted -- only the pinned fingerprint does.
set -euo pipefail

repo="${1:-.}"
ref="${2:-HEAD}"

WEB_FLOW_FINGERPRINT="968479A1AFF927E37D1A566BB5690EEEBB952194"
WEB_FLOW_KEY_URL="https://github.com/web-flow.gpg"
MAINTAINER_KEY_FILE=".github/release-signing-key.asc"

for cmd in git gpg curl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[FATAL] Verification requires $cmd" >&2
        exit 1
    }
done

# Resolve the maintainer fingerprint: explicit env wins, otherwise the value
# committed alongside the version. Normalised to uppercase, no spaces.
release_signer="${CAELESTIA_RELEASE_SIGNER:-}"
signer_from_checkout=0
if [[ -z "$release_signer" && -f "$repo/.github/version.env" ]]; then
    release_signer="$(sed -n 's/^RELEASE_SIGNER[[:space:]]*=[[:space:]]*//p' "$repo/.github/version.env" | tr -d '"'"'"' \t\r' | head -n1)"
    [[ -n "$release_signer" ]] && signer_from_checkout=1
fi
release_signer="$(printf '%s' "$release_signer" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"

if [[ -n "$release_signer" && ! "$release_signer" =~ ^[0-9A-F]{40}$ ]]; then
    echo "[FATAL] RELEASE_SIGNER must be a full 40-character fingerprint, got: $release_signer" >&2
    exit 1
fi

# Legacy override: CAELESTIA_TRUSTED_SIGNER used to replace the web-flow anchor.
trusted_fingerprint="${CAELESTIA_TRUSTED_SIGNER:-$WEB_FLOW_FINGERPRINT}"

verify_home="$(mktemp -d "${TMPDIR:-/tmp}/caelestia-verify.XXXXXX")"
trap 'rm -rf -- "$verify_home"' EXIT HUP INT TERM
chmod 700 "$verify_home"

# Import key material and refuse it unless the pinned fingerprint is present.
import_anchored_key() {
    local key_path="$1" expected="$2" fingerprints
    fingerprints="$(gpg --homedir "$verify_home" --batch --with-colons \
        --import-options show-only --import "$key_path" 2>/dev/null \
        | awk -F: '$1 == "fpr" { print $10 }')"
    grep -Fxq "$expected" <<< "$fingerprints" || {
        echo "[FATAL] Key material does not contain the pinned fingerprint $expected" >&2
        return 1
    }
    gpg --homedir "$verify_home" --batch --import "$key_path" >/dev/null 2>&1
}

# Return the VALIDSIG fingerprint for a ref, preferring an annotated signed tag
# over the commit it points at.
signature_fingerprint() {
    local target="$1" status=""
    if git -C "$repo" cat-file -t "$target" 2>/dev/null | grep -qx tag; then
        status="$(GNUPGHOME="$verify_home" git -C "$repo" -c gpg.program=gpg \
            verify-tag --raw "$target" 2>&1 || true)"
    fi
    if ! grep -q 'VALIDSIG' <<< "$status"; then
        status="$(GNUPGHOME="$verify_home" git -C "$repo" -c gpg.program=gpg \
            verify-commit --raw "$target" 2>&1 || true)"
    fi
    printf '%s\n' "$status" | sed -n 's/^\[GNUPG:\] VALIDSIG \([0-9A-F]*\) .*/\1/p' | head -n1
}

if [[ -n "$release_signer" ]]; then
    anchor="$release_signer"
    anchor_kind="maintainer release-signing key"
    if (( signer_from_checkout )); then
        # An anchor read out of the thing being verified is only advisory: an
        # attacker who controls the checkout controls both the key file and
        # this fingerprint. It still detects tampering *after* a good checkout,
        # which is why it is allowed, but callers that install code -- notably
        # src/bin/caelestia-update -- carry the fingerprint themselves instead.
        echo "[WARN] RELEASE_SIGNER came from the checkout being verified; this is advisory." >&2
        echo "[WARN] Pin it outside the repo via CAELESTIA_RELEASE_SIGNER for a real identity check." >&2
    fi
    if [[ ! -f "$repo/$MAINTAINER_KEY_FILE" ]]; then
        echo "[FATAL] RELEASE_SIGNER is pinned but $MAINTAINER_KEY_FILE is missing" >&2
        exit 1
    fi
    import_anchored_key "$repo/$MAINTAINER_KEY_FILE" "$anchor" || exit 1
else
    anchor="$trusted_fingerprint"
    anchor_kind="GitHub web-flow key (attests github.com authorship, not a signer)"
    curl -fsSL --proto '=https' --tlsv1.2 "$WEB_FLOW_KEY_URL" -o "$verify_home/trusted.asc"
    import_anchored_key "$verify_home/trusted.asc" "$anchor" || exit 1
fi

valid_fingerprint="$(signature_fingerprint "$ref")"
[[ "$valid_fingerprint" == "$anchor" ]] || {
    echo "[FATAL] $ref is not signed by the trusted signer $anchor" >&2
    echo "        anchor: $anchor_kind" >&2
    echo "        got:    ${valid_fingerprint:-<no valid signature>}" >&2
    exit 1
}

printf '[OK] Trusted update ref: %s (%s)\n     anchor: %s\n' \
    "$(git -C "$repo" rev-parse "$ref")" "$anchor" "$anchor_kind"
