#!/usr/bin/env bash
# installDP_fedora.sh - Fedora package installation for Caelestia KDE Port

set -uo pipefail

log()  { echo -e "\033[0;36m[INFO]\033[0m $*"; }
err()  { echo -e "\033[0;31m[ERR]\033[0m  $*"; }
CLI_TARBALL_SHA256="1d238723b74581e9d8fae4f836837f71050d65759b11bfc9b3de71534accb368"
FONT_MATERIAL_URL="https://github.com/google/material-design-icons/raw/e083cc60a0828fdd3b404cea0cb8a5b900e9c23e/variablefont/MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf"
FONT_CASCADIA_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/CascadiaCode.zip"
FONT_JETBRAINS_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/JetBrainsMono.zip"
FONT_MATERIAL_SHA256="c2c185c2f31193348f34ae454215d990bb49f494c45e79348d9f2b3d653607d7"
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

log "Installing Fedora packages..."

INSTALL_FISH="${INSTALL_FISH:-true}"
INSTALL_PAPIRUS="${INSTALL_PAPIRUS:-true}"
INSTALL_DARKLY="${INSTALL_DARKLY:-true}"

# Core dependencies split by group — controlled via PACKAGE_GROUP env var
PACKAGE_GROUP="${PACKAGE_GROUP:-all}"

CORE_PACKAGES=(
    cmake ninja-build ccache
    wl-clipboard cliphist wl-clip-persist inotify-tools wireplumber trash-cli jq aubio lm_sensors lm_sensors-devel
    pipewire-devel glibc qt6-qtdeclarative qt6-qtdeclarative-devel qt6-qtwayland qt6-qtwayland-devel kf6-kglobalaccel-devel qt6-qtbase-private-devel qt6-qtsvg qt6-qtsvg-devel qt6-qtshadertools-devel libgcc qt6-qtbase libqalculate libqalculate-devel aubio-devel kf6-kpipewire kf6-kpipewire-devel kf6-kwindowsystem-devel kf6-networkmanager-qt-devel libsecret vulkan-headers
)

SHELL_PACKAGES=(
    foot eza fastfetch starship btop bash
)

THEME_PACKAGES=(
    adw-gtk3-theme google-rubik-fonts google-noto-sans-fonts google-noto-sans-cjk-fonts google-noto-emoji-fonts
)

UTILITY_PACKAGES=(
    fuzzel swappy ddcutil NetworkManager ImageMagick tesseract tesseract-langpack-eng spectacle gpu-screen-recorder slurp grim xdg-utils sassc bat ripgrep lazygit xdg-user-dirs
)

# Packages known to need copr or manual fallback
COPR_CORE=(app2unit libcava)
COPR_SHELL=(quickshell-git)
COPR_UTILS=()

# Build final package list based on selected group
PACKAGES=()
COPR_PKGS=()
case "$PACKAGE_GROUP" in
    core)   PACKAGES=("${CORE_PACKAGES[@]}");   COPR_PKGS=("${COPR_CORE[@]}") ;;
    shell)  PACKAGES=("${SHELL_PACKAGES[@]}");  COPR_PKGS=("${COPR_SHELL[@]}") ;;
    themes) PACKAGES=("${THEME_PACKAGES[@]}");  COPR_PKGS=() ;;
    utils)  PACKAGES=("${UTILITY_PACKAGES[@]}"); COPR_PKGS=("${COPR_UTILS[@]}") ;;
    all|*)  PACKAGES=("${CORE_PACKAGES[@]}" "${SHELL_PACKAGES[@]}" "${THEME_PACKAGES[@]}" "${UTILITY_PACKAGES[@]}")
            COPR_PKGS=("quickshell-git" "gpu-screen-recorder" "app2unit" "starship" "libcava" "wl-clip-persist") ;;
esac

# See tests/integration/README.md. The override still uses dnf and rpm; it only
# reduces the package set and disables unrelated third-party repositories.
if [[ -n "${CAELESTIA_INTEGRATION_PACKAGES:-}" ]]; then
    read -r -a PACKAGES <<< "$CAELESTIA_INTEGRATION_PACKAGES"
    COPR_PKGS=()
    INSTALL_FISH=false
    INSTALL_PAPIRUS=false
    INSTALL_DARKLY=false
fi

