#!/usr/bin/env bash
# ==============================================================
#   Caelestia KDE Port - Unified Installer
#
#   Original Hyprland dots: Caelestia
#   KDE port and modifications: ladybug-me
#   Installer behavior: idempotent and safe for reruns
# ==============================================================

set -euo pipefail
export CAELESTIA_SETUP_RUNNING=1

# Hide cursor immediately for cleaner output
tput civis 2>/dev/null || true

# -- Paths ---------------------------------------------------------------------
# setup.sh lives in scripts/, so the bundle root is one level up. Without the
# "/.." every derived path lands a directory too deep -- $BUNDLE_DIR/installer,
# $BUNDLE_DIR/src, $BUNDLE_DIR/shell and the step scripts the TUI runs all
# resolve under scripts/ and do not exist. a0e30d5e fixed this when setup.sh was
# moved out of the repo root; 09201835 reverted it.
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$BUNDLE_DIR/scripts"
export BUNDLE_DIR
INSTALL_START_EPOCH="$(date +%s)"
export INSTALL_START_EPOCH

# Prevent concurrent runs in a private directory.
LOCK_DIR="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/caelestia"
mkdir -p "$LOCK_DIR"
chmod 700 "$LOCK_DIR"
exec 9>"$LOCK_DIR/setup.lock"
flock -n 9 || { echo "Another Caelestia setup is already running."; exit 1; }

detect_base_distro() {
    local detected="unknown"

    if [[ -f /etc/os-release ]]; then
       # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
            arch|cachyos|endeavouros|manjaro|artix)
                detected="arch"
                ;;
            fedora|nobara|bazzite|rhel|centos|almalinux|rocky)
                detected="fedora"
                ;;
            debian|ubuntu|pop|mint|kali|raspbian|elementary|zorin|deepin|devuan)
                detected="debian"
                ;;
            *)
                if echo "${ID_LIKE:-}" | grep -iq "arch"; then
                    detected="arch"
                elif echo "${ID_LIKE:-}" | grep -iq "fedora"; then
                    detected="fedora"
                elif echo "${ID_LIKE:-}" | grep -iq -E "debian|ubuntu"; then
                    detected="debian"
                fi
                ;;
        esac
    fi

    if [[ "$detected" == "unknown" ]]; then
        if command -v pacman >/dev/null 2>&1; then
            detected="arch"
        elif command -v dnf >/dev/null 2>&1; then
            detected="fedora"
        elif command -v apt-get >/dev/null 2>&1; then
            detected="debian"
        fi
    fi

    echo "$detected"
}

# Look up the country for pacman mirror ranking.
#
# This sends the machine's IP address to a third-party geo-IP service, which is
# not something an installer should do silently, so it is opt-in. Without it,
# reflector still ranks mirrors by measured download rate -- just against the
# global pool instead of a country-filtered one.
#
# Opt in with CAELESTIA_GEOIP_MIRRORS=1.
detect_country() {
    if [[ "${CAELESTIA_GEOIP_MIRRORS:-0}" != "1" ]]; then
        return 1
    fi

    local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/caelestia-country"
    local cache_ttl=86400

    if [[ -f "$cache_file" ]]; then
        local cache_age
        cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)))
        if (( cache_age < cache_ttl )); then
            cat "$cache_file"
            return 0
        fi
    fi

    # Each probe writes to its own file. Sharing one pipe between three
    # concurrent curls let partial writes interleave into a corrupted line.
    local probe_dir country=""
    probe_dir="$(mktemp -d)" || return 1

    curl -fsSL --max-time 2 'https://am.i.mullvad.net/country' >"$probe_dir/1" 2>/dev/null &
    curl -fsSL --max-time 2 'https://ipinfo.io/country' >"$probe_dir/2" 2>/dev/null &
    curl -fsSL --max-time 2 'https://ifconfig.co/json' 2>/dev/null \
        | grep -oP '"country_iso"\s*:\s*"\K[^"]+' >"$probe_dir/3" 2>/dev/null &
    wait

    local probe
    for probe in "$probe_dir"/1 "$probe_dir"/2 "$probe_dir"/3; do
        [[ -s "$probe" ]] || continue
        country="$(tr -d '[:space:]' < "$probe" | grep -E '^[A-Za-z]{2,3}$' || true)"
        [[ -n "$country" ]] && break
    done
    rm -rf -- "$probe_dir"

    if [[ -n "$country" ]]; then
        mkdir -p "$(dirname "$cache_file")"
        printf '%s' "$country" > "$cache_file"
        printf '%s' "$country"
        return 0
    fi

    return 1
}

