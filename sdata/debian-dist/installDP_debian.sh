#!/usr/bin/env bash
# installDP_debian.sh - Debian/Ubuntu package installation for Caelestia KDE Port

set -uo pipefail

log()  { echo -e "\033[0;36m[INFO]\033[0m $*"; }
err()  { echo -e "\033[0;31m[ERR]\033[0m  $*"; }
CLI_TARBALL_SHA256="1d238723b74581e9d8fae4f836837f71050d65759b11bfc9b3de71534accb368"
ADW_GTK3_URL="https://github.com/lassekongo83/adw-gtk3/releases/download/v5.3/adw-gtk3v5.3.tar.xz"
ADW_GTK3_SHA256="2e6e87935bef30936e40d07c7af4fd20754e77917be224f61c4346867196bef0"
FONT_MATERIAL_URL="https://github.com/google/material-design-icons/raw/e083cc60a0828fdd3b404cea0cb8a5b900e9c23e/variablefont/MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf"
FONT_RUBIK_URL="https://github.com/google/fonts/raw/352f6b7d9d6cc4fa9e242b931291d31b21a6dc84/ofl/rubik/Rubik%5Bwght%5D.ttf"
FONT_CASCADIA_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/CascadiaCode.zip"
FONT_JETBRAINS_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/JetBrainsMono.zip"
FONT_MATERIAL_SHA256="c2c185c2f31193348f34ae454215d990bb49f494c45e79348d9f2b3d653607d7"
FONT_RUBIK_SHA256="1b3a7437ba2af80e465e773ed60c5036d1ba6ace492d89046dbcf18fb31e4e88"
FONT_CASCADIA_SHA256="e68cf12cc3c14a18b9ddce0e77f66a78e3ebec4a5224423674fdd9303c5c9272"
FONT_JETBRAINS_SHA256="1fa397478bfca4917dba796eeeb5a428c0834e760b1d96caffff633d6238fdce"

download_verified() {
    local url="$1" expected="$2" destination="$3" tmp="${3}.part.$$"
    rm -f -- "$tmp"
    curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$tmp" || return 1
    printf '%s  %s\n' "$expected" "$tmp" | sha256sum -c - >/dev/null 2>&1 || {
        rm -f -- "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$destination"
}

clone_verified() {
    local url="$1" dest="$2" allow_unverified="${3:-0}"
    git clone --depth 1 "$url" "$dest" || return 1
    if [[ "$allow_unverified" != "1" ]]; then
        git -C "$dest" verify-commit HEAD >/dev/null 2>&1 || {
            rm -rf -- "$dest"
            err "Refusing unsigned source checkout: $url"
            return 1
        }
    fi
}

log "Installing Debian packages..."

INSTALL_FISH="${INSTALL_FISH:-true}"
INSTALL_PAPIRUS="${INSTALL_PAPIRUS:-true}"
INSTALL_DARKLY="${INSTALL_DARKLY:-true}"

# Core dependencies split by group — controlled via PACKAGE_GROUP env var
PACKAGE_GROUP="${PACKAGE_GROUP:-all}"

CORE_PACKAGES=(
    cmake ninja-build ccache g++ build-essential
    wl-clipboard cliphist inotify-tools wireplumber trash-cli jq yq
    libaubio-dev aubio-tools lm-sensors libsensors-dev
    libpipewire-0.3-dev pipewire libc6
    qt6-base-dev qt6-base-private-dev qt6-declarative-dev qml6-module-qtquick qt6-wayland qt6-wayland-dev qt6-svg-dev qt6-shadertools-dev
    libkf6globalaccel-dev libkf6windowsystem-dev libkf6networkmanagerqt-dev libkpipewire-dev libsecret-1-dev
    ffmpeg libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libqalculate-dev qalc
)

SHELL_PACKAGES=(
    foot eza fastfetch btop bash
)

THEME_PACKAGES=(
    adw-gtk3
)

UTILITY_PACKAGES=(
    fuzzel swappy ddcutil network-manager imagemagick tesseract-ocr tesseract-ocr-eng kde-spectacle slurp grim xdg-utils sassc python3-venv uv konsave
)

# Packages that need manual build or script fallback on Debian if apt package missing
FALLBACK_PKGS=(
    quickshell starship libcava app2unit gpu-screen-recorder wl-clip-persist satty adw-gtk3 uv konsave
)

# Build final package list based on selected group
PACKAGES=()
FALLBACK_TARGETS=()
case "$PACKAGE_GROUP" in
    core)   PACKAGES=("${CORE_PACKAGES[@]}");   FALLBACK_TARGETS=("libcava" "app2unit") ;;
    shell)  PACKAGES=("${SHELL_PACKAGES[@]}");  FALLBACK_TARGETS=("quickshell" "starship") ;;
    themes) PACKAGES=("${THEME_PACKAGES[@]}");  FALLBACK_TARGETS=("adw-gtk3") ;;
    utils)  PACKAGES=("${UTILITY_PACKAGES[@]}"); FALLBACK_TARGETS=("gpu-screen-recorder" "wl-clip-persist" "satty" "uv" "konsave") ;;
    all|*)  PACKAGES=("${CORE_PACKAGES[@]}" "${SHELL_PACKAGES[@]}" "${THEME_PACKAGES[@]}" "${UTILITY_PACKAGES[@]}")
            FALLBACK_TARGETS=("quickshell" "starship" "libcava" "app2unit" "gpu-screen-recorder" "wl-clip-persist" "satty" "adw-gtk3" "uv" "konsave") ;;
