#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
# ==============================================================
#   Caelestia KDE Port - Unified Updater
# ==============================================================

set -uo pipefail

die()  { echo "[FATAL] $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }
ok()   { echo "[OK]    $*"; }
warn() { echo "[WARN]  $*"; }

verify_update_commit() {
    local trusted_fingerprint="968479A1AFF927E37D1A566BB5690EEEBB952194"
    local verify_home fingerprints status valid_fingerprint
    verify_home="$(mktemp -d "${TMPDIR:-/tmp}/caelestia-verify.XXXXXX")" || die "Could not create verification directory"
    chmod 700 "$verify_home"
    trap 'rm -rf -- "${verify_home:-}"' EXIT
    curl -fsSL --proto '=https' --tlsv1.2 https://github.com/web-flow.gpg -o "$verify_home/trusted.asc" || die "Could not download trusted public key"
    fingerprints="$(gpg --homedir "$verify_home" --batch --with-colons --import-options show-only --import "$verify_home/trusted.asc" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }')"
    grep -Fxq "$trusted_fingerprint" <<< "$fingerprints" || die "Trusted signer fingerprint mismatch"
    gpg --homedir "$verify_home" --batch --import "$verify_home/trusted.asc" >/dev/null 2>&1 || die "Could not import trusted public key"
    status="$(GNUPGHOME="$verify_home" git -C "$BUNDLE_DIR" -c gpg.program=gpg verify-commit --raw HEAD 2>&1 || true)"
    valid_fingerprint="$(printf '%s\n' "$status" | sed -n 's/^\[GNUPG:\] VALIDSIG \([0-9A-F]*\) .*/\1/p' | head -n1)"
    rm -rf -- "$verify_home"
    trap - EXIT
    [[ "$valid_fingerprint" == "$trusted_fingerprint" ]] || die "Update commit is not trusted"
}

section() {
    local title="$1"
    echo
    echo "-------------------------------------------------------------"
    echo "  $title"
    echo "-------------------------------------------------------------"
}

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BUNDLE_DIR
EXPECTED_COMMIT="${CAELESTIA_UPDATE_COMMIT:-}"
if [[ -z "$EXPECTED_COMMIT" && "${CAELESTIA_ALLOW_UNVERIFIED_UPDATE:-}" != "true" ]]; then
    cat >&2 <<'USAGE'
[FATAL] Refusing mutable update: set CAELESTIA_UPDATE_COMMIT to a reviewed commit.

This script updates an existing git checkout to one specific, reviewed commit.
It deliberately will not follow a moving branch head.

  For normal updates, use the release-tracking updater instead:
      caelestia-update main

  To pin this checkout to a commit you have reviewed:
      CAELESTIA_UPDATE_COMMIT=<40-char-sha> ./update.sh

  To list candidate commits:
      git fetch origin && git log --oneline -20 origin/main
USAGE
    exit 1
fi
cd "$BUNDLE_DIR" || die "Could not enter $BUNDLE_DIR"

# Prevent concurrent update runs in a private directory.
LOCK_DIR="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/caelestia"
mkdir -p "$LOCK_DIR"
chmod 700 "$LOCK_DIR"
exec 9>"$LOCK_DIR/update.lock"
flock -n 9 || { echo "Another Caelestia update is already running."; exit 1; }

section "Step 1 - Source Code Update"

info "Checking dependencies..."
for cmd in git cmake make; do
    if ! command -v "$cmd" &> /dev/null; then
        die "Required command '$cmd' is missing. Please install it first."
    fi
done

if [ -d "$BUNDLE_DIR/.git" ]; then
    info "Fetching remote branches..."
    git -C "$BUNDLE_DIR" fetch origin || warn "Failed to fetch from origin. Network issue?"

    STASHED=0
    # Safely stash uncommitted changes to avoid merge conflicts
    if ! git -C "$BUNDLE_DIR" diff-index --quiet HEAD --; then
        warn "You have uncommitted changes in the repository."
        info "Stashing your local changes..."
        git -C "$BUNDLE_DIR" stash -m "Auto-stash before Caelestia update" || die "Failed to stash changes."
        STASHED=1
    fi

    # Branch selection only matters on the unverified/mutable path. When
    # CAELESTIA_UPDATE_COMMIT is set -- which the guard at the top of this
    # script makes the normal case -- the commit fully determines what is
    # checked out, and asking the user to pick a branch first was dead UI.
    if [[ -n "$EXPECTED_COMMIT" ]]; then
        [[ "$EXPECTED_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || die "CAELESTIA_UPDATE_COMMIT must be a full 40-character commit hash"
        info "Checking out reviewed commit $EXPECTED_COMMIT..."
        git -C "$BUNDLE_DIR" fetch --depth=1 origin "$EXPECTED_COMMIT" || die "Failed to fetch requested update commit"
        git -C "$BUNDLE_DIR" checkout --detach "$EXPECTED_COMMIT" || die "Failed to checkout requested update commit"
    else
        if [ -n "${1:-}" ]; then
            BRANCH="$1"
            info "Using provided branch: $BRANCH"
        elif [ -t 1 ]; then
            echo
            info "Available remote branches (default: main):"
            select BRANCH in main dev; do
                if [ -z "$REPLY" ]; then
                    BRANCH="main"
                    info "Defaulted to branch: $BRANCH"
                    break
                elif [ -n "$BRANCH" ]; then
                    info "Selected branch: $BRANCH"
                    break
                else
                    warn "Invalid selection. Please enter a valid number or press Enter for main."
                fi
            done
        else
            BRANCH=$(git -C "$BUNDLE_DIR" rev-parse --abbrev-ref HEAD)
            if [ -z "$BRANCH" ] || [ "$BRANCH" == "HEAD" ]; then
                BRANCH="main"
            fi
            info "Auto-detected branch: $BRANCH (GUI Mode)"
        fi

        if [[ "$BRANCH" != "main" && "$BRANCH" != "dev" ]]; then
            warn "Branch '$BRANCH' is not allowed. Falling back to main."
            BRANCH="main"
        elif ! git -C "$BUNDLE_DIR" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
            warn "Remote branch '$BRANCH' not found. Falling back to main."
            BRANCH="main"
        fi

        info "Checking out $BRANCH..."
        git -C "$BUNDLE_DIR" checkout "$BRANCH" || die "Failed to checkout $BRANCH"
        info "Pulling latest changes for $BRANCH..."
        git -C "$BUNDLE_DIR" pull --ff-only origin "$BRANCH" || die "Refusing non-fast-forward update for origin/$BRANCH"
    fi

    if [[ "${CAELESTIA_ALLOW_UNVERIFIED_UPDATE:-}" != "true" ]]; then
        verify_update_commit
    fi

    if [[ -f "$BUNDLE_DIR/.gitmodules" ]]; then
        info "Syncing and updating submodules..."
        git -C "$BUNDLE_DIR" submodule sync --recursive || die "Failed to sync submodules"
        git -C "$BUNDLE_DIR" submodule update --init --recursive || \
            die "Failed to initialize submodules"
    fi

    if [ "$STASHED" -eq 1 ]; then
        echo
        warn "Your local uncommitted changes were backed up to the git stash to allow a clean update."
        warn "If you need to recover them, you can manually run 'git stash pop' later."
    fi
else
    warn "Not a git repository. Skipping source code update."
fi

section "Step 2 - Core Updates"

if [ ! -f "$BUNDLE_DIR/scripts/03-deploy-configs.sh" ] || [ ! -f "$BUNDLE_DIR/scripts/08-build-shell.sh" ]; then
    die "Critical internal scripts are missing from $BUNDLE_DIR/scripts/"
fi

# Cache sudo credentials once now so sub-scripts don't each re-prompt.
# The keepalive loop refreshes the timestamp with -nv (non-interactive
# extend) so it never expires, even during long CMake builds.
#
# When running without a terminal (e.g. launched from the shell UI), we
# use ksshaskpass or pkexec for the initial prompt and export
# SUDO_ASKPASS for every child process.

if [ "$EUID" -ne 0 ]; then
    # Determine the best interactive helper for the initial prompt. Root is
    # optional for the update itself (the only root-requiring step, the
    # workspace-tracker effect install, warns and continues), so a failed
    # priming must not abort the whole update — e.g. when pkexec rejects the
    # environment's SHELL or no polkit agent is reachable.
    if [ -t 1 ]; then
        sudo -v || warn "Could not prime sudo; continuing without root (system-level steps will be skipped)."
    elif command -v ksshaskpass &> /dev/null; then
        SUDO_ASKPASS="$(command -v ksshaskpass)"
        export SUDO_ASKPASS
        sudo -A -v || warn "Could not prime sudo; continuing without root (system-level steps will be skipped)."
    elif command -v pkexec &> /dev/null; then
        info "Requesting administrator privileges via pkexec..."
        pkexec true || warn "Could not prime administrator privileges; continuing without root (system-level steps will be skipped)."
    else
        warn "No privilege helper available (terminal, ksshaskpass, pkexec); continuing without root — system-level steps will be skipped."
    fi

    # Background keepalive: refresh the sudo timestamp every 30 seconds.
    # Using -nv instead of -v means it quietly extends the timestamp
    # without ever re-prompting.
    (
        while kill -0 "$$" 2>/dev/null; do
            sleep 30
            sudo -nv 2>/dev/null || true
        done
    ) &
    SUDO_KEEPER_PID=$!
    trap 'kill "$SUDO_KEEPER_PID" 2>/dev/null || true' EXIT
fi

# Determine the best escalation helper for GUI environments.
# Tries cached credentials first (-n) before falling back to prompting.
run_elevated() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    elif sudo -n true 2>/dev/null; then
        sudo -n "$@"
    elif [ -t 1 ]; then
        sudo "$@"
    elif [ -n "${SUDO_ASKPASS:-}" ]; then
        sudo -A "$@"
    elif command -v pkexec &> /dev/null; then
        pkexec "$@"
    else
        die "Cannot elevate privileges. Please install ksshaskpass, pkexec, or run from a terminal."
    fi
}

# Apply config updates and rebuild the shell UI.  The native C++ plugin
# backend talks directly to KWin/Wayland — no Python daemon or mock
# hyprctl binary is involved.
bash "$BUNDLE_DIR/scripts/03-deploy-configs.sh" || die "Config deployment failed."

info "Building Caelestia Shell UI..."
bash "$BUNDLE_DIR/scripts/08-build-shell.sh" || die "Shell build failed."

# Re-apply idempotent system tweaks (KDE settings, CLI patches, etc.)
# so they survive package upgrades that may have overwritten patches.
info "Re-applying system tweaks..."
bash "$BUNDLE_DIR/scripts/09-system-tweaks.sh" || warn "System tweaks step reported errors (non-fatal)."

# Kill the keepalive background process now that sudo is no longer needed
if [ -n "${SUDO_KEEPER_PID:-}" ] && kill -0 "$SUDO_KEEPER_PID" 2>/dev/null; then
    kill "$SUDO_KEEPER_PID" 2>/dev/null || true
fi

section "Update Completed Successfully"
echo
info "The core shell and bridge scripts have been updated."
info "System tweaks (OSD, desktops, CLI patches) have been re-applied to keep KDE in sync."
echo
echo "Restarting bridge and shell to apply changes..."

if command -v caelestia >/dev/null 2>&1; then
    CAELESTIA_BIN=$(command -v caelestia)
elif [[ -x "$HOME/.local/bin/caelestia" ]]; then
    CAELESTIA_BIN="$HOME/.local/bin/caelestia"
elif [[ -x "/usr/local/bin/caelestia" ]]; then
    CAELESTIA_BIN="/usr/local/bin/caelestia"
elif [[ -x "/usr/bin/caelestia" ]]; then
    CAELESTIA_BIN="/usr/bin/caelestia"
else
    CAELESTIA_BIN="caelestia"
fi

# Resolve a reliable way to talk to the running shell instance.
# Prefer the (now-patched) CLI; fall back to the path-based IPC wrapper.
SHELL_IPC=""
if [[ -x "$HOME/.local/bin/caelestia-shell-ipc" ]]; then
    SHELL_IPC="$HOME/.local/bin/caelestia-shell-ipc"
fi

# Kill the running shell – try CLI first, then the IPC wrapper, then pkill.
if "$CAELESTIA_BIN" shell -k 2>/dev/null; then
    : # CLI succeeded
elif [[ -n "$SHELL_IPC" ]] && "$SHELL_IPC" quit 2>/dev/null; then
    : # IPC wrapper succeeded
else
    pkill -f "quickshell.*caelestia/shell.qml" 2>/dev/null || true
fi

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia"
SCHEME_FILE="$STATE_DIR/scheme.json"
i=0
while [[ $i -lt 15 && ! -s "$SCHEME_FILE" ]]; do
    sleep 1
    i=$((i + 1))
done

# Start the shell – the CLI was patched for path-based resolution during build.
# Fall back to the IPC wrapper or direct quickshell if the CLI is unavailable.
if command -v "$CAELESTIA_BIN" >/dev/null 2>&1; then
    "$CAELESTIA_BIN" shell -d >/dev/null 2>&1 &
elif [[ -n "$SHELL_IPC" ]]; then
    "$SHELL_IPC" start 2>/dev/null &
else
    QUICKSHELL_PATH="$(command -v quickshell 2>/dev/null || command -v qs 2>/dev/null || echo quickshell)"
    export QML2_IMPORT_PATH="$HOME/.local/lib/qt6/qml"
    export CAELESTIA_LIB_DIR="$HOME/.local/lib/caelestia"
    stdbuf -oL -eL "$QUICKSHELL_PATH" -d -n -p "$HOME/.config/quickshell/caelestia/shell.qml" >/dev/null 2>&1 &
fi

sleep 1
if ! pgrep -x quickshell >/dev/null 2>&1 && ! pgrep -x qs >/dev/null 2>&1; then
    echo "Shell restart failed: no quickshell process is running." >&2
    exit 1
fi
echo "Shell restarted successfully!"
echo
echo "If the shell doesn't start, please restart it manually by running: $CAELESTIA_BIN shell -d"
