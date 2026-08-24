#!/usr/bin/env sh
# POSIX sh: `pipefail` is not available here, so this is `set -eu`.
set -eu

# Replaying the sequence file is optional -- it does not exist until the theme
# has been generated once, and a missing file must not stop the terminal from
# launching.
cat ~/.local/state/caelestia/sequences.txt 2>/dev/null || true

exec "$@"