esac

# See tests/integration/README.md. Packages still come from apt and are checked
# with dpkg; the override only bounds the CI workload.
if [[ -n "${CAELESTIA_INTEGRATION_PACKAGES:-}" ]]; then
    read -r -a PACKAGES <<< "$CAELESTIA_INTEGRATION_PACKAGES"
    FALLBACK_TARGETS=()
    INSTALL_FISH=false
    INSTALL_PAPIRUS=false
    INSTALL_DARKLY=false
fi

log "Installing packages (group: $PACKAGE_GROUP)..."

# Optional packages only included for relevant groups (or "all")
if [[ "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "shell" ]]; then
    if [[ "$INSTALL_FISH" == "true" ]]; then
        PACKAGES+=(fish)
    else
        log "Skipping Fish installation by user choice."
    fi
fi

if [[ "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "themes" ]]; then
    if [[ "$INSTALL_PAPIRUS" == "true" ]]; then
        PACKAGES+=(papirus-icon-theme)
    else
        log "Skipping Papirus icon theme installation by user choice."
    fi
fi

log "Updating apt package index..."
if ! sudo apt-get update; then
    err "Failed to update apt package index; refusing to continue."
    exit 1
fi

FAILED_PKGS=()

# Filter batch packages (excluding known fallback build targets)
BATCH_PKGS=()
for pkg in "${PACKAGES[@]}"; do
    _is_fallback="no"
    for fb in "${FALLBACK_TARGETS[@]}"; do
        if [[ "$pkg" == "$fb" ]]; then _is_fallback="yes"; break; fi
    done
    if [[ "$_is_fallback" == "no" ]]; then
        BATCH_PKGS+=("$pkg")
    fi
done

# Batch install standard packages via apt
if [[ ${#BATCH_PKGS[@]} -gt 0 ]]; then
    log "Batch installing standard Debian packages..."
    if ! sudo apt-get install -y --no-install-recommends "${BATCH_PKGS[@]}"; then
        log "Batch install had failures. Retrying standard packages individually..."
        for pkg in "${BATCH_PKGS[@]}"; do
            if ! dpkg -s "$pkg" >/dev/null 2>&1; then
                sudo apt-get install -y --no-install-recommends "$pkg" || {
                    err "apt failed to install $pkg"
                    FAILED_PKGS+=("$pkg")
                }
            fi
        done
    fi
fi

# Process fallback / manual build targets
for pkg in "${FALLBACK_TARGETS[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1 || command -v "$pkg" >/dev/null 2>&1; then
        continue
    fi

    if sudo apt-get install -y "$pkg" 2>/dev/null; then
        continue
    fi

    log "apt failed or package missing for $pkg. Attempting manual fallback..."
    case "$pkg" in
        quickshell)
            if [[ "${CAELESTIA_ALLOW_THIRD_PARTY_PPA:-0}" != "1" ]]; then
                err "quickshell is unavailable from configured repositories; refusing unreviewed PPA."
                err "Set CAELESTIA_ALLOW_THIRD_PARTY_PPA=1 only after reviewing ppa:avengemedia/danklinux."
                FAILED_PKGS+=("$pkg")
                continue
            fi
            log "Installing quickshell from explicitly enabled PPA..."
            sudo apt-get install -y software-properties-common || { err "Failed to install PPA prerequisites."; FAILED_PKGS+=("$pkg"); continue; }
            sudo add-apt-repository -y ppa:avengemedia/danklinux || { err "Failed to add quickshell PPA."; FAILED_PKGS+=("$pkg"); continue; }
            sudo apt-get update || { err "Failed to refresh PPA metadata."; FAILED_PKGS+=("$pkg"); continue; }
            sudo apt-get install -y quickshell || { err "Failed to install quickshell from PPA."; FAILED_PKGS+=("$pkg"); }
            ;;
        libcava|cava)
            tmpdir="$(mktemp -d)"
            if ! sudo apt-get install -y libasound2-dev libfftw3-dev libpulse-dev libiniparser-dev meson ninja-build cmake gcc g++; then
                err "Failed to install libcava build dependencies."
                FAILED_PKGS+=("$pkg")
                rm -rf -- "$tmpdir"
                continue
            fi
            if clone_verified https://github.com/LukashonakV/cava "$tmpdir"; then
                (
                    cd "$tmpdir" || exit 1
                    if [ -f "meson.build" ]; then
                        meson setup build && meson compile -C build && sudo meson install -C build
                    elif [ -f "CMakeLists.txt" ]; then
                        cmake -B build && cmake --build build && sudo cmake --install build
                    else
                        ./autogen.sh && ./configure && make && sudo make install
                    fi
                ) || { err "Manual build for $pkg failed."; FAILED_PKGS+=("$pkg"); }
            else
                err "Failed to clone $pkg."
                FAILED_PKGS+=("$pkg")
            fi
            rm -rf "$tmpdir"
            ;;
        app2unit)
            tmpdir="$(mktemp -d)"
            if ! sudo apt-get install -y make; then
                err "Failed to install app2unit build dependencies."
                FAILED_PKGS+=("$pkg")
                rm -rf -- "$tmpdir"
                continue
            fi
            if clone_verified https://github.com/Vladimir-csp/app2unit "$tmpdir"; then
                (
                    cd "$tmpdir" || exit 1
                    sudo make install
                ) || { err "Manual build for $pkg failed."; FAILED_PKGS+=("$pkg"); }
            else
                err "Failed to clone $pkg."
                FAILED_PKGS+=("$pkg")
            fi
            rm -rf "$tmpdir"
            ;;
        gpu-screen-recorder)
            tmpdir="$(mktemp -d)"
            if ! sudo apt-get install -y build-essential git ffmpeg meson libxi-dev libdrm-dev libavcodec-dev libavformat-dev libx11-dev libxcomposite-dev libxdamage-dev libxrender-dev libxrandr-dev libpulse-dev libva-dev libcap-dev libdbus-1-dev libpipewire-0.3-dev libavfilter-dev libvulkan-dev; then
                err "Failed to install gpu-screen-recorder build dependencies."
                FAILED_PKGS+=("$pkg")
                rm -rf -- "$tmpdir"
                continue
            fi
            if clone_verified https://repo.dec05eba.com/gpu-screen-recorder "$tmpdir"; then
                (
                    cd "$tmpdir" || exit 1
                    sudo ./install.sh
                ) || { err "Manual build for $pkg failed."; FAILED_PKGS+=("$pkg"); }
            else
                err "Failed to clone $pkg."
                FAILED_PKGS+=("$pkg")
            fi
            rm -rf "$tmpdir"
            ;;
        starship)
            err "starship is unavailable from configured repositories; install it from a signed distribution package."
            FAILED_PKGS+=("$pkg")
            ;;
        wl-clip-persist)
            if ! sudo apt-get install -y build-essential cargo git libwayland-dev; then
                err "Failed to install wl-clip-persist build dependencies."
                FAILED_PKGS+=("$pkg")
                continue
            fi
            if command -v cargo >/dev/null 2>&1; then
                tmpdir="$(mktemp -d)"
                if clone_verified https://github.com/Linus789/wl-clip-persist "$tmpdir"; then
                    (
                        cd "$tmpdir" || exit 1
                        cargo build --release
                        sudo cp target/release/wl-clip-persist /usr/local/bin/
                    ) || { err "cargo build $pkg failed."; FAILED_PKGS+=("$pkg"); }
                else
                    err "Failed to clone $pkg."
                    FAILED_PKGS+=("$pkg")
                fi
                rm -rf "$tmpdir"
            else
                err "Cargo not available to build $pkg."
                FAILED_PKGS+=("$pkg")
            fi
            ;;
        satty)
            if command -v cargo-binstall >/dev/null 2>&1; then
                cargo-binstall -y satty || {
                    err "cargo-binstall failed for $pkg."
                    FAILED_PKGS+=("$pkg")
                }
            else
                err "cargo-binstall is not installed; refusing to run an unverified remote installer."
                FAILED_PKGS+=("$pkg")
            fi
            ;;
        uv)
            err "uv is unavailable from configured repositories; install it from a signed distribution package."
            FAILED_PKGS+=("$pkg")
            ;;
        konsave)
            export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
            if command -v uv >/dev/null 2>&1; then
                uv tool install konsave || { err "uv tool install $pkg failed."; FAILED_PKGS+=("$pkg"); }
            else
                err "uv is required to install $pkg, but it is not available."
                FAILED_PKGS+=("$pkg")
            fi
            ;;
        adw-gtk3)
            tmpdir="$(mktemp -d)"
            log "Downloading adw-gtk3 theme..."
            if download_verified "$ADW_GTK3_URL" "$ADW_GTK3_SHA256" "$tmpdir/adw-gtk3.tar.xz" \
                && tar -xJf "$tmpdir/adw-gtk3.tar.xz" -C "$tmpdir"; then
                mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/themes"
                cp -r "$tmpdir/adw-gtk3" "$tmpdir/adw-gtk3-dark" "${XDG_DATA_HOME:-$HOME/.local/share}/themes/" || { err "Failed to install adw-gtk3"; FAILED_PKGS+=("$pkg"); }
            else
                err "Failed to download or verify adw-gtk3 theme."
                FAILED_PKGS+=("$pkg")
            fi
            rm -rf "$tmpdir"
            ;;
        *)
            err "No manual fallback defined for $pkg."
            FAILED_PKGS+=("$pkg")
            ;;
    esac
