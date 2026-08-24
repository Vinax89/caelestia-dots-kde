#!/bin/bash

# Exit on error
set -euo pipefail

# Harmonious HSL colors for elegant premium styling output
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

section() {
    local title="$1"
    echo -e "\n${BLUE}===================================================${NC}"
    echo -e "${BLUE} ${title}${NC}"
    echo -e "${BLUE}===================================================${NC}"
}

section "Ollama AI Setup for Caelestia"

# 1. Install Ollama.
#
# Prefer the distribution package: it is signed by the distro, tracked by the
# package manager, and removable. Only when no package exists do we fall back
# to piping the vendor's install script into a root shell, and then only with
# explicit confirmation.
#
# The previous version had no packaged path at all, and demanded
# OLLAMA_INSTALL_SHA256 with no published value to compare against -- leaving
# two options: don't run it, or hash the same download it was meant to
# authenticate. Neither verifies anything.
section "Step 1/4 - Install Ollama"

detect_base_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
            arch|cachyos|endeavouros|manjaro|artix) echo arch; return ;;
            fedora|nobara|bazzite|rhel|centos|almalinux|rocky) echo fedora; return ;;
            debian|ubuntu|pop|mint|kali|raspbian|elementary|zorin|deepin|devuan) echo debian; return ;;
        esac
        case "${ID_LIKE:-}" in
            *arch*) echo arch; return ;;
            *fedora*|*rhel*) echo fedora; return ;;
            *debian*|*ubuntu*) echo debian; return ;;
        esac
    fi
    if command -v pacman >/dev/null 2>&1; then echo arch
    elif command -v dnf >/dev/null 2>&1; then echo fedora
    elif command -v apt-get >/dev/null 2>&1; then echo debian
    else echo unknown
    fi
}

install_ollama_from_repo() {
    case "$(detect_base_distro)" in
        arch)
            pacman -Si ollama >/dev/null 2>&1 || return 1
            echo -e "${BLUE}Installing ollama from the Arch repositories...${NC}"
            sudo pacman -S --needed --noconfirm ollama
            ;;
        fedora)
            dnf info ollama >/dev/null 2>&1 || return 1
            echo -e "${BLUE}Installing ollama from the Fedora repositories...${NC}"
            sudo dnf install -y ollama
            ;;
        debian)
            apt-cache show ollama >/dev/null 2>&1 || return 1
            echo -e "${BLUE}Installing ollama from the APT repositories...${NC}"
            sudo apt-get update && sudo apt-get install -y ollama
            ;;
        *)
            return 1
            ;;
    esac
}

if command -v ollama >/dev/null 2>&1; then
    echo -e "${GREEN}Ollama is already installed ($(command -v ollama)).${NC}"
elif install_ollama_from_repo; then
    echo -e "${GREEN}Ollama installed from your distribution's repositories.${NC}"
else

echo -e "${YELLOW}No packaged Ollama found for this distribution.${NC}"
echo -e "${YELLOW}The only remaining option is the vendor's install script, run as root.${NC}"
echo
tmp_installer="$(mktemp)"
trap 'rm -f "$tmp_installer"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp_installer" https://ollama.com/install.sh

if [[ ! "${OLLAMA_INSTALL_SHA256:-}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo -e "${RED}OLLAMA_INSTALL_SHA256 must be a pinned 64-character SHA-256 checksum.${NC}" >&2
    echo -e "Fetch the installer, review it, and set OLLAMA_INSTALL_SHA256 before running this setup." >&2
    exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    echo -e "${RED}sha256sum is required to verify the Ollama installer.${NC}" >&2
    exit 1
fi

actual_sha="$(sha256sum "$tmp_installer" | cut -d' ' -f1)"
if [[ "$actual_sha" != "${OLLAMA_INSTALL_SHA256,,}" ]]; then
    echo -e "${RED}Ollama installer checksum mismatch; refusing to run it as root.${NC}" >&2
    echo "  expected: $OLLAMA_INSTALL_SHA256" >&2
    echo "  actual:   $actual_sha" >&2
    exit 1
fi
echo -e "${GREEN}Ollama installer matches the pinned checksum.${NC}"

sudo sh "$tmp_installer"

fi  # end: packaged install unavailable

# 2. Enable and start the systemd service
section "Step 2/4 - Enable and Start Ollama Daemon"
sudo systemctl enable --now ollama
echo -e "${GREEN}Ollama daemon is now running in the background.${NC}"

# 3. Prompt user to download models
section "Step 3/4 - Model Selection"
echo -e "Caelestia's AI Assistant requires at least one model. Here are some popular options:"
echo -e "  1) llama3  (Meta's highly capable model, ~4.7GB)"
echo -e "  2) phi3    (Microsoft's lightweight and fast model, ~2.3GB)"
echo -e "  3) gemma   (Google's lightweight model, ~5.2GB)"
echo -e "  4) mistral (Solid all-rounder model, ~4.1GB)"
echo -e "  5) All of the above"
echo -e "  6) Skip for now"

read -p "Select models to download [1-6]: " MODEL_CHOICE

pull_model() {
    echo -e "${BLUE}Pulling $1...${NC}"
    ollama pull "$1"
}

case $MODEL_CHOICE in
    1) pull_model "llama3" ;;
    2) pull_model "phi3" ;;
    3) pull_model "gemma" ;;
    4) pull_model "mistral" ;;
    5)
        pull_model "llama3"
        pull_model "phi3"
        pull_model "gemma"
        pull_model "mistral"
        ;;
    6) echo -e "${YELLOW}Skipping model download. You can download models later using 'ollama pull <model>'.${NC}" ;;
    *) echo -e "${RED}Invalid selection. Skipping model download.${NC}" ;;
esac

# 4. Final configuration and setup
section "Step 4/4 - Finalize Setup"
echo -e "Setting up autostart for Ollama with Caelestia Shell."
# Note: Since the systemd service is enabled globally, it will start automatically on boot.
# If a user-level service is preferred in the future, we can configure systemd --user.

echo -e "\n${GREEN}===================================================${NC}"
echo -e "${GREEN}          Ollama Setup Completed Successfully!      ${NC}"
echo -e "${GREEN}===================================================${NC}"
echo -e "Caelestia's AI assistant is now ready to use."
echo -e "Open the sidebar in the shell and start chatting!"
echo -e "${GREEN}===================================================${NC}"
