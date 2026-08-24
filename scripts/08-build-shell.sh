#!/usr/bin/env bash

set -euo pipefail

CYAN="\033[0;36m"
GREEN="\033[0;32m"
YELLOW="\033[38;5;220m"
RED="\033[0;31m"
RST="\033[0m"

info() { echo -e "${CYAN}[INFO]  $*${RST}"; }
ok()   { echo -e "${GREEN}[OK]    $*${RST}"; }
warn() { echo -e "${YELLOW}[WARN]  $*${RST}"; }
err()  { echo -e "${RED}[ERR]   $*${RST}"; }
die()  { echo -e "${RED}[ERR]   $*${RST}"; exit 1; }

BUNDLE_DIR="${BUNDLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SHELL_DIR="$BUNDLE_DIR/shell"


if [[ "${CAELESTIA_SETUP_RUNNING:-0}" == "0" ]]; then
    info "Running standalone update mode... syncing submodules first."

    if [[ -f "$BUNDLE_DIR/.gitmodules" ]]; then
        info "Initializing all submodules..."
        # -C "$BUNDLE_DIR": these ran against the caller's working directory, so
        # invoking the script by absolute path from anywhere but the repo failed
        # with a bare "Failed to initialize all submodules".
        git -C "$BUNDLE_DIR" submodule sync --recursive >/dev/null 2>&1 ||
            die "Failed to synchronize submodule URLs"
        if ! submodule_err="$(git -C "$BUNDLE_DIR" submodule update --init --recursive --force 2>&1)"; then
            printf '%s\n' "$submodule_err" >&2
            die "Failed to initialize all submodules"
        fi

        # Pin plasma-wallpaper-application to the tagged release.
        WALLPAPER_DIR="$BUNDLE_DIR/src/plasma-wallpaper-application"
        WALLPAPER_TAG="v1.2"
        if [[ -e "$WALLPAPER_DIR/.git" ]]; then
            info "Pinning plasma-wallpaper-application to tag $WALLPAPER_TAG..."
            git -C "$WALLPAPER_DIR" fetch --tags --quiet 2>/dev/null || true
            git -C "$WALLPAPER_DIR" checkout "tags/$WALLPAPER_TAG" --quiet 2>/dev/null || \
                warn "Could not checkout tag $WALLPAPER_TAG for plasma-wallpaper-application; using current HEAD."
        fi
    fi

    info "Installing Caelestia Services..."
    if [[ -f "$BUNDLE_DIR/scripts/06-services.sh" ]]; then
        bash "$BUNDLE_DIR/scripts/06-services.sh" || warn "06-services.sh failed"
    fi

    info "Installing plasma-wallpaper-application..."
    if [[ -f "$BUNDLE_DIR/scripts/02-packages.sh" ]]; then
        bash "$BUNDLE_DIR/scripts/02-packages.sh" || warn "02-packages.sh failed"
    else
        warn "02-packages.sh not found; skipping wallpaper plugin installation."
    fi

    info "Installing qt6-wayland if missing..."
    if command -v pacman >/dev/null; then
        info "Installing via pacman..."
        sudo pacman -S --needed qt6-wayland kpipewire kglobalaccel kglobalacceld --noconfirm || warn "qt6-wayland install failed..."
    elif command -v dnf >/dev/null; then
        info "Installing via dnf..."
        sudo dnf install qt6-qtwayland qt6-qtwayland-devel kf6-kglobalaccel-devel kf6-kwindowsystem-devel qt6-qtbase-private-devel kf6-kpipewire kf6-kpipewire-devel -y || warn "qt6-qtwayland qt6-qtwayland-devel kf6-kglobalaccel-devel qt6-qtbase-private-devel install failed..."
    elif command -v apt-get >/dev/null; then
        info "Installing via apt..."
        sudo apt-get update && sudo apt-get install -y qt6-wayland qt6-wayland-dev libkf6globalaccel-dev libkf6windowsystem-dev qt6-base-private-dev libkf6kpipewire-dev || warn "apt install failed..."
    fi

    if [[ "${CAELESTIA_SKIP_DEPLOY:-0}" == "0" ]]; then
        info "Configuring KDE Lock Screen to use Caelestia..."
        WALLPAPER_STAMP="${XDG_CACHE_HOME:-$HOME/.cache}/caelestia-kde/wallpaper-plugin-installed"
        PLUGIN_OK=false
        if [[ "${CAELESTIA_WALLPAPER_PLUGIN_INSTALLED:-false}" == "true" ]]; then
            PLUGIN_OK=true
        elif command -v kpackagetool6 >/dev/null 2>&1 \
            && kpackagetool6 --list -t Plasma/Wallpaper 2>/dev/null \
            | grep -q "net.dosowisko.PlasmaApplicationWallpaper"; then
            PLUGIN_OK=true
        elif ! command -v kpackagetool6 >/dev/null 2>&1 && [[ -f "$WALLPAPER_STAMP" ]]; then
            PLUGIN_OK=true
        fi

        if $PLUGIN_OK && command -v kwriteconfig6 >/dev/null 2>&1; then
            kwriteconfig6 --file kscreenlockerrc --group Greeter --key WallpaperPlugin net.dosowisko.PlasmaApplicationWallpaper
            kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group net.dosowisko.PlasmaApplicationWallpaper --group General --key command "quickshell -p $HOME/.config/quickshell/caelestia/lockscreen.qml"
            kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group net.dosowisko.PlasmaApplicationWallpaper --group General --key fps 1
            kwriteconfig6 --file kscreenlockerrc --group Greeter --group LnF --group General --key alwaysShowClock false
            kwriteconfig6 --file kscreenlockerrc --group Greeter --group LnF --group General --key showMediaControls false
            ok "KDE Lock Screen configured."
        elif ! $PLUGIN_OK; then
            warn "plasma-wallpaper-application plugin not installed. Skipping KDE Lock Screen configuration."
        else
            warn "KDE config tools not found. Skipping KDE Lock Screen configuration."
        fi
    else
        info "KDE Lock Screen configuration skipped."
    fi

    info "Deleting yet-another-monochrome-icon-set for lag free update..."
    if [ -z "${SHELL_DIR-}" ]; then
        warn "SHELL_DIR is not set. Aborting deletion to prevent system damage."
        return 1 2>/dev/null || exit 1
    fi
    TARGET_DIR="$SHELL_DIR/assets/icons/yet-another-monochrome-icon-set"
    if [ -d "$TARGET_DIR" ]; then
        if ! rm -rf "$TARGET_DIR"; then
            warn "Failed to delete yet-another-monochrome-icon-set."
            return 1 2>/dev/null || exit 1
        fi
    fi

    info "Updating autostart environment variables"
    if [[ -f "$BUNDLE_DIR/scripts/10-autostart.sh" ]]; then
        bash "$BUNDLE_DIR/scripts/10-autostart.sh" || warn "10-autostart.sh failed"
    fi
fi

# UPDATER ONLY BLOCK END

info "Building Caelestia Shell..."

if [ ! -d "$SHELL_DIR" ]; then
    err "Shell directory not found at $SHELL_DIR!"
    exit 1
fi

if command -v python3 >/dev/null 2>&1 && [[ -f "$BUNDLE_DIR/.github/scripts/check_qml_deployment.py" ]]; then
    python3 "$BUNDLE_DIR/.github/scripts/check_qml_deployment.py" --source-root "$SHELL_DIR" || {
        err "QML source compatibility validation failed."
        exit 1
    }
fi

cd "$SHELL_DIR" || exit 1

info "Configuring CMake..."
rm -rf build
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOME/.local" -DINSTALL_QSCONFDIR="$HOME/.config/quickshell/caelestia" -DINSTALL_LIBDIR="lib/caelestia" -DINSTALL_QMLDIR="lib/qt6/qml" || {
    err "CMake configuration failed."
    exit 1
}

info "Building..."
cmake --build build -j"$(nproc)" || {
    err "Build failed."
    exit 1
}

info "Installing to user local dir..."
cmake --install build || {
    err "Installation failed."
    exit 1
}

info "Building and installing workspace-tracker KWin Effect..."
rm -rf kwin-effects/workspace-tracker/build
cmake -B kwin-effects/workspace-tracker/build -S kwin-effects/workspace-tracker -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr > /dev/null || {
    warn "Workspace tracker configuration failed."
}
cmake --build kwin-effects/workspace-tracker/build -j"$(nproc)" > /dev/null || {
    warn "Workspace tracker build failed."
}
sudo cmake --install kwin-effects/workspace-tracker/build > /dev/null || {
    warn "Workspace tracker system installation failed."
}

if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kwinrc --group Plugins --key kwin_workspace_trackerEnabled true
fi

qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
ok "Installed workspace-tracker to KDE."