is_cachyos() {
    local os_id=""
    local os_like=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
        os_like="${ID_LIKE:-}"
    fi

    [[ "$os_id" == "cachyos" || " $os_like " == *" cachyos "* ]]
}

silent_refresh_pacman_sources() {
    if [[ "$BASE_DISTRO" != "arch" ]]; then
        return 0
    fi

    local have_root=0
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        have_root=1
    else
        # Ask for sudo once upfront; sudo -v caches the ticket.
        echo "[INFO]  Requesting sudo access to refresh/rank pacman mirrors..."
        if sudo -v; then
            have_root=1
        else
            echo "[WARN]  Skipping pacman mirror refresh/ranking (sudo access not available)."
        fi
    fi

    if (( have_root )); then
        # Cached sudo — non-interactive from here on.
        as_root() {
            if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                "$@"
            else
                sudo -n "$@"
            fi
        }

        if is_cachyos; then
            if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
                echo "[INFO]  Ranking Arch and CachyOS mirrors using cachyos-rate-mirrors..."
                as_root cachyos-rate-mirrors >/dev/null 2>&1 || echo "[WARN]  cachyos-rate-mirrors failed, continuing with current mirrors."
            else
                echo "[WARN]  cachyos-rate-mirrors is not installed; continuing with current mirrors."
            fi
        else
            # Reflector is the fallback for Arch-based systems without CachyOS tooling.
            if ! command -v reflector >/dev/null 2>&1; then
                as_root pacman -Syu --noconfirm reflector >/dev/null 2>&1 || true
            fi

            if command -v reflector >/dev/null 2>&1; then
                local reflector_country
                # `|| true` matters under `set -e`: detect_country returns non-zero
                # whenever the geo-IP lookup is disabled or fails, and a bare
                # assignment from a failing substitution aborts the installer.
                reflector_country="$(detect_country || true)"
                local -a reflector_args=(--latest 20 --protocol https --sort rate)
                if [[ -n "$reflector_country" ]]; then
                    echo "[INFO]  Ranking pacman mirrors by download speed (country: $reflector_country)..."
                    reflector_args+=(--country "$reflector_country")
                else
                    if [[ "${CAELESTIA_GEOIP_MIRRORS:-0}" == "1" ]]; then
                        echo "[INFO]  Ranking pacman mirrors by download speed (country detection failed, using global pool)..."
                    else
                        echo "[INFO]  Ranking pacman mirrors by download speed (global pool)."
                        echo "[INFO]  Set CAELESTIA_GEOIP_MIRRORS=1 to narrow this by country via a third-party geo-IP lookup."
                    fi
                fi
                as_root reflector "${reflector_args[@]}" --save /etc/pacman.d/mirrorlist >/dev/null 2>&1 \
                    || echo "[WARN]  reflector failed, continuing with current mirrors."
            fi
        fi

        # Pre-install dos2unix for CRLF normalization later.
        if ! command -v dos2unix >/dev/null 2>&1; then
            as_root pacman -Syu --noconfirm dos2unix >/dev/null 2>&1 || true
        fi

        as_root pacman -Syu --noconfirm >/dev/null 2>&1 || echo "[WARN]  Failed to refresh pacman sources early. Continuing..."
        unset -f as_root
    fi
}

silent_refresh_native_sources() {
    local have_root=0

    case "$BASE_DISTRO" in
        fedora|debian) ;;
        *) return 0 ;;
    esac

    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        have_root=1
    elif sudo -v; then
        have_root=1
    else
        echo "[WARN]  Skipping package source refresh (sudo access not available)."
        return 0
    fi

    case "$BASE_DISTRO" in
        fedora)
            echo "[INFO]  Refreshing Fedora repository metadata using DNF..."
            if (( have_root )) && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                dnf makecache --refresh >/dev/null 2>&1 || echo "[WARN]  Failed to refresh DNF metadata. Continuing..."
            else
                sudo -n dnf makecache --refresh >/dev/null 2>&1 || echo "[WARN]  Failed to refresh DNF metadata. Continuing..."
            fi
            ;;
        debian)
            echo "[INFO]  Refreshing Debian repository metadata using APT..."
            if (( have_root )) && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                apt-get update >/dev/null 2>&1 || echo "[WARN]  Failed to refresh APT metadata. Continuing..."
            else
                sudo -n apt-get update >/dev/null 2>&1 || echo "[WARN]  Failed to refresh APT metadata. Continuing..."
            fi
            ;;
    esac
}

run_arch_pacman_install() {
    local -a pkgs=("$@")
    local -a pacman_args=(-S --needed --noconfirm)

    if (( ${#pkgs[@]} == 0 )); then
        return 0
    fi

    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        pacman -Syu --noconfirm >/dev/null 2>&1 || echo "[WARN]  Failed to refresh pacman sources before install. Continuing..."
        pacman "${pacman_args[@]}" "${pkgs[@]}" && return 0

        echo "[WARN]  pacman install failed. Refreshing sources and retrying once..."
        pacman -Syu --noconfirm >/dev/null 2>&1 || true
        pacman "${pacman_args[@]}" "${pkgs[@]}"
        return $?
    fi

    sudo pacman -Syu --noconfirm >/dev/null 2>&1 || echo "[WARN]  Failed to refresh pacman sources before install. Continuing..."
    sudo pacman "${pacman_args[@]}" "${pkgs[@]}" && return 0

    echo "[WARN]  pacman install failed. Refreshing sources and retrying once..."
    sudo pacman -Syu --noconfirm >/dev/null 2>&1 || true
    sudo pacman "${pacman_args[@]}" "${pkgs[@]}"
}

BASE_DISTRO="$(detect_base_distro)"
export BASE_DISTRO

PACKAGE_STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/caelestia-kde"
PACKAGE_BEFORE="$PACKAGE_STATE_DIR/packages.before"
PACKAGE_MANIFEST="$PACKAGE_STATE_DIR/installed-packages.txt"
mkdir -p "$PACKAGE_STATE_DIR"
export PACKAGE_STATE_DIR PACKAGE_BEFORE PACKAGE_MANIFEST

# shellcheck source=lib/package-snapshot.sh
. "$SCRIPTS_DIR/lib/package-snapshot.sh"

# Only run in the outer (pre-tmux) invocation.
if [[ "${CAELESTIA_TMUX_MASTER:-0}" == "0" ]]; then
    if [[ "$BASE_DISTRO" == "arch" ]]; then
        silent_refresh_pacman_sources
    elif [[ "$BASE_DISTRO" == "fedora" || "$BASE_DISTRO" == "debian" ]]; then
        silent_refresh_native_sources
    fi
fi

# Snapshot the installed-package set AFTER the mirror refresh above.
#
# That refresh runs a full `pacman -Syu` (and installs reflector/dos2unix), so
# taking the snapshot before it recorded every package that upgrade pulled in as
# "installed by Caelestia" -- and the uninstaller feeds this list straight to
# `pacman -Rns`. 00a-system-update.sh re-takes the snapshot after the installer's
# own system-update step for the same reason.
caelestia_snapshot_packages "$PACKAGE_BEFORE"

normalize_line_endings_first() {
    BASE_DISTRO="$(detect_base_distro)"
    export BASE_DISTRO
    local -a crlf_files=()
    local convert_choice=""

    mapfile -t crlf_files < <(
        find "$BUNDLE_DIR" -path "$BUNDLE_DIR/.git" -prune -o -type f -name '*.sh' -print0 | \
            xargs -0 grep -Il $'\r' 2>/dev/null || true
    )

    if (( ${#crlf_files[@]} == 0 )); then
        return 0
    fi

    echo "[WARN]  Detected ${#crlf_files[@]} file(s) with CRLF line endings."
    while true; do
        read -r -p "Convert all files under this repo to LF with dos2unix? [Y/n]: " convert_choice
        convert_choice="${convert_choice:-y}"

        case "${convert_choice,,}" in
            y|yes)
                if ! command -v dos2unix >/dev/null 2>&1; then
                    echo "[WARN]  dos2unix is not installed. Attempting to install it now..."
                    case "$BASE_DISTRO" in
                        arch)
                            run_arch_pacman_install dos2unix || return 1
                            ;;
                        fedora)
                            sudo dnf install -y dos2unix || return 1
                            ;;
                        debian)
                            sudo apt-get update && sudo apt-get install -y dos2unix || return 1
                            ;;
                        *)
                            echo "[WARN]  Could not detect distro for automatic dos2unix installation."
                            return 1
                            ;;
                    esac
                    echo "[OK]    dos2unix installed."
                fi

                (
                    cd "$BUNDLE_DIR" || exit 1
                    printf '%s\0' "${crlf_files[@]}" | xargs -0 -r dos2unix --
                ) || return 1

                echo "[OK]    Line endings normalized to LF."
                return 0
                ;;
            n|no)
                echo "[WARN]  Skipping line ending normalization by user choice."
                return 0
                ;;
            *)
                echo "Please answer with y or n."
                ;;
        esac
    done
}

