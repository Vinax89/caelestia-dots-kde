#!/usr/bin/env bash
set -euo pipefail

page="${1:-}"
caelestia shell -k || true
sleep 2
caelestia shell -d
if [[ -n "$page" ]]; then
    sleep 1
    caelestia shell nexus openPage 0 "$page"
fi
