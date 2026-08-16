#!/usr/bin/env bash
# 03-deploy-configs.sh  Deploy Caelestia configuration files to ~/.config

set -euo pipefail

BUNDLE_DIR="${BUNDLE_DIR:?BUNDLE_DIR not set}"
SRC_DIR="$BUNDLE_DIR/src"
DOTS_DIR="$SRC_DIR/dots"
FISH_DIR="$SRC_DIR/dots-extra"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/caelestia-kde"
BACKUP_DIR_FILE="$CACHE_DIR/backup-dir.txt"
if [[ -z "${BACKUP_DIR:-}" ]]; then
    BACKUP_DIR=""
    if [[ -f "$BACKUP_DIR_FILE" ]]; then
        BACKUP_DIR="$(cat "$BACKUP_DIR_FILE" 2>/dev/null || true)"
    fi

    # Only reuse the cached backup dir if it belongs to *this* bundle's backups and matches the timestamp format.
    if [[ -n "$BACKUP_DIR" ]]; then
        case "$BACKUP_DIR" in
            "$BUNDLE_DIR/backups/"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
            *) BACKUP_DIR="" ;;
        esac
    fi

    if [[ -n "$BACKUP_DIR" ]] && [[ ! -d "$BACKUP_DIR" ]]; then
        BACKUP_DIR=""
    fi

    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$BUNDLE_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    fi
fi

echo
echo ""
echo "  Step 3/11  Config Deployment"
echo ""

mkdir -p "$BACKUP_DIR"

if [[ ! -d "$DOTS_DIR" ]] || [[ -z "$(ls -A "$DOTS_DIR" 2>/dev/null)" ]]; then
    echo "  [ERR] Missing src/dots content. Run: git submodule update --init --recursive src/dots"
    exit 1
fi

echo "  Recording previous login shell..."
getent passwd "$USER" | cut -d: -f7 > "$BACKUP_DIR/previous_shell.txt"

echo "  Backing up pre-install configs..."
mkdir -p "$BACKUP_DIR/shellrc" "$BACKUP_DIR/.config" "$BACKUP_DIR/local"

# Backup selected config dirs that may be overwritten/removed during install/uninstall
for cfg in btop fastfetch fish foot kitty micro thunar; do
    if [[ -e "$HOME/.config/$cfg" ]]; then
        if ! cp -a "$HOME/.config/$cfg" "$BACKUP_DIR/.config/$cfg"; then
            echo "[FATAL] Failed to back up $HOME/.config/$cfg; refusing to deploy." >&2
            exit 1
        fi
    fi
done

# Backup Konsole config/profiles (system tweaks may modify these)
if [[ -f "$HOME/.config/konsolerc" ]]; then
    if ! cp -a "$HOME/.config/konsolerc" "$BACKUP_DIR/.config/konsolerc"; then
        echo "[FATAL] Failed to back up $HOME/.config/konsolerc; refusing to deploy." >&2
        exit 1
    fi
fi
if [[ -d "$HOME/.local/share/konsole" ]]; then
    if ! cp -a "$HOME/.local/share/konsole" "$BACKUP_DIR/local/konsole"; then
        echo "[FATAL] Failed to back up $HOME/.local/share/konsole; refusing to deploy." >&2
        exit 1
    fi
fi

backup_shell_rc() {
    local src="$1"
    local key="$2"
    if [[ -f "$src" ]]; then
        if ! cp "$src" "$BACKUP_DIR/shellrc/$key"; then
            echo "[FATAL] Failed to back up $src; refusing to deploy." >&2
            exit 1
        fi
        printf 'present\n' > "$BACKUP_DIR/shellrc/$key.state"
    else
        printf 'missing\n' > "$BACKUP_DIR/shellrc/$key.state"
    fi
}

backup_shell_rc "$HOME/.bashrc" "bashrc"
backup_shell_rc "$HOME/.zshrc" "zshrc"
backup_shell_rc "$HOME/.config/fish/config.fish" "fish_config"

deploy_config_dir() {
    local source="$1" target="$2" parent staging new_target old_target
    parent="$(dirname "$target")"
    mkdir -p "$parent"
    staging="$(mktemp -d "$parent/.caelestia-deploy.XXXXXX")"
    new_target="$staging/$(basename "$target")"
    old_target="$parent/.caelestia-old.$$.${RANDOM}"
    if ! cp -a "$source" "$new_target"; then
        rm -rf -- "$staging"
        return 1
    fi
    if [[ -e "$target" || -L "$target" ]]; then
        if ! mv -- "$target" "$old_target"; then
            rm -rf -- "$staging"
            return 1
        fi
    fi
    if mv -- "$new_target" "$target"; then
        rm -rf -- "$staging" "$old_target"
        return 0
    fi
    rm -rf -- "$target"
    if [[ -e "$old_target" || -L "$old_target" ]]; then
        mv -- "$old_target" "$target" || true
    fi
    rm -rf -- "$staging"
    return 1
}

