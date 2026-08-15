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
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

        # Reflector: rank pacman mirrors by speed. Install on-the-fly if
        # missing (single -Sy, not -Syy).
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

            as_root reflector "${reflector_args[@]}" --save /etc/pacman.d/mirrorlist >/dev/null 2>&1 || echo "[WARN]  reflector failed, continuing with current mirrors."
        fi

        # Re-rank CachyOS-specific mirrors (separate from Arch mirrorlist).
        if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
            echo "[INFO]  Ranking CachyOS mirrors by download speed..."
            as_root cachyos-rate-mirrors >/dev/null 2>&1 || echo "[WARN]  cachyos-rate-mirrors failed, continuing with current mirrors."
        fi

        # Pre-install dos2unix for CRLF normalization later.
        if ! command -v dos2unix >/dev/null 2>&1; then
            as_root pacman -Syu --noconfirm dos2unix >/dev/null 2>&1 || true
        fi

        as_root pacman -Syu --noconfirm >/dev/null 2>&1 || echo "[WARN]  Failed to refresh pacman sources early. Continuing..."
        unset -f as_root
    fi
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
case "$BASE_DISTRO" in
    arch) pacman -Qq 2>/dev/null | sort -u > "$PACKAGE_BEFORE" || true ;;
    fedora) dnf repoquery --installed --qf '%{name}' 2>/dev/null | sort -u > "$PACKAGE_BEFORE" || true ;;
    debian) dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u > "$PACKAGE_BEFORE" || true ;;
    *) : > "$PACKAGE_BEFORE" ;;
esac
export PACKAGE_STATE_DIR PACKAGE_BEFORE PACKAGE_MANIFEST

# Only run in the outer (pre-tmux) invocation.
if [[ "${CAELESTIA_TMUX_MASTER:-0}" == "0" ]]; then
    silent_refresh_pacman_sources
fi

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

stop_spinner() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
}
trap stop_spinner EXIT

if [[ "${CAELESTIA_TMUX_MASTER:-0}" == "0" ]]; then
    echo -n "Compiling Caelestia installer"
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

    # Check and install requirements
    MISSING_PKGS=()
    if ! command -v g++ >/dev/null 2>&1; then
        MISSING_PKGS+=("g++")
    fi
    if ! command -v cmake >/dev/null 2>&1; then
        MISSING_PKGS+=("cmake")
    fi
    if ! command -v make >/dev/null 2>&1; then
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
        echo -n "Compiling Caelestia installer"
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

    BUILD_DIR="$BUNDLE_DIR/installer/build"
    BUILD_LOG="/tmp/caelestia_build.log"
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
        echo "--- build log (last 60 lines) ---"
        tail -n 60 "$BUILD_LOG" 2>/dev/null || cat "$BUILD_LOG" 2>/dev/null
        echo "--- end build log ---"
        echo "Full log saved to: $BUILD_LOG"
        exit 1
    }

    stop_spinner
    echo ""

    rm -f "$BIN"
    cp "$BUILD_DIR/caelestia-install" "$BIN" || {
        echo "[FATAL] Failed to copy the compiled Caelestia installer to $BIN." >&2
        exit 1
    }
fi

cleanup_install_state() {
    # This trap replaces the spinner-only trap installed above, so it has to
    # take over that responsibility too.
    stop_spinner
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
    case "$BASE_DISTRO" in
        arch) pacman -Qq 2>/dev/null | sort -u > "$PACKAGE_STATE_DIR/packages.after" || true ;;
        fedora) dnf repoquery --installed --qf '%{name}' 2>/dev/null | sort -u > "$PACKAGE_STATE_DIR/packages.after" || true ;;
        debian) dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u > "$PACKAGE_STATE_DIR/packages.after" || true ;;
        *) : > "$PACKAGE_STATE_DIR/packages.after" ;;
    esac
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