# Ensure COPR-only packages are actually requested for the relevant groups
if [[ -z "${CAELESTIA_INTEGRATION_PACKAGES:-}" && ( "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "core" ) ]]; then
    PACKAGES+=("${COPR_CORE[@]}")
fi
if [[ -z "${CAELESTIA_INTEGRATION_PACKAGES:-}" && ( "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "shell" ) ]]; then
    PACKAGES+=("${COPR_SHELL[@]}")
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

if [[ -z "${CAELESTIA_INTEGRATION_PACKAGES:-}" ]]; then
    log "Enabling RPM Fusion for H264 hardware codecs..."
    fedora_release="$(rpm -E %fedora)"
    sudo dnf install -y --setopt=gpgcheck=1 --setopt=localpkg_gpgcheck=1 \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_release}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_release}.noarch.rpm" || {
        err "RPM Fusion release packages failed GPG verification or installation."
        exit 1
    }
    if ! sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing; then
        err "Failed to enable FFmpeg codecs; continuing without the swap."
    fi
fi

if [[ -z "${CAELESTIA_INTEGRATION_PACKAGES:-}" && ( "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "core" ) ]]; then
    PACKAGES+=(ffmpeg)
fi

log "Installing packages via dnf (batch mode)..."
if ! sudo dnf upgrade -y; then
    err "Failed to refresh Fedora packages; package installation may be incomplete."
fi

# Build a batch list excluding copr-only packages
BATCH_PKGS=()
for pkg in "${PACKAGES[@]}"; do
    _is_copr="no"
    for cp in "${COPR_PKGS[@]}"; do
        if [[ "$pkg" == "$cp" ]]; then _is_copr="yes"; break; fi
    done
    if [[ "$_is_copr" == "no" ]]; then
        BATCH_PKGS+=("$pkg")
    fi
done

FAILED_PKGS=()

# Batch install standard packages
if [[ ${#BATCH_PKGS[@]} -gt 0 ]]; then
    if ! sudo dnf install -y "${BATCH_PKGS[@]}"; then
        log "Batch install had failures. Retrying standard packages individually..."
        for pkg in "${BATCH_PKGS[@]}"; do
            if ! rpm -q "$pkg" >/dev/null 2>&1; then
                if ! sudo dnf install -y "$pkg"; then
                    err "dnf failed to install $pkg"
                    FAILED_PKGS+=("$pkg")
                fi
            fi
        done
    fi
fi

# Handle copr/manual-fallback packages individually
for pkg in "${COPR_PKGS[@]}"; do
    # Skip if not in the original PACKAGES list
    _needed="no"
    for op in "${PACKAGES[@]}"; do
        if [[ "$op" == "$pkg" ]]; then _needed="yes"; break; fi
    done
    if [[ "$_needed" == "no" ]]; then continue; fi

    if sudo dnf install -y "$pkg" 2>/dev/null; then
        continue
    fi

    log "dnf failed to install $pkg. Attempting copr fallback..."
    COPR_FAILED="yes"
    case "$pkg" in
        quickshell-git|quickshell)
            if sudo dnf copr enable -y errornointernet/quickshell && sudo dnf install -y quickshell-git; then
                COPR_FAILED="no"
            fi
            ;;
        gpu-screen-recorder)
            if sudo dnf copr enable -y brycensranch/gpu-screen-recorder-git && sudo dnf install -y gpu-screen-recorder-ui; then
                COPR_FAILED="no"
            fi
            ;;
        app2unit)
            if sudo dnf copr enable -y celestelove/app2unit && sudo dnf install -y app2unit; then
                COPR_FAILED="no"
            fi
            ;;
        starship)
            if sudo dnf copr enable -y atim/starship && sudo dnf install -y starship; then
                COPR_FAILED="no"
            fi
            ;;
        libcava)
            if sudo dnf copr enable -y celestelove/libcava && sudo dnf install -y libcava-devel; then
                COPR_FAILED="no"
            fi
            ;;
        wl-clip-persist)
            if sudo dnf copr enable -y leloubil/wl-clip-persist && sudo dnf install -y wl-clip-persist; then
                COPR_FAILED="no"
            fi
            ;;
    esac

    if [ "$COPR_FAILED" = "no" ]; then
        continue
    fi

    log "Copr fallback failed or not defined for $pkg. Attempting manual build..."
    case "$pkg" in
        libcava)
            tmpdir="$(mktemp -d)"
            if ! sudo dnf install -y alsa-lib-devel fftw-devel pulseaudio-libs-devel iniparser-devel meson ninja-build cmake gcc-c++; then
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
            if ! sudo dnf install -y make; then
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
            if ! sudo dnf install -y meson ninja-build pkgconf libXcomposite-devel libXrandr-devel libXfixes-devel libdrm-devel wayland-devel pipewire-devel libcap-devel ffmpeg-devel; then
                err "Failed to install gpu-screen-recorder build dependencies."
                FAILED_PKGS+=("$pkg")
                rm -rf -- "$tmpdir"
                continue
            fi
            if clone_verified https://git.dec05eba.com/gpu-screen-recorder "$tmpdir"; then
                (
                    cd "$tmpdir" || exit 1
                    meson setup build && ninja -C build && sudo meson install -C build
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

unzip -qo "$font_tmp_dir/CascadiaCode.zip" -d "$font_dir" || { err "Failed to extract Cascadia Code font."; exit 1; }
unzip -qo "$font_tmp_dir/JetBrainsMono.zip" -d "$font_dir" || { err "Failed to extract JetBrains Mono font."; exit 1; }

fc-cache -f

log "Building and Installing Darkly KDE Theme..."
if [[ "$INSTALL_DARKLY" == "true" ]]; then
    if ! command -v darkly >/dev/null 2>&1; then
        tmpdir="$(mktemp -d)"
        if ! sudo dnf install -y cmake extra-cmake-modules gettext kf6-kconfig-devel kf6-kconfigwidgets-devel kf6-kcoreaddons-devel kf6-kguiaddons-devel kf6-ki18n-devel kf6-kiconthemes-devel kf6-kio-devel kf6-kwidgetsaddons-devel kf6-kwindowsystem-devel qt6-qtbase-devel qt6-qtdeclarative-devel; then
            err "Failed to install Darkly build dependencies."
            exit 1
        fi
        if clone_verified https://github.com/Bali10050/Darkly "$tmpdir"; then
            (
                cd "$tmpdir" || exit 1
                cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"$(nproc)" && sudo cmake --install build
            ) || err "Failed to build Darkly theme from source."
        fi
    fi
else
    log "Skipping Darkly package installation by user choice."
fi

fi  # end of PACKAGE_GROUP themes/all block

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    xdg-user-dirs-update || true
fi

if [[ "$PACKAGE_GROUP" == "all" || "$PACKAGE_GROUP" == "shell" ]]; then
log "Installing Caelestia CLI wrapper..."
if ! command -v caelestia >/dev/null 2>&1; then
    if ! sudo dnf install -y python3-pip python3-build python3-installer python3-hatchling python3-hatch-vcs; then
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
        if ! sudo pip3 install dist/*.whl --break-system-packages; then
            pip3 install dist/*.whl --user --break-system-packages
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

log "Fedora package installation complete."