if [[ "${CAELESTIA_TMUX_MASTER:-0}" == "0" ]]; then
    if ! normalize_line_endings_first; then
        echo "[FATAL] Line ending normalization step failed. Aborting installer." >&2
        exit 1
    fi
fi

BIN="$BUNDLE_DIR/caelestia-install"

PREBUILT_BASE_URL="https://github.com/Vinax89/caelestia-dots-kde/releases/download/caelestia-bin-repo"
MAINTAINER_KEY_FILE="$BUNDLE_DIR/.github/release-signing-key.asc"

# Resolve the pinned release-signer fingerprint, if the project has one.
#
# Reading it out of the checkout is only as strong as the checkout itself --
# but the checkout arrives over git and the update path verifies commit
# signatures, whereas a release asset has no such anchor. That asymmetry is the
# whole point: without a pinned key there is nothing that makes a downloaded
# binary more trustworthy than whoever can write to the release.
prebuilt_release_signer() {
    local signer=""
    if [[ -n "${CAELESTIA_RELEASE_SIGNER:-}" ]]; then
        signer="$CAELESTIA_RELEASE_SIGNER"
    elif [[ -f "$BUNDLE_DIR/.github/version.env" ]]; then
        signer="$(sed -n 's/^RELEASE_SIGNER[[:space:]]*=[[:space:]]*//p' \
            "$BUNDLE_DIR/.github/version.env" | tr -d '"'"'"' \t\r' | head -n1)"
    fi
    signer="$(printf '%s' "$signer" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
    [[ "$signer" =~ ^[0-9A-F]{40}$ ]] || return 1
    printf '%s' "$signer"
}

# Verify SHA256SUMS carries a good signature from the pinned release signer.
# Key material is fetched from the checkout and then rejected unless it
# contains the pinned fingerprint, so only the fingerprint has to be trusted.
verify_prebuilt_signature() {
    local sums_file="$1" sig_file="$2" signer="$3"
    local verify_home fingerprints
    command -v gpg >/dev/null 2>&1 || return 1
    [[ -s "$sig_file" && -f "$MAINTAINER_KEY_FILE" ]] || return 1

    verify_home="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/caelestia-prebuilt-verify.XXXXXX")" || return 1
    chmod 700 "$verify_home"

    fingerprints="$(gpg --homedir "$verify_home" --batch --with-colons \
        --import-options show-only --import "$MAINTAINER_KEY_FILE" 2>/dev/null \
        | awk -F: '$1 == "fpr" { print $10 }')"
    if ! grep -Fxq "$signer" <<< "$fingerprints"; then
        rm -rf -- "$verify_home"
        return 1
    fi
    gpg --homedir "$verify_home" --batch --import "$MAINTAINER_KEY_FILE" >/dev/null 2>&1

    local status
    status="$(gpg --homedir "$verify_home" --batch --status-fd 1 \
        --verify "$sig_file" "$sums_file" 2>/dev/null || true)"
    rm -rf -- "$verify_home"

    grep -q "^\[GNUPG:\] VALIDSIG $signer" <<< "$status"
}

