#!/bin/bash
# uninstall.sh — remove ThermalBar completely (both launch agents, config, app).
set -euo pipefail
for label in com.evilork.thermalbar com.evilork.macmon; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
# Intel power daemon (needs sudo)
if [ -f /Library/LaunchDaemons/com.evilork.thermalbar.power.plist ]; then
  sudo launchctl bootout system/com.evilork.thermalbar.power 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/com.evilork.thermalbar.power.plist
fi
rm -f /var/tmp/thermalbar-power /var/tmp/thermalbar-power.tmp
rm -rf "$HOME/.config/thermalbar"
rm -rf /Applications/ThermalBar.app
pkill -f "ThermalBar.app/Contents/MacOS" 2>/dev/null || true
pkill -f "macmon serve" 2>/dev/null || true
echo "ThermalBar removed. macmon itself kept (run 'brew uninstall macmon' if unwanted)."
