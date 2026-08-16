#!/usr/bin/env bash
# 02a-submodules.sh - Initialize git submodules

set -euo pipefail

# Initialize submodules
if [[ -f "$BUNDLE_DIR/.gitmodules" ]]; then
    echo "[INFO]  Initializing submodules..."
    git submodule sync --recursive
    if ! git submodule update --init --recursive --force; then
        echo "[FAIL]  Failed to initialize all submodules." >&2
        exit 1
    fi
fi