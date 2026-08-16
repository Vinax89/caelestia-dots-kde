#!/usr/bin/env bash

# Caelestia supplies its own exclusive-zone panel. A visible Plasma panel on
# the same edge contributes a second strut even while Caelestia covers it,
# leaving an unexplained gap between maximized windows and the Caelestia bar.
panels="$(qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
    'panels().forEach(p => print(p.id + ":" + p.hiding))' 2>/dev/null || true)"

if [[ -n "$panels" ]] && grep -qv ':autohide$' <<< "$panels"; then
    qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
        'panels().forEach(p => { p.hiding = "autohide"; })' >/dev/null 2>&1 || true
    # Plasma 6 persists panelVisibility immediately but does not withdraw the
    # old strut until its panel view is recreated.
    systemctl --user restart plasma-plasmashell.service 2>/dev/null || true
fi

echo "StartupTasks: Disabled duplicate Plasma panel reservations"
exit 0
