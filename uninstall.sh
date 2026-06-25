#!/bin/bash
# uninstall.sh — remove ThermalBar completely (both launch agents, config, app).
set -euo pipefail
for label in com.evilork.thermalbar com.evilork.macmon; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -rf "$HOME/.config/thermalbar"
rm -rf /Applications/ThermalBar.app
pkill -f "ThermalBar.app/Contents/MacOS" 2>/dev/null || true
pkill -f "macmon serve" 2>/dev/null || true
echo "ThermalBar removed. macmon itself kept (run 'brew uninstall macmon' if unwanted)."
