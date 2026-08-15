#!/usr/bin/env bash
set -euo pipefail

action="${1:?usage: game-mode-kde.sh enable|disable STATE_FILE}"
state_file="${2:?missing state file}"

case "$action" in
    enable)
        if [[ ! -e "$state_file" ]]; then
            prev_blur="$(kreadconfig6 --file kwinrc --group Plugins --key blurEnabled --default true)"
            prev_anim="$(kreadconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor --default 1)"
            mkdir -p "$(dirname "$state_file")"
            printf '%s\n%s\n' "$prev_blur" "$prev_anim" > "$state_file"
        fi
        kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled false
        kwriteconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor --notify 0
        ;;
    disable)
        prev_blur="$(sed -n 1p "$state_file" 2>/dev/null || true)"
        prev_anim="$(sed -n 2p "$state_file" 2>/dev/null || true)"
        kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled "${prev_blur:-true}"
        kwriteconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor --notify "${prev_anim:-1}"
        rm -f -- "$state_file"
        ;;
    *) echo "unknown action: $action" >&2; exit 2 ;;
esac

qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1