# Prefer the release-built installer when available, but retain the local
# compilation path as an offline and verification-friendly fallback.
#
# The binary is executed with the user's privileges and goes on to run every
# install step, so it is verified before it is ever made executable:
#
#   1. Its SHA-256 must match the entry in the release's SHA256SUMS.
#   2. SHA256SUMS must carry a good signature from the pinned release signer.
#
# Step 2 is what makes step 1 mean anything -- anyone able to replace the
# binary in a release can replace the checksum file beside it. When no signer
# is pinned there is no anchor to verify against, so the prebuilt path is
# declined and the installer compiles from the (git-verified) source tree
# instead. CAELESTIA_ALLOW_UNSIGNED_PREBUILT=1 overrides that for users who
# accept the risk.
# Sets PREBUILT_BIN on success and PREBUILT_DECLINED_REASON on refusal.
# Deliberately not run in a command substitution: both are globals, and a
# subshell would discard them.
try_download_prebuilt_installer() {
    local arch tmp_dir tmp_bin signer actual expected
    PREBUILT_BIN=""
    PREBUILT_DECLINED_REASON=""
    arch="$(uname -m)"
    case "$arch" in
        x86_64|aarch64) ;;
        *) return 1 ;;
    esac

    signer="$(prebuilt_release_signer || true)"
    if [[ -z "$signer" && "${CAELESTIA_ALLOW_UNSIGNED_PREBUILT:-0}" != "1" ]]; then
        PREBUILT_DECLINED_REASON="no release-signing key is pinned"
        return 1
    fi

    tmp_dir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/caelestia-prebuilt-XXXXXX")" || return 1
    tmp_bin="$tmp_dir/caelestia-install"

    local -a curl_args=(-fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120)

    if ! curl "${curl_args[@]}" "$PREBUILT_BASE_URL/caelestia-install-${arch}" -o "$tmp_bin" 2>/dev/null; then
        PREBUILT_DECLINED_REASON="download failed"
        rm -rf -- "$tmp_dir"
        return 1
    fi
    if ! curl "${curl_args[@]}" "$PREBUILT_BASE_URL/SHA256SUMS" -o "$tmp_dir/SHA256SUMS" 2>/dev/null; then
        PREBUILT_DECLINED_REASON="release publishes no SHA256SUMS"
        rm -rf -- "$tmp_dir"
        return 1
    fi
    curl "${curl_args[@]}" "$PREBUILT_BASE_URL/SHA256SUMS.asc" -o "$tmp_dir/SHA256SUMS.asc" 2>/dev/null || true

    if [[ -n "$signer" ]]; then
        if ! verify_prebuilt_signature "$tmp_dir/SHA256SUMS" "$tmp_dir/SHA256SUMS.asc" "$signer"; then
            PREBUILT_DECLINED_REASON="SHA256SUMS is not signed by $signer"
            rm -rf -- "$tmp_dir"
            return 1
        fi
    fi

    expected="$(awk -v f="caelestia-install-${arch}" '$2 == f || $2 == "*" f { print $1 }' \
        "$tmp_dir/SHA256SUMS" | head -n1)"
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
        PREBUILT_DECLINED_REASON="no SHA256SUMS entry for caelestia-install-${arch}"
        rm -rf -- "$tmp_dir"
        return 1
    fi

    actual="$(sha256sum "$tmp_bin" | awk '{print $1}')"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        PREBUILT_DECLINED_REASON="checksum mismatch (expected $expected, got $actual)"
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Only now is it safe to make the file executable.
    chmod 700 "$tmp_bin"
    PREBUILT_BIN="$tmp_bin"
    return 0
}

stop_spinner() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
}

# Discard the private build-log directory.
#
# This used to live inside stop_spinner(), which the build-failure handler calls
# as its very first action -- so the log was deleted before the handler printed
# it, and every failed build reported an empty log plus a path that no longer
# existed. Cleanup is now separate and only runs on the success path and at
# exit, after any diagnostics have been shown.
discard_build_log() {
    if [[ -n "${BUILD_LOG_DIR:-}" ]]; then
        rm -rf -- "$BUILD_LOG_DIR"
        BUILD_LOG_DIR=""
    fi
}

stop_spinner_and_discard_log() {
    stop_spinner
    discard_build_log
}
trap stop_spinner_and_discard_log EXIT