done

if [ ${#FAILED_PKGS[@]} -ne 0 ]; then
    mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/caelestia-kde"
    err "The following packages could not be installed:"
    for pkg in "${FAILED_PKGS[@]}"; do
        err "  - $pkg"
        echo "$pkg" >> "${XDG_CACHE_HOME:-$HOME/.cache}/caelestia-kde/failed_packages.txt"
    done
fi

if [[ "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "themes" ]]; then

log "Downloading and installing required custom fonts (parallel)..."
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
font_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/caelestia-fonts.XXXXXX")"
trap 'rm -rf -- "$font_tmp_dir"' EXIT

font_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
download_verified "$FONT_MATERIAL_URL" "$FONT_MATERIAL_SHA256" "$font_dir/MaterialSymbolsRounded.ttf" || { err "Material Symbols checksum or download failed."; exit 1; }
download_verified "$FONT_CASCADIA_URL" "$FONT_CASCADIA_SHA256" "$font_tmp_dir/CascadiaCode.zip" || { err "Cascadia Code checksum or download failed."; exit 1; }
download_verified "$FONT_JETBRAINS_URL" "$FONT_JETBRAINS_SHA256" "$font_tmp_dir/JetBrainsMono.zip" || { err "JetBrains Mono checksum or download failed."; exit 1; }
download_verified "$FONT_RUBIK_URL" "$FONT_RUBIK_SHA256" "$font_dir/Rubik-VariableFont_wght.ttf" || { err "Rubik checksum or download failed."; exit 1; }

unzip -qo "$font_tmp_dir/CascadiaCode.zip" -d "$font_dir" || { err "Failed to extract Cascadia Code font."; exit 1; }
unzip -qo "$font_tmp_dir/JetBrainsMono.zip" -d "$font_dir" || { err "Failed to extract JetBrains Mono font."; exit 1; }

fc-cache -f

log "Building and Installing Darkly KDE Theme..."
if [[ "$INSTALL_DARKLY" == "true" ]]; then
    if ! command -v darkly >/dev/null 2>&1; then
        tmpdir="$(mktemp -d)"
        if ! sudo apt-get install -y cmake extra-cmake-modules gettext libkf6config-dev libkf6configwidgets-dev libkf6coreaddons-dev libkf6guiaddons-dev libkf6i18n-dev libkf6iconthemes-dev libkf6kio-dev libkf6widgetsaddons-dev libkf6windowsystem-dev libkf6colorscheme-dev libkf6kcmutils-dev libkirigami-dev libkdecorations3-dev libkf6style-dev qt6-base-dev qt6-declarative-dev; then
            err "Failed to install Darkly build dependencies."
            exit 1
        fi
        if clone_verified https://github.com/Bali10050/Darkly "$tmpdir"; then
            (
                cd "$tmpdir" || exit 1
                cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_QT5=OFF && cmake --build build -j"$(nproc)" && cd build && sudo cmake --install .
            ) || err "Failed to build Darkly theme from source."
        fi
        rm -rf "$tmpdir"
    fi
else
    log "Skipping Darkly package installation by user choice."
fi

fi  # end of PACKAGE_GROUP themes/all block

if [[ "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "shell" ]]; then

log "Installing Caelestia CLI wrapper..."
if ! command -v caelestia >/dev/null 2>&1; then
    if ! sudo apt-get install -y python3-pip python3-build python3-installer python3-hatchling python3-hatch-vcs; then
        err "Failed to install Caelestia CLI build dependencies."
        exit 1
    fi
    tmpdir="$(mktemp -d)"
    (
        cd "$tmpdir" || exit 1
        if ! curl -fsSL --proto '=https' --tlsv1.2 \
            "https://github.com/caelestia-dots/cli/releases/download/v1.0.8/caelestia-1.0.8.tar.gz" \
            -o caelestia.tar.gz; then
            err "Failed to download the Caelestia CLI source archive."
            exit 1
        fi
        if ! printf '%s  %s\n' "$CLI_TARBALL_SHA256" caelestia.tar.gz | sha256sum -c -; then
            err "Caelestia CLI source archive checksum mismatch; refusing to build or install it."
            exit 1
        fi
        tar -xzf caelestia.tar.gz
        cd caelestia-1.0.8 || exit 1
        python3 -m build --wheel --no-isolation
        if ! sudo pip3 install dist/*.whl --break-system-packages 2>/dev/null; then
            pip3 install dist/*.whl --user --break-system-packages 2>/dev/null || pip3 install dist/*.whl --user
            if [[ -f "$HOME/.local/bin/caelestia" ]]; then
                if ! sudo ln -sf "$HOME/.local/bin/caelestia" /usr/local/bin/caelestia; then
                    err "Failed to install the Caelestia CLI wrapper in /usr/local/bin."
                    exit 1
                fi
            fi
        fi

        # Install fish completions if fish is present
        mkdir -p ~/.config/fish/completions/
        cp ./completions/caelestia.fish ~/.config/fish/completions/ 2>/dev/null || true
    )
    rm -rf "$tmpdir"
fi

if command -v sassc >/dev/null 2>&1 && ! command -v sass >/dev/null 2>&1; then
    if ! sudo ln -sf /usr/bin/sassc /usr/local/bin/sass; then
        err "Failed to install the sass compatibility symlink."
        exit 1
    fi
fi

fi  # end of PACKAGE_GROUP shell/all block

log "Debian package installation complete."
