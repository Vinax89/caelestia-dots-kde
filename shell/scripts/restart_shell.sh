#!/bin/bash
set -euo pipefail

# Every teardown step below is best-effort: the shell may already be stopped,
# and none of these failing should prevent the restart at the end.
/usr/bin/caelestia shell -k 2>/dev/null || true
sleep 1.3

if pgrep -x quickshell > /dev/null; then
    killall -w quickshell 2>/dev/null || true
fi
if pgrep -x qs > /dev/null; then
    killall -w qs 2>/dev/null || true
fi

# Wipe the stale Quickshell socket locks
rm -rf "${XDG_RUNTIME_DIR:-/run/user/$UID}/quickshell/"* || true

# shellcheck disable=SC1091
. /etc/profile || true
[ -f ~/.profile ] && { . ~/.profile || true; }
[ -f ~/.bashrc ] && { . ~/.bashrc || true; }
export QML2_IMPORT_PATH="$HOME/.local/lib/qt6/qml"
export CAELESTIA_LIB_DIR="$HOME/.local/lib/caelestia"
export QS_NO_RELOAD_POPUP=1
export QS_DROP_EXPENSIVE_FONTS=1
export QS_DISABLE_CRASH_HANDLER=1
export QSG_RENDER_LOOP=threaded
export QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000

/usr/bin/caelestia shell -d
