#!/usr/bin/env bash
set -euo pipefail

command -v asdbctl >/dev/null 2>&1 || exit 0
exec asdbctl get
