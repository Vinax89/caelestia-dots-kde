#!/usr/bin/env bash
# 06-services.sh  Enable systemd user services and reload KWin.

set -euo pipefail

echo
echo ""
echo "  Step 6/11  Services & KWin"
echo ""

if systemctl --user is-enabled --quiet qs-kwin-bridge.service 2>/dev/null || \
   systemctl --user is-active --quiet qs-kwin-bridge.service 2>/dev/null; then
    echo "  Disabling legacy qs-kwin-bridge service..."
    systemctl --user disable --now qs-kwin-bridge.service 2>/dev/null || true
fi

echo "  Clearing legacy KWin workspace shortcuts to avoid QML conflicts..."
for i in $(seq 1 10); do
    kwriteconfig6 --file kglobalshortcutsrc --group "kwin" --key "Switch to Desktop $i" "none,none,Switch to Desktop $i"
    kwriteconfig6 --file kglobalshortcutsrc --group "kwin" --key "Window to Desktop $i" "none,none,Move Window to Desktop $i"
done

echo "  Disabling legacy quickshell-kde-bridge KWin script..."
kwriteconfig6 --file kwinrc --group "Plugins" --key "quickshell-kde-bridgeEnabled" "false"

echo "  Setting default KWin virtual desktops to 5 (only if not already configured)..."
EXISTING_DESKTOPS="$(kreadconfig6 --file kwinrc --group "Desktops" --key "Number" 2>/dev/null || true)"
if [ -z "$EXISTING_DESKTOPS" ]; then
    kwriteconfig6 --file kwinrc --group "Desktops" --key "Number" "5"
    kwriteconfig6 --file kwinrc --group "Desktops" --key "Rows" "1"
    for i in $(seq 1 5); do
        kwriteconfig6 --file kwinrc --group "Desktops" --key "Name_$i" "Desktop $i"
    done
else
    echo "  Existing virtual desktop configuration found - leaving it untouched."
fi

# ydotoold (on-screen keyboard key injection) uses uaccess so only the
# currently active local session receives /dev/uinput access. Do not grant
# every user in the input group raw access to all input devices.
echo "  Applying system-level configurations (requires root)..."
sudo bash -s << 'EOF'
set -euo pipefail

if systemctl is-enabled --quiet keyd.service 2>/dev/null || \
   systemctl is-active --quiet keyd.service 2>/dev/null; then
    echo "  Disabling legacy keyd service..."
    systemctl disable --now keyd.service 2>/dev/null || true
fi

echo "  Setting up ydotoold (OSK key injection daemon)..."
cat > /etc/udev/rules.d/80-uinput.rules <<'RULE'
KERNEL=="uinput", TAG+="uaccess"
RULE
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=misc --sysname-match=uinput 2>/dev/null || true
echo "  [OK]  udev uaccess rule for uinput created."
EOF

# Deploy ydotoold-wrapper script to ~/.local/bin
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/ydotoold-wrapper" << 'WRAPPER'
#!/bin/bash
# ydotoold-wrapper starts ydotoold with the active-session uaccess rule above.
SOCKET="${YDOTOOL_SOCKET:-/run/user/$(id -u)/.ydotool_socket}"
if [ -S "$SOCKET" ] && pidof ydotoold > /dev/null 2>&1; then
    exit 0
fi
exec /usr/bin/ydotoold \
    --socket-path="$SOCKET" \
    --socket-perm=0660
WRAPPER
chmod +x "$HOME/.local/bin/ydotoold-wrapper"
echo "  [OK]  ydotoold-wrapper deployed to ~/.local/bin."

# Deploy and enable ydotoold systemd user service
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/ydotoold.service" << 'UNIT'
[Unit]
Description=ydotoold key injection daemon
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.local/bin/ydotoold-wrapper
Restart=on-failure
Environment=YDOTOOL_SOCKET=/run/user/%U/.ydotool_socket

[Install]
WantedBy=graphical-session.target
UNIT
systemctl --user daemon-reload
systemctl --user enable ydotoold.service 2>/dev/null || true
systemctl --user start ydotoold.service 2>/dev/null || \
    echo "  [INFO] ydotoold will start on next login."
echo "  [OK]  ydotoold service configured."

echo "[OK]  Services configured."