if [[ "${CAELESTIA_TMUX_MASTER:-0}" == "0" ]]; then
    echo -n "Preparing Caelestia installer"
    {
        while true; do
            printf "."
            sleep 0.5
            printf "."
            sleep 0.5
            printf "."
            sleep 0.5
            printf "\b\b\b   \b\b\b"
        done
    } &
    SPINNER_PID=$!

    PREBUILT_BIN=""
    PREBUILT_DECLINED_REASON=""
    if [[ -z "${CAELESTIA_FORCE_BUILD_INSTALLER:-}" ]] && command -v curl >/dev/null 2>&1; then
        try_download_prebuilt_installer || true
    fi

    # Check and install requirements. Build tools are unnecessary when the
    # release binary was fetched successfully; tmux is still used by the UI.
    MISSING_PKGS=()
    if [[ -z "$PREBUILT_BIN" ]] && ! command -v g++ >/dev/null 2>&1; then
        MISSING_PKGS+=("g++")
    fi
    if [[ -z "$PREBUILT_BIN" ]] && ! command -v cmake >/dev/null 2>&1; then
        MISSING_PKGS+=("cmake")
    fi
    if [[ -z "$PREBUILT_BIN" ]] && ! command -v make >/dev/null 2>&1; then
        MISSING_PKGS+=("make")
    fi
    # tmux is used for the split-pane installer view unless explicitly disabled
    if [[ "${CAELESTIA_USE_TMUX:-1}" == "1" ]] && ! command -v tmux >/dev/null 2>&1; then
        MISSING_PKGS+=("tmux")
    fi

    if [ ${#MISSING_PKGS[@]} -ne 0 ]; then
        stop_spinner
        echo ""
        echo "Missing build tools: ${MISSING_PKGS[*]}. Installing..."
        if [[ "$BASE_DISTRO" == "arch" ]]; then
            if [[ "${CAELESTIA_USE_TMUX:-1}" == "1" ]]; then
                run_arch_pacman_install base-devel cmake tmux
            else
                run_arch_pacman_install base-devel cmake
            fi
        elif [[ "$BASE_DISTRO" == "fedora" ]]; then
            if [[ "${CAELESTIA_USE_TMUX:-1}" == "1" ]]; then
                sudo dnf install -y gcc-c++ cmake make tmux
            else
                sudo dnf install -y gcc-c++ cmake make
            fi
        elif [[ "$BASE_DISTRO" == "debian" ]]; then
            if [[ "${CAELESTIA_USE_TMUX:-1}" == "1" ]]; then
                sudo apt-get update && sudo apt-get install -y build-essential g++ cmake make tmux
            else
                sudo apt-get update && sudo apt-get install -y build-essential g++ cmake make
            fi
        else
            echo "Could not auto-install build tools. Please install manually: ${MISSING_PKGS[*]}"
            exit 1
        fi
        echo -n "Preparing Caelestia installer"
        {
            while true; do
                printf "."
                sleep 0.5
                printf "."
                sleep 0.5
                printf "."
                sleep 0.5
                printf "\b\b\b   \b\b\b"
            done
        } &
        SPINNER_PID=$!
    fi

    if [[ -n "$PREBUILT_BIN" ]]; then
        stop_spinner
        echo ""
        rm -f -- "$BIN"
        mv -- "$PREBUILT_BIN" "$BIN"
        rmdir "$(dirname "$PREBUILT_BIN")" 2>/dev/null || true
        echo "[OK]    Using verified prebuilt installer binary (skipped compilation)."
    else
        if [[ -n "${PREBUILT_DECLINED_REASON:-}" ]]; then
            stop_spinner
            echo ""
            echo "[INFO]  Building the installer from source: ${PREBUILT_DECLINED_REASON}."
            echo -n "Preparing Caelestia installer"
            {
                while true; do
                    printf "."; sleep 0.5
                    printf "."; sleep 0.5
                    printf "."; sleep 0.5
                    printf "\b\b\b   \b\b\b"
                done
            } &
            SPINNER_PID=$!
        fi
    BUILD_DIR="$BUNDLE_DIR/installer/build"
    BUILD_LOG_DIR="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/caelestia-build-XXXXXX")" || {
        echo "[FATAL] Failed to create a private build-log directory." >&2
        exit 1
    }
    BUILD_LOG="$BUILD_LOG_DIR/build.log"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    (
        cd "$BUILD_DIR" || exit 1
        cmake -DCMAKE_BUILD_TYPE=Release .. >"$BUILD_LOG" 2>&1 || exit 1
        make -j"$(nproc 2>/dev/null || echo 1)" >>"$BUILD_LOG" 2>&1 || exit 1
    ) || {
        stop_spinner
        echo ""
        echo "[FATAL] Failed to build the Caelestia installer." >&2

        # Copy the log somewhere that survives the EXIT trap before printing it,
        # so the path reported below is one the user can actually open.
        _saved_log="${XDG_CACHE_HOME:-$HOME/.cache}/caelestia-kde/installer-build.log"
        mkdir -p "$(dirname "$_saved_log")"
        if cp -- "$BUILD_LOG" "$_saved_log" 2>/dev/null; then
            :
        else
            _saved_log="$BUILD_LOG"
        fi

        echo "--- build log (last 60 lines) ---"
        if ! tail -n 60 -- "$BUILD_LOG"; then
            echo "(the build log could not be read: $BUILD_LOG)"
        fi
        echo "--- end build log ---"
        echo "Full log saved to: $_saved_log"
        exit 1
    }

    stop_spinner
    discard_build_log
    echo ""

    rm -f "$BIN"
    cp "$BUILD_DIR/caelestia-install" "$BIN" || {
        echo "[FATAL] Failed to copy the compiled Caelestia installer to $BIN." >&2
        exit 1
    }
    fi
