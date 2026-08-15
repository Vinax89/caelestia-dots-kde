#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="${CONTAINER_ENGINE:-}"

if [[ -z "$ENGINE" ]]; then
    ENGINE="$(command -v docker 2>/dev/null || command -v podman 2>/dev/null || true)"
fi
if [[ -z "$ENGINE" ]]; then
    echo "docker or podman is required" >&2
    exit 2
fi

run_case() {
    local distro="$1" image="$2"
    echo "[integration] $distro ($image)"
    "$ENGINE" run --rm --init \
        -v "$ROOT:/workspace:ro" \
        -w /workspace \
        -e "TEST_DISTRO=$distro" \
        "$image" bash tests/integration/run-in-container.sh
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        arch) run_case arch archlinux:base ;;
        fedora) run_case fedora fedora:42 ;;
        debian) run_case debian debian:bookworm ;;
        *) echo "unknown distro: $1" >&2; exit 2 ;;
    esac
else
    run_case arch archlinux:base
    run_case fedora fedora:42
    run_case debian debian:bookworm
fi
