#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"

set -uo pipefail
# shell-quality: allow-no-errexit -- each update stage reports failure and preserves recovery.

source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/privileges.sh"
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/install-fs.sh"
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/submodules.sh"

section() {
    local title="$1"
    echo
    echo "-------------------------------------------------------------"
    echo "  $title"
    echo "-------------------------------------------------------------"
}

export BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BUNDLE_DIR" || die "Could not enter $BUNDLE_DIR"

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
    if ! git -C "$BUNDLE_DIR" diff-index --quiet HEAD --; then
        warn "You have uncommitted changes in the repository."
        info "Stashing your local changes..."
        git -C "$BUNDLE_DIR" stash -m "Auto-stash before Caelestia update" || die "Failed to stash changes."
        STASHED=1
    fi

    if [ -n "${1:-}" ]; then
        BRANCH="$1"
        if [[ "$BRANCH" != "main" && "$BRANCH" != "dev" ]]; then
            warn "Branch '$BRANCH' is not allowed. Falling back to main."
            BRANCH="main"
        fi
        info "Using provided branch: $BRANCH"
    else
        if [ -t 1 ]; then
            BRANCHES="main dev"
            echo
            info "Available remote branches (default: main):"
            select BRANCH in $BRANCHES; do
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
    fi

    if [[ "$BRANCH" != "main" && "$BRANCH" != "dev" ]]; then
        warn "Branch '$BRANCH' is not allowed. Falling back to main."
        BRANCH="main"
    elif ! git -C "$BUNDLE_DIR" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
        warn "Remote branch '$BRANCH' not found. Falling back to main."
        BRANCH="main"
    fi

    EXPECTED_COMMIT="${CAELESTIA_UPDATE_COMMIT:-}"
    if [[ -n "$EXPECTED_COMMIT" ]]; then
        [[ "$EXPECTED_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || die "Expected a full commit hash"
        git -C "$BUNDLE_DIR" fetch origin "$EXPECTED_COMMIT" || die "Failed to fetch reviewed update"
        UPDATE_REF="$EXPECTED_COMMIT"
    else
        UPDATE_REF="origin/$BRANCH"
    fi
    if [[ "${CAELESTIA_ALLOW_UNVERIFIED_UPDATE:-0}" != "1" && "${CAELESTIA_ALLOW_UNVERIFIED_UPDATE:-}" != "true" ]]; then
        bash "$BUNDLE_DIR/scripts/verify-update-source.sh" "$BUNDLE_DIR" "$UPDATE_REF" || die "Update signature verification failed"
    fi
    info "Checking out $BRANCH..."
    if [[ -n "$EXPECTED_COMMIT" ]]; then
        git -C "$BUNDLE_DIR" checkout --detach "$UPDATE_REF" || die "Failed to checkout reviewed update"
    else
        git -C "$BUNDLE_DIR" checkout "$BRANCH" || die "Failed to checkout $BRANCH"
    fi

    info "Pulling latest changes for $BRANCH..."
    git -C "$BUNDLE_DIR" merge --ff-only "$UPDATE_REF" || die "Update is not a fast-forward"

    if [[ -f "$BUNDLE_DIR/.gitmodules" ]]; then
        info "Syncing submodules..."
        prune_removed_submodules "$BUNDLE_DIR"
        git -C "$BUNDLE_DIR" submodule sync --recursive >/dev/null 2>&1 || true
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

if [ -f "$HOME/.config/caelestia-kde/install.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$HOME/.config/caelestia-kde/install.env"
    set +a
fi

trap 'caelestia_stop_sudo_keepalive' EXIT

bash "$BUNDLE_DIR/scripts/03-deploy-configs.sh" || die "Config deployment failed."

info "Building the Caelestia shell UI..."
bash "$BUNDLE_DIR/scripts/08-build-shell.sh" || die "Shell build failed."

info "Re-applying system tweaks..."
bash "$BUNDLE_DIR/scripts/09-system-tweaks.sh" || warn "System tweaks step reported errors (non-fatal)."

caelestia_stop_sudo_keepalive

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

SHELL_IPC=""
if [[ -x "$HOME/.local/bin/caelestia-shell-ipc" ]]; then
    SHELL_IPC="$HOME/.local/bin/caelestia-shell-ipc"
fi

if "$CAELESTIA_BIN" shell -k 2>/dev/null; then
    : # CLI succeeded
elif [[ -n "$SHELL_IPC" ]] && "$SHELL_IPC" quit 2>/dev/null; then
    : # IPC wrapper succeeded
else
    pkill -f "quickshell.*caelestia/shell.qml" 2>/dev/null || true
fi

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia"
SCHEME_FILE="$STATE_DIR/scheme.json"

QUICKSHELL_PATH="$(command -v quickshell 2>/dev/null || command -v qs 2>/dev/null || echo quickshell)"
RESTART_SCRIPT="$BUNDLE_DIR/shell/scripts/restart_shell.sh"

if [[ -x "$RESTART_SCRIPT" ]] && bash "$RESTART_SCRIPT" 2>/dev/null; then
    : # Restarted via the KDE-managed autostart unit — env identical to login startup
elif [[ -n "$SHELL_IPC" ]]; then
    "$SHELL_IPC" start 2>/dev/null &
elif command -v systemd-run >/dev/null 2>&1; then
    systemd-run --user --quiet --collect --unit=caelestia-shell \
        --description="Caelestia Shell" \
        --setenv=QML2_IMPORT_PATH="$HOME/.local/lib/qt6/qml:$HOME/.config/quickshell/caelestia" \
        --setenv=CAELESTIA_LIB_DIR="$HOME/.local/lib/caelestia" \
        --setenv=QS_NO_RELOAD_POPUP=1 \
        --setenv=QS_DROP_EXPENSIVE_FONTS=1 \
        --setenv=QS_DISABLE_CRASH_HANDLER=1 \
        --setenv=QSG_RENDER_LOOP=threaded \
        --setenv=QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000 \
        -- "$QUICKSHELL_PATH" -n -p "$HOME/.config/quickshell/caelestia/shell.qml" &
else
    export QML2_IMPORT_PATH="$HOME/.local/lib/qt6/qml:$HOME/.config/quickshell/caelestia"
    export CAELESTIA_LIB_DIR="$HOME/.local/lib/caelestia"
    export QS_NO_RELOAD_POPUP=1
    export QS_DROP_EXPENSIVE_FONTS=1
    export QS_DISABLE_CRASH_HANDLER=1
    export QSG_RENDER_LOOP=threaded
    export QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000
    stdbuf -oL -eL "$QUICKSHELL_PATH" -n -p "$HOME/.config/quickshell/caelestia/shell.qml" >/dev/null 2>&1 &
fi

if ! wait_for_nonempty_file "$SCHEME_FILE" 15; then
    warn "The restarted shell has not written $SCHEME_FILE yet; the lock screen may fall back to its default colors."
fi

echo "Shell restarted successfully!"
echo
echo "If the shell doesn't start, restart it with the same wrapper the shell uses:"
echo "  bash \"\$HOME/.config/quickshell/caelestia/scripts/restart_shell.sh\""
echo "Check logs by running: $CAELESTIA_BIN shell -l"
