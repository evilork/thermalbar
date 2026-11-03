#!/bin/bash
# install.sh - builds ThermalBar from source, installs it to /Applications and opens it at login.
# v2 reads every sensor natively: no Homebrew, no macmon, no sudo.
set -euo pipefail

cd "$(dirname "$0")"

APP="ThermalBar"
LABEL="com.evilork.thermalbar"
LEGACY_LABEL="com.evilork.macmon"
APP_DST="/Applications/${APP}.app"
LA="${HOME}/Library/LaunchAgents"
UID_NUM="$(id -u)"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m%s\033[0m\n' "$1"; }
note() { printf '\033[33m%s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# 1. Requirements
[ "$(uname -m)" = "arm64" ] || fail "ThermalBar needs an Apple Silicon Mac (M1 or newer)."
command -v swiftc >/dev/null 2>&1 || fail "Xcode Command Line Tools are required. Run: xcode-select --install"

# 2. Build (also runs the signature and minimum-macOS checks)
step "Building ${APP}"
./build.sh build

# 3. Quit a running copy
if pgrep -x "${APP}" >/dev/null 2>&1; then
  step "Quitting the running ${APP}"
  osascript -e "quit app \"${APP}\"" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -x "${APP}" >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -x "${APP}" >/dev/null 2>&1; then
    pkill -x "${APP}" || true
    sleep 1
  fi
fi

# 4. Install
step "Installing to /Applications"
rm -rf "${APP_DST}"
ditto "build/${APP}.app" "${APP_DST}" || fail "cannot copy the app to /Applications"

# 5. Remove the v1 helper agent (v2 does not need macmon)
if [ -f "${LA}/${LEGACY_LABEL}.plist" ] || launchctl print "gui/${UID_NUM}/${LEGACY_LABEL}" >/dev/null 2>&1; then
  step "Removing the v1 helper agent ${LEGACY_LABEL}"
  launchctl bootout "gui/${UID_NUM}/${LEGACY_LABEL}" >/dev/null 2>&1 || true
  rm -f "${LA}/${LEGACY_LABEL}.plist"
  note "The macmon program itself was left installed; remove it with 'brew uninstall macmon' if nothing else uses it."
fi

# 6. Open at login (the same file the app's "Open at login" switch manages)
step "Setting up open at login"
mkdir -p "${LA}"
launchctl bootout "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1 || true
cat > "${LA}/${LABEL}.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>${APP_DST}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PL
plutil -lint -s "${LA}/${LABEL}.plist" || fail "the launch agent plist is not valid"

# 7. Open now
open "${APP_DST}" || fail "cannot open ${APP_DST}"
echo
ok "Done. ThermalBar is in your menu bar and opens at login."
echo "Click it for the panel; Settings are at the bottom of the panel."
echo "Uninstall anytime: ./uninstall.sh"
