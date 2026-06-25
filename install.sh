#!/bin/bash
# install.sh — one-command installer for ThermalBar.
# Builds the app, installs to /Applications, sets up auto-start, and (optionally)
# starts a background macmon server for GPU temperature and power readings.
set -euo pipefail

APP="ThermalBar"
BUNDLE_ID_APP="com.evilork.thermalbar"
BUNDLE_ID_MACMON="com.evilork.macmon"
PORT=9090
LA="$HOME/Library/LaunchAgents"
APP_DST="/Applications/$APP.app"

cyan()  { printf "\033[36m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$1"; }

cyan "ThermalBar installer"
echo

# 1. Toolchain check
if ! command -v swiftc >/dev/null; then
  yellow "Xcode Command Line Tools required. Run: xcode-select --install"
  exit 1
fi

# 2. macmon (optional — needed only for GPU temp + power)
MACMON="$(command -v macmon || true)"
if [ -z "$MACMON" ]; then
  if command -v brew >/dev/null; then
    yellow "macmon not found — installing via Homebrew (enables GPU temp + power)..."
    brew install macmon || yellow "macmon install failed; CPU temp will still work."
    MACMON="$(command -v macmon || true)"
  else
    yellow "macmon not found and Homebrew unavailable. CPU temp works; GPU/W disabled."
  fi
fi

# 3. Build
cyan "Building $APP..."
rm -rf build
mkdir -p "build/$APP.app/Contents/MacOS"
swiftc -O \
  -import-objc-header Sources/ThermalBar-Bridging-Header.h \
  Sources/Sensors.m \
  Sources/main.swift Sources/Config.swift Sources/Sampler.swift Sources/StatusController.swift \
  -framework Cocoa -framework IOKit \
  -o "build/$APP.app/Contents/MacOS/$APP"

cat > "build/$APP.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ThermalBar</string>
  <key>CFBundleDisplayName</key><string>ThermalBar</string>
  <key>CFBundleIdentifier</key><string>com.evilork.thermalbar</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>ThermalBar</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# 4. Install to /Applications
cyan "Installing to /Applications..."
rm -rf "$APP_DST"
cp -R "build/$APP.app" /Applications/

# 5. Stop any running instances
launchctl bootout "gui/$(id -u)/$BUNDLE_ID_APP" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$BUNDLE_ID_MACMON" 2>/dev/null || true
pkill -9 -f "$APP.app/Contents/MacOS" 2>/dev/null || true
pkill -9 -f "macmon serve" 2>/dev/null || true
sleep 1

mkdir -p "$LA"

# 6. macmon serve agent (GPU temp + power)
if [ -n "$MACMON" ]; then
cat > "$LA/$BUNDLE_ID_MACMON.plist" << PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID_MACMON</string>
  <key>ProgramArguments</key>
  <array>
    <string>$MACMON</string><string>serve</string>
    <string>-p</string><string>$PORT</string>
    <string>-i</string><string>1000</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PL
launchctl bootstrap "gui/$(id -u)" "$LA/$BUNDLE_ID_MACMON.plist"
green "macmon server running on port $PORT (GPU temp + power)."
fi

# 7. ThermalBar UI agent (delayed start so macmon is ready first)
cat > "$LA/$BUNDLE_ID_APP.plist" << PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID_APP</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>sleep 5; exec /usr/bin/open -a "$APP_DST"</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
PL
launchctl bootstrap "gui/$(id -u)" "$LA/$BUNDLE_ID_APP.plist"

# 8. Launch now
open "$APP_DST"
echo
green "Done. ThermalBar is now in your menu bar and will auto-start on login."
echo "Configure via the menu bar icon, or edit ~/.config/thermalbar/config.json"
echo "Uninstall anytime: ./uninstall.sh"