fi

cleanup_install_state() {
    # This trap replaces the spinner/build-log trap installed above, so it has
    # to take over those responsibilities too.
    stop_spinner
    discard_build_log
    tput cnorm 2>/dev/null || true

    if [[ -n "${TMUX:-}" && "${CAELESTIA_TMUX_MASTER:-0}" == "1" ]]; then
        tmux kill-session -t caelestia_install 2>/dev/null || true
    fi
    if [[ "${CAELESTIA_IPC_CLEANUP:-0}" == "1" && -n "${CAELESTIA_IPC_DIR:-}" ]]; then
        rm -rf -- "$CAELESTIA_IPC_DIR"
    fi
}
trap cleanup_install_state EXIT

if [[ -z "${TMUX:-}" && "${CAELESTIA_NO_TMUX:-0}" == "0" && "${CAELESTIA_USE_TMUX:-1}" == "1" ]]; then
    # Kill any stale session first
    tmux kill-session -t caelestia_install 2>/dev/null || true

    export CAELESTIA_TMUX_MASTER=1
    CAELESTIA_IPC_DIR="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/caelestia-install-XXXXXX")" || {
        echo "[FATAL] Failed to create private installer IPC directory." >&2
        exit 1
    }
    chmod 700 "$CAELESTIA_IPC_DIR"
    export CAELESTIA_IPC_DIR CAELESTIA_IPC_CLEANUP=1
    mkfifo "$CAELESTIA_IPC_DIR/cmd" "$CAELESTIA_IPC_DIR/status"

    # Wrapper keeps the tmux pane alive after exit/crash for diagnostics.
    WRAPPER_SCRIPT="$CAELESTIA_IPC_DIR/tmux_wrapper.sh"
    printf -v args_str '%q ' "$0" "$@"
    cat > "$WRAPPER_SCRIPT" <<WRAPPER_EOF
#!/usr/bin/env bash
CAELESTIA_IPC_CLEANUP=0 bash $args_str
ec=\$?
echo ""
echo "============================================================"
echo "  installer session ended (exit code: \$ec)"
echo "============================================================"
echo ""
echo "Press Enter to close this window..."
read -r
exit \$ec
WRAPPER_EOF
    chmod +x "$WRAPPER_SCRIPT"

    printf -v _wrapper_cmd 'bash %q' "$WRAPPER_SCRIPT"
    tmux new-session -d -s caelestia_install "$_wrapper_cmd"
    # Keep pane visible on failure; close normally on success.
    tmux set-option -t caelestia_install remain-on-exit failed
    tmux set-option -t caelestia_install mouse on

    tmux attach-session -t caelestia_install
    _tmux_exit=$?

    # Surface inner-script diagnostics in the outer terminal.
    _needs_pause=0
    if [[ -s "$CAELESTIA_IPC_DIR/installer_err.log" ]]; then
        _reached_done=0
        if grep -q '\[installer\] done (success)' "$CAELESTIA_IPC_DIR/installer_err.log" 2>/dev/null; then
            _reached_done=1
        fi
        if [[ $_reached_done -eq 0 ]]; then
            stty sane 2>/dev/null || true
            tput cnorm 2>/dev/null || true
            echo ""
            echo "============================================================"
            echo "  INSTALLER DID NOT COMPLETE"
            echo "============================================================"
            echo ""
            echo "--- stderr output from installer ---"
            cat "$CAELESTIA_IPC_DIR/installer_err.log"
            echo "--- end stderr ---------------------"
            echo ""
            _needs_pause=1
        fi
    elif [[ $_tmux_exit -ne 0 ]]; then
        stty sane 2>/dev/null || true
        tput cnorm 2>/dev/null || true
        echo ""
        echo "============================================================"
        echo "  INSTALLER SESSION ENDED (exit code: $_tmux_exit)"
        echo "  No stderr log was produced — the binary may have crashed"
        echo "  or the tmux session may have failed to start entirely"
        echo "  (check for a stale tmux session or private installer IPC issues)."
        echo "============================================================"
        echo ""
        _needs_pause=1
    fi

    # Prevent terminal from auto-closing before the user can read output.
    if [[ $_needs_pause -eq 1 ]]; then
        echo "Press Enter to close this window..."
        read -r
    fi

    exit $_tmux_exit
