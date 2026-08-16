#!/bin/bash
set -euo pipefail

# Syncs or modifies kde-material-you-colors configuration

CONF_DIR="$HOME/.config/kde-material-you-colors"
CONF_FILE="$CONF_DIR/config.conf"

mkdir -p "$CONF_DIR"

if [ ! -f "$CONF_FILE" ]; then
    kde-material-you-colors -c || true
fi

if [ ! -f "$CONF_FILE" ]; then
    touch "$CONF_FILE"
fi

# Escape a value for the replacement side of a sed s/// expression
escape_sed_replacement() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//\//\\/}"
    printf '%s' "$s"
}

update_or_uncomment() {
    local key="$1"
    local value="$2"
    if [[ ! "$key" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        echo "Error: invalid config key: ${key}" >&2
        exit 1
    fi
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        echo "Error: value for ${key} must be a single line" >&2
        exit 1
    fi
    local value_rep
    value_rep="$(escape_sed_replacement "$value")"
    if grep -E -q "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$CONF_FILE"; then
        sed -i -E "s/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*/${key} = ${value_rep}/" "$CONF_FILE"
    else
        printf '%s = %s\n' "$key" "$value" >> "$CONF_FILE"
    fi
}

# If the first argument is a hex color (e.g. #ff0000), use the legacy positional format
if [[ "${1:-}" == "#"* ]]; then
    update_or_uncomment "color" "${1:-}"
    update_or_uncomment "scheme_variant" "${2:-}"
    update_or_uncomment "light" "${3:-}"
    exit 0
fi

# Modern argument parsing for arbitrary key-value sets
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --set)
            if [ -n "${2:-}" ] && [ -n "${3:-}" ]; then
                update_or_uncomment "$2" "$3"
                shift 3
            else
                echo "Error: --set requires KEY and VALUE"
                exit 1
            fi
            ;;
        *)
            echo "Unknown parameter: $1"
            exit 1
            ;;
    esac
done
