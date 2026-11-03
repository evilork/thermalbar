#!/bin/bash
# uninstall.sh - removes ThermalBar: the app, its login agent, the legacy v1 helper agent,
# settings and saved history. The macmon program (if v1 installed it) is left alone.
set -euo pipefail

APP="ThermalBar"
UID_NUM="$(id -u)"
LA="${HOME}/Library/LaunchAgents"

removed() { printf '\033[32mremoved\033[0m %s\n' "$1"; }

if pgrep -x "${APP}" >/dev/null 2>&1; then
  osascript -e "quit app \"${APP}\"" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -x "${APP}" >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -x "${APP}" 2>/dev/null || true
  echo "quit the running ${APP}"
fi

for label in com.evilork.thermalbar com.evilork.macmon; do
  launchctl bootout "gui/${UID_NUM}/${label}" >/dev/null 2>&1 || true
  if [ -f "${LA}/${label}.plist" ]; then
    rm -f "${LA}/${label}.plist"
    removed "${LA}/${label}.plist"
  fi
done

for path in "/Applications/${APP}.app" "${HOME}/.config/thermalbar" "${HOME}/Library/Application Support/${APP}"; do
  if [ -e "${path}" ]; then
    rm -rf "${path}"
    removed "${path}"
  fi
done

echo "ThermalBar is removed. macmon (if v1 installed it) was kept: 'brew uninstall macmon' removes it."