# Validate every generated QML module before declaring success. Checking only
# Caelestia.Config lets a partial install reach Quickshell and fail as a large
# cascade of "Type unavailable" errors.
QML_BASE="$HOME/.local/lib/qt6/qml"
QML_MODULES=(
    Caelestia
    Caelestia/Components
    Caelestia/Config
    Caelestia/Internal
    Caelestia/Models
    Caelestia/Services
    Caelestia/Blobs
    Caelestia/Images
    Caelestia/Layouts
    M3Shapes
)

for module in "${QML_MODULES[@]}"; do
    module_dir="$QML_BASE/$module"
    if [[ ! -f "$module_dir/qmldir" ]]; then
        err "Missing QML module metadata: $module_dir/qmldir"
        exit 1
    fi

    shopt -s nullglob
    plugin_files=("$module_dir"/*.so)
    shopt -u nullglob
    if [[ ${#plugin_files[@]} -eq 0 ]]; then
        err "Missing QML plugin library in $module_dir"
        exit 1
    fi
done

export QML2_IMPORT_PATH="$QML_BASE${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"

# Add wrapper config to bashrc/fish.
#
# Guard on a sentinel we actually write. The previous guard looked for
# "QML2_IMPORT_PATH=.*caelestia", but the line written is
# `export QML2_IMPORT_PATH="$HOME/.local/lib/qt6/qml"` -- no "caelestia" after
# the '='. The grep never matched, so every install, update and rebuild
# appended another copy, and uninstall.sh (which reused the same broken
# pattern) could never remove them.
CAELESTIA_RC_MARKER="# >>> caelestia shell environment >>>"
CAELESTIA_RC_END="# <<< caelestia shell environment <<<"

append_rc_block() {
    local rc_file="$1" style="$2"

    # Drop any previous block, including ones written before the markers
    # existed, so repeated runs converge on exactly one copy.
    if [[ -f "$rc_file" ]]; then
        if grep -qF "$CAELESTIA_RC_MARKER" "$rc_file"; then
            sed -i "\\|^${CAELESTIA_RC_MARKER}\$|,\\|^${CAELESTIA_RC_END}\$|d" "$rc_file"
        fi
        sed -i '/^export QML2_IMPORT_PATH="\$HOME\/\.local\/lib\/qt6\/qml"$/d;/^export CAELESTIA_LIB_DIR="\$HOME\/\.local\/lib\/caelestia"$/d' "$rc_file"
        sed -i '/^set -gx QML2_IMPORT_PATH "\$HOME\/\.local\/lib\/qt6\/qml"$/d;/^set -gx CAELESTIA_LIB_DIR "\$HOME\/\.local\/lib\/caelestia"$/d' "$rc_file"
    fi

    {
        printf '%s\n' "$CAELESTIA_RC_MARKER"
        if [[ "$style" == "fish" ]]; then
            printf '%s\n' 'set -gx QML2_IMPORT_PATH "$HOME/.local/lib/qt6/qml"'
            printf '%s\n' 'set -gx CAELESTIA_LIB_DIR "$HOME/.local/lib/caelestia"'
            printf '%s\n' 'set -gx CAELESTIA_COMPAT_LIB_DIR "$HOME/.local/lib/caelestia/compat"'
        else
            printf '%s\n' 'export QML2_IMPORT_PATH="$HOME/.local/lib/qt6/qml"'
            printf '%s\n' 'export CAELESTIA_LIB_DIR="$HOME/.local/lib/caelestia"'
            printf '%s\n' 'export CAELESTIA_COMPAT_LIB_DIR="$HOME/.local/lib/caelestia/compat"'
        fi
        printf '%s\n' "$CAELESTIA_RC_END"
    } >> "$rc_file"
}

append_rc_block "$HOME/.bashrc" posix
if [ -f "$HOME/.config/fish/config.fish" ]; then
    append_rc_block "$HOME/.config/fish/config.fish" fish
fi

mkdir -p ~/.local/bin ~/.config/systemd/user

# Private OpenCV compat links for gpu-screen-recorder. Scoped to this directory
# and applied via LD_LIBRARY_PATH by the recorder only -- never installed into
# a system library path, and removed with ~/.local/lib/caelestia on uninstall.
caelestia_compat_lib_dir="$HOME/.local/lib/caelestia/compat"
mkdir -p "$caelestia_compat_lib_dir"
# No `exit` inside awk: it closes the pipe, ldconfig dies of SIGPIPE, and under
# `set -euo pipefail` the 141 status aborts the whole script at this line --
# silently skipping every remaining step. Let awk drain its input and take the
# first match with head instead.
find_lib() {
    ldconfig -p 2>/dev/null | awk -v pat="$1" '$0 ~ pat { print $NF }' | head -n1
}
opencv_imgproc="$(find_lib 'libopencv_imgproc\.so\.5')"
opencv_core="$(find_lib 'libopencv_core\.so\.5')"
if [ -n "$opencv_imgproc" ] && [ -n "$opencv_core" ]; then
    ln -sfn "$opencv_imgproc" "$caelestia_compat_lib_dir/libopencv_imgproc.so.413"
    ln -sfn "$opencv_core" "$caelestia_compat_lib_dir/libopencv_core.so.413"
    info "Installed private OpenCV compat links in $caelestia_compat_lib_dir"
else
    warn "libopencv_{imgproc,core}.so.5 not found via ldconfig - screen recording may not work"
fi


info "Installing Caelestia bin wrappers..."
install -m 755 "$BUNDLE_DIR/src/bin/caelestia-record" ~/.local/bin/caelestia-record
install -m 755 "$BUNDLE_DIR/src/bin/caelestia-screenshot" ~/.local/bin/caelestia-screenshot
install -m 755 "$BUNDLE_DIR/src/bin/caelestia-shell-ipc" ~/.local/bin/caelestia-shell-ipc
install -m 755 "$BUNDLE_DIR/src/bin/caelestia" ~/.local/bin/caelestia
install -m 755 "$BUNDLE_DIR/src/bin/caelestia-update" ~/.local/bin/caelestia-update
install -m 755 "$BUNDLE_DIR/src/bin/caelestia-check-updates" ~/.local/bin/caelestia-check-updates
ok "Caelestia bin wrappers installed to ~/.local/bin"


# Copying mono icon theme
DEST_DIR="$HOME/.config/quickshell/caelestia/assets/icons/yet-another-monochrome-icon-set"
TMP_DIR="${DEST_DIR}.tmp"

mkdir -p "$(dirname "$DEST_DIR")"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

if rsync -a --chmod=u+w --exclude='.git' "$BUNDLE_DIR/src/yet-another-monochrome-icon-set/" "$TMP_DIR/"; then
    OLD_DEST="${DEST_DIR}.old.$$"
    if [[ -e "$DEST_DIR" || -L "$DEST_DIR" ]] && ! mv -- "$DEST_DIR" "$OLD_DEST"; then
        rm -rf -- "$TMP_DIR"
        die "Failed to stage the existing icon set."
    fi
    if mv -- "$TMP_DIR" "$DEST_DIR"; then
        rm -rf -- "$OLD_DEST"
        info "Yet another monochrome icon set copied successfully."
    else
        rm -rf -- "$DEST_DIR"
        [[ -e "$OLD_DEST" || -L "$OLD_DEST" ]] && mv -- "$OLD_DEST" "$DEST_DIR" || true
        die "Failed to install the monochrome icon set."
    fi
else
    rm -rf "$TMP_DIR"
    die "Failed to copy yet-another-monochrome-icon-set."
fi

# Save current commit and branch for the update checker
mkdir -p ~/.config/quickshell/caelestia
if [ -d "$BUNDLE_DIR/.git" ]; then
    current_commit="$(git -C "$BUNDLE_DIR" rev-parse HEAD)" || die "Failed to determine the installed commit"
    current_branch="$(git -C "$BUNDLE_DIR" rev-parse --abbrev-ref HEAD)" || die "Failed to determine the installed branch"
    printf '%s\n' "$current_commit" > ~/.config/quickshell/caelestia/.current_commit || die "Failed to record the installed commit"
    printf '%s\n' "$current_branch" > ~/.config/quickshell/caelestia/.update_branch || die "Failed to record the installed branch"

    # Persist the installed release metadata as well. This lets the update
    # checker report a version even when the commit exists only locally.
    if [ -f "$BUNDLE_DIR/.github/version.env" ]; then
        cp "$BUNDLE_DIR/.github/version.env" ~/.config/quickshell/caelestia/.current_version || die "Failed to record the installed version"
    else
        git -C "$BUNDLE_DIR" show HEAD:.github/version.env > ~/.config/quickshell/caelestia/.current_version || die "Failed to record the installed version"
    fi
fi

ok "Caelestia Shell and KDE Bridges built and installed successfully to user directory."