fi

# Always capture diagnostics in a private directory; never fall back to /tmp.
if [[ -z "${CAELESTIA_IPC_DIR:-}" ]]; then
    CAELESTIA_IPC_DIR="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/caelestia-install-XXXXXX")" || {
        echo "[FATAL] Failed to create private installer runtime directory." >&2
        exit 1
    }
    chmod 700 "$CAELESTIA_IPC_DIR"
    export CAELESTIA_IPC_DIR CAELESTIA_IPC_CLEANUP=1
fi

if [[ ! -x "$BIN" ]]; then
    echo ""
    echo "============================================================"
    echo "  FATAL: Installer binary missing: $BIN"
    echo "  C++ compilation likely failed — check g++, cmake, make."
    echo "============================================================"
    echo ""
    echo "Press Enter to close this window..."
    read -r
    exit 1
fi

_installer_start=$(date +%s)
_installer_err_log="$CAELESTIA_IPC_DIR/installer_err.log"
if "$BIN" "$@" 2>"$_installer_err_log"; then
    _exit_code=0
else
    _exit_code=$?
fi
_installer_elapsed=$(($(date +%s) - _installer_start))

if [[ $_exit_code -eq 0 && -s "$PACKAGE_BEFORE" ]]; then
    caelestia_snapshot_packages "$PACKAGE_STATE_DIR/packages.after"
    comm -13 "$PACKAGE_BEFORE" "$PACKAGE_STATE_DIR/packages.after" > "$PACKAGE_MANIFEST" || true
fi

_reached_done=0
if grep -q '\[installer\] done (success)' "$CAELESTIA_IPC_DIR/installer_err.log" 2>/dev/null; then
    _reached_done=1
fi

_show_diagnostic=0
_diag_title=""

if [[ $_exit_code -ne 0 ]]; then
    _show_diagnostic=1
    _diag_title="INSTALLER FAILED (exit code: $_exit_code)"
elif [[ $_reached_done -eq 0 ]]; then
    _show_diagnostic=1
    if [[ $_installer_elapsed -lt 3 ]]; then
        _diag_title="INSTALLER EXITED PREMATURELY (ran ${_installer_elapsed}s, exit 0)"
    else
        _diag_title="INSTALLER EXITED UNEXPECTEDLY (no completion marker)"
    fi
elif [[ -s "$_installer_err_log" ]]; then
    _show_diagnostic=1
    _diag_title="INSTALLER COMPLETED (stderr output captured below)"
fi

if [[ $_show_diagnostic -eq 1 ]]; then
    # Reset terminal in case the binary left it in raw/alt-screen mode
    stty sane 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    printf '\033[0m\033[?1049l\033[?25h' 2>/dev/null || true

    echo ""
    echo "============================================================"
    echo "  $_diag_title"
    echo "============================================================"
    echo ""

    if [[ -s "$_installer_err_log" ]]; then
        echo "--- stderr output ---"
        cat "$_installer_err_log"
        echo "--- end stderr ------"
        echo ""
    else
        echo "(no stderr output captured)"
        echo ""
    fi

    if [[ $_exit_code -eq 139 ]]; then
        echo "Exit code 139 = SIGSEGV (segmentation fault / memory crash)."
    elif [[ $_exit_code -eq 127 ]]; then
        echo "Exit code 127 = command not found (missing shared library or binary)."
    elif [[ $_exit_code -eq 134 ]] || [[ $_exit_code -eq 135 ]]; then
        echo "Exit code $_exit_code = SIGABRT (aborted, possible assertion failure)."
    elif [[ $_exit_code -eq 0 ]] && [[ $_reached_done -eq 0 ]]; then
        echo "Binary exited cleanly (code 0) but never reached the summary screen."
        echo "This usually means it returned early before phase 6."
    fi
    echo ""

    echo "Press Enter to close this window..."
    read -r
fi

exit $_exit_code
