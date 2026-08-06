#!/bin/bash
# install.sh — one-command installer for ThermalBar.
# Builds the app, installs to /Applications, sets up auto-start.
# On Apple Silicon, optionally starts a background macmon server for GPU
# temperature and power readings. On Intel Macs, sensors are read via SMC
# and RAM natively - no helper needed.
set -euo pipefail

APP="ThermalBar"
BUNDLE_ID_APP="com.evilork.thermalbar"
BUNDLE_ID_MACMON="com.evilork.macmon"
PORT=9090
LA="$HOME/Library/LaunchAgents"
APP_DST="/Applications/$APP.app"
ARCH="$(uname -m)"

cyan()  { printf "\033[36m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$1"; }

cyan "ThermalBar installer ($ARCH)"
echo

# 1. Toolchain check
if ! command -v swiftc >/dev/null; then
  yellow "Xcode Command Line Tools required. Run: xcode-select --install"
  exit 1
fi

# 2. macmon (Apple Silicon only — needed only for GPU temp + power there)
MACMON=""
if [ "$ARCH" = "arm64" ]; then
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
else
  echo "Intel Mac detected: reading CPU/GPU via SMC, RAM natively (no helper needed)."
fi

# 2b. Power daemon (Intel only): root LaunchDaemon streaming powermetrics
#     CPU package power into /var/tmp/thermalbar-power. Requires sudo once.
POWER_LABEL="com.evilork.thermalbar.power"
POWER_DAEMON="/Library/LaunchDaemons/$POWER_LABEL.plist"
if [ "$ARCH" = "x86_64" ]; then
  yellow "Installing power daemon (CPU watts) — sudo required..."
  if sudo -v; then
    sudo launchctl bootout "system/$POWER_LABEL" 2>/dev/null || true
    sudo tee "$POWER_DAEMON" > /dev/null << 'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.evilork.thermalbar.power</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>/usr/bin/powermetrics --samplers cpu_power -i 1000 2&gt;/dev/null | /usr/bin/grep --line-buffered "package power" | while IFS= read -r line; do w="${line##*: }"; w="${w%W}"; printf '%s\n' "$w" &gt; /var/tmp/thermalbar-power.tmp; mv -f /var/tmp/thermalbar-power.tmp /var/tmp/thermalbar-power; done</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PL
    sudo launchctl bootstrap system "$POWER_DAEMON" && green "Power daemon running (CPU watts enabled)." \
      || yellow "Power daemon failed to start; watts will stay hidden."
  else
    yellow "sudo skipped; watts will stay hidden."
  fi
fi

# 3. Build
cyan "Building $APP..."
rm -rf build
mkdir -p "build/$APP.app/Contents/MacOS" "build/$APP.app/Contents/Resources"
iconutil -c icns Resources/AppIcon.iconset -o "build/$APP.app/Contents/Resources/AppIcon.icns"
swiftc -O \
  -import-objc-header Sources/ThermalBar-Bridging-Header.h \
  Sources/Sensors.m \
  Sources/SMC.m \
  Sources/main.swift Sources/Config.swift Sources/Sampler.swift Sources/Memory.swift Sources/SettingsWindow.swift Sources/StatusController.swift \
  -framework Cocoa -framework IOKit -framework SwiftUI \
  -o "build/$APP.app/Contents/MacOS/$APP"

cat > "build/$APP.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ThermalBar</string>
  <key>CFBundleDisplayName</key><string>ThermalBar</string>
  <key>CFBundleIdentifier</key><string>com.evilork.thermalbar</string>
  <key>CFBundleVersion</key><string>1.1.0</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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

# 6. macmon serve agent (Apple Silicon only: GPU temp + power)
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
else
  rm -f "$LA/$BUNDLE_ID_MACMON.plist"
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