echo "  Deploying Caelestia configs..."
for config in btop fastfetch foot kitty micro thunar; do
    if [[ -d "$DOTS_DIR/$config" ]]; then
        if ! deploy_config_dir "$DOTS_DIR/$config" "$HOME/.config/$config"; then
            echo "[FATAL] Failed to deploy $config; existing config was preserved." >&2
            exit 1
        fi
        echo "    Deployed: $config"
    fi
done

echo "  Deploying extra configs..."
for config in fish fastfetch; do
    if [[ "$config" == "fish" && "${INSTALL_FISH:-true}" != "true" ]]; then
        echo "    [SKIP] fish config deployment disabled by user choice"
        continue
    fi

    if [[ -d "$FISH_DIR/$config" ]]; then
        if ! deploy_config_dir "$FISH_DIR/$config" "$HOME/.config/$config"; then
            echo "[FATAL] Failed to deploy $config; existing config was preserved." >&2
            exit 1
        fi
        echo "    Deployed: $config"
    fi
done

# Backup existing starship config
if [[ -f "$HOME/.config/starship.toml" ]]; then
    mkdir -p "$BACKUP_DIR/.config"
    if ! cp "$HOME/.config/starship.toml" "$BACKUP_DIR/.config/starship.toml"; then
        echo "[FATAL] Failed to back up starship.toml; refusing to deploy." >&2
        exit 1
    fi
fi

# Deploy starship.toml
if [[ -f "$DOTS_DIR/starship.toml" ]]; then
    mkdir -p "$HOME/.config"
    if ! install -m 0644 "$DOTS_DIR/starship.toml" "$HOME/.config/starship.toml"; then
        echo "[FATAL] Failed to deploy starship.toml." >&2
        exit 1
    fi
    echo "    Deployed: starship.toml"
fi

#  Deploy Bridge Files
echo "  Deploying bridge files (bin, applications, systemd, kwin script)..."
mkdir -p \
    "$HOME/.local/bin" \
    "$HOME/.local/share/applications" \
    "$HOME/.config/systemd/user" \
    "$HOME/.local/share/kwin/scripts"

# bin scripts
if [[ -d "$SRC_DIR/bin" ]]; then
    # Copy scripts, but skip C++ source files and build files
    for file in "$SRC_DIR/bin/"*; do
        if [[ ! "$file" == *.cpp && ! "$file" == *CMakeLists.txt && ! -d "$file" ]]; then
            if ! cp --remove-destination "$file" "$HOME/.local/bin/"; then
                echo "[FATAL] Failed to deploy $(basename "$file")." >&2
                exit 1
            fi
        fi
    done
fi

# User systemd units
for unit in "$BUNDLE_DIR/src/systemd/"*.service "$BUNDLE_DIR/src/systemd/"*.timer; do
    [[ -f "$unit" ]] || continue
    install -m 0644 "$unit" "$HOME/.config/systemd/user/$(basename "$unit")"
done
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable --now caelestia-update-checker.timer 2>/dev/null || \
    echo "  [WARN]  Could not enable the Caelestia update checker timer." >&2

# Update desktop database
update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null || true
echo "  [OK]  Bridge files deployed."

if [[ "${APPLY_LOCKSCREEN:-true}" != "false" ]]; then
    echo "  Configuring KDE Lock Screen to use Caelestia..."
    if command -v kwriteconfig6 >/dev/null 2>&1 && command -v kpackagetool6 >/dev/null 2>&1; then
        if kpackagetool6 --list -t Plasma/Wallpaper 2>/dev/null | grep -q "net.dosowisko.PlasmaApplicationWallpaper"; then
            printf -v lockscreen_command 'quickshell -p %q' "$HOME/.config/quickshell/caelestia/lockscreen.qml"
            kwriteconfig6 --file kscreenlockerrc --group Greeter --key WallpaperPlugin net.dosowisko.PlasmaApplicationWallpaper
            kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group net.dosowisko.PlasmaApplicationWallpaper --group General --key command "$lockscreen_command"
            kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group net.dosowisko.PlasmaApplicationWallpaper --group General --key fps 1
            kwriteconfig6 --file kscreenlockerrc --group Greeter --group LnF --group General --key alwaysShowClock false
            kwriteconfig6 --file kscreenlockerrc --group Greeter --group LnF --group General --key showMediaControls false
            echo "  [OK]  KDE Lock Screen configured."
        else
            echo "  [WARN] plasma-wallpaper-application plugin not installed. Skipping KDE Lock Screen configuration."
        fi
    else
        echo "  [WARN] KDE config tools not found. Skipping KDE Lock Screen configuration."
    fi
else
    echo "  [SKIP] KDE Lock Screen configuration disabled by user choice."
fi

echo "[OK]  Config deployment complete."
