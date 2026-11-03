#!/bin/bash
# build.sh - builds, tests, signs and packages ThermalBar. Writes only into ./build.
#
#   ./build.sh            build build/ThermalBar.app (same as ./build.sh build)
#   ./build.sh test       compile and run the unit tests
#   ./build.sh zip        build, optionally notarize, and write build/ThermalBar-<version>.zip (+ .sha256)
#   ./build.sh clean      remove ./build
#
# Maintainers: SIGN_IDENTITY="Developer ID Application: ..." signs with hardened runtime;
# NOTARY_PROFILE=<notarytool keychain profile> (with SIGN_IDENTITY) notarizes and staples the zip build.
set -euo pipefail

cd "$(dirname "$0")"

APP="ThermalBar"
BUNDLE_ID="com.evilork.thermalbar"
MIN_MACOS="13.0"
TARGET="arm64-apple-macos${MIN_MACOS}"
BUILD="build"
APP_DIR="${BUILD}/${APP}.app"
OBJ_DIR="${BUILD}/obj"
BRIDGE="Sources/ThermalBar-Bridging-Header.h"
# v1 sources that are not part of v2 (skipped if they are still around).
LEGACY=("Sources/Sampler.swift" "Sources/StatusController.swift")
# Foundation-only sources that the test runner compiles.
PURE=(Levels Snapshot Config L10n History Detectors ProcessList Games)

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m%s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

read_version() {
  [ -f VERSION ] || fail "VERSION file is missing"
  VERSION="$(tr -d '[:space:]' < VERSION)"
  [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like 1.2.3, got '${VERSION}'"
}

require_tools() {
  local t
  for t in "$@"; do
    command -v "${t}" >/dev/null 2>&1 || fail "${t} not found (install Xcode Command Line Tools: xcode-select --install)"
  done
}

is_legacy() {
  local f="$1" l
  for l in "${LEGACY[@]}"; do
    [ "${f}" = "${l}" ] && return 0
  done
  return 1
}

compile_objc() {
  step "Compiling Objective-C sources"
  mkdir -p "${OBJ_DIR}"
  OBJECTS=()
  local src obj
  for src in Sources/*.m; do
    [ -e "${src}" ] || continue
    obj="${OBJ_DIR}/$(basename "${src%.m}").o"
    clang -c -O2 -fobjc-arc -Wall -Wextra -target "${TARGET}" "${src}" -o "${obj}" \
      || fail "clang failed on ${src}"
    OBJECTS+=("${obj}")
  done
  [ "${#OBJECTS[@]}" -gt 0 ] || fail "no Objective-C sources found in Sources/"
}

write_info_plist() {
  cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP}</string>
  <key>CFBundleDisplayName</key><string>${APP}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>${APP}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 evilork. MIT License.</string>
</dict>
</plist>
PLIST
  plutil -lint -s "${APP_DIR}/Contents/Info.plist" || fail "Info.plist is not valid"
}

sign_app() {
  # Extended attributes (provenance, Finder info) break signing and leak into the zip.
  xattr -cr "${APP_DIR}" || fail "cannot clear extended attributes"
  if [ -n "${SIGN_IDENTITY:-}" ]; then
    step "Signing with ${SIGN_IDENTITY} (hardened runtime)"
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_DIR}" \
      || fail "codesign failed"
  else
    step "Signing ad-hoc (set SIGN_IDENTITY for a Developer ID signature)"
    codesign --force --sign - "${APP_DIR}" || fail "ad-hoc codesign failed"
  fi
  codesign --verify --strict --verbose=1 "${APP_DIR}" || fail "signature does not verify"
}

check_min_os() {
  step "Checking the minimum macOS version of the binary"
  local bin="${APP_DIR}/Contents/MacOS/${APP}" minos
  minos="$(vtool -show-build "${bin}" 2>/dev/null | awk '/minos/ {print $2; exit}')"
  if [ -z "${minos}" ]; then
    minos="$(otool -l "${bin}" | awk '/LC_BUILD_VERSION/ {found=1} found && /minos/ {print $2; exit}')"
  fi
  [ -n "${minos}" ] || fail "cannot read the minimum macOS version of ${bin}"
  # v1 shipped with minos 26.0 and would not start on macOS 15 (issue #2).
  [ "${minos}" = "${MIN_MACOS}" ] || fail "binary requires macOS ${minos}, expected ${MIN_MACOS}"
  ok "minimum macOS: ${minos}"
}

build_app() {
  read_version
  require_tools clang swiftc codesign plutil
  [ -f "${BRIDGE}" ] || fail "${BRIDGE} is missing"
  [ -f Resources/AppIcon.icns ] || fail "Resources/AppIcon.icns is missing (run: swift tools/make-icon.swift)"

  compile_objc

  local swift_sources=() src
  for src in Sources/*.swift; do
    [ -e "${src}" ] || continue
    is_legacy "${src}" && continue
    swift_sources+=("${src}")
  done
  [ "${#swift_sources[@]}" -gt 0 ] || fail "no Swift sources found in Sources/"

  step "Compiling ${APP} ${VERSION} for ${TARGET}"
  rm -rf "${APP_DIR}"
  mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
  swiftc -O -swift-version 5 -target "${TARGET}" \
    -import-objc-header "${BRIDGE}" \
    "${swift_sources[@]}" "${OBJECTS[@]}" \
    -framework Cocoa -framework IOKit -framework SwiftUI -framework UserNotifications -framework Combine \
    -lIOReport \
    -o "${APP_DIR}/Contents/MacOS/${APP}" \
    || fail "swiftc failed"

  write_info_plist
  cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
  printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

  sign_app
  check_min_os
  ok "Built ${APP_DIR}"
}

run_tests() {
  require_tools swiftc
  [ -f Tests/main.swift ] || fail "Tests/main.swift is missing"
  local sources=() name
  for name in "${PURE[@]}"; do
    [ -f "Sources/${name}.swift" ] || fail "Sources/${name}.swift is missing"
    sources+=("Sources/${name}.swift")
  done
  step "Compiling tests"
  mkdir -p "${BUILD}/tests"
  swiftc -swift-version 5 -target "${TARGET}" \
    -import-objc-header "${BRIDGE}" \
    Tests/*.swift "${sources[@]}" \
    -o "${BUILD}/tests/run" \
    || fail "test build failed"
  step "Running tests"
  "${BUILD}/tests/run" || fail "tests failed"
  ok "All tests passed"
}

make_zip() {
  build_app
  local zip="${BUILD}/${APP}-${VERSION}.zip"
  rm -f "${zip}" "${zip}.sha256"
  step "Packaging ${zip}"
  ditto -c -k --norsrc --noextattr --noacl --keepParent "${APP_DIR}" "${zip}" || fail "ditto failed"

  if [ -n "${NOTARY_PROFILE:-}" ]; then
    [ -n "${SIGN_IDENTITY:-}" ] || fail "NOTARY_PROFILE needs SIGN_IDENTITY (ad-hoc builds cannot be notarized)"
    require_tools xcrun spctl
    step "Notarizing (this can take a few minutes)"
    local log="${BUILD}/notary.log" status
    xcrun notarytool submit "${zip}" --keychain-profile "${NOTARY_PROFILE}" --wait 2>&1 | tee "${log}" \
      || fail "notarytool submit failed (see ${log})"
    status="$(awk -F': ' '/^ *status:/ {s=$2} END {print s}' "${log}")"
    [ "${status}" = "Accepted" ] || fail "notarization status: ${status:-unknown} (see ${log})"
    step "Stapling the ticket"
    xcrun stapler staple "${APP_DIR}" || fail "stapler failed"
    spctl -a -vv -t exec "${APP_DIR}" || fail "Gatekeeper rejects the app"
    rm -f "${zip}"
    ditto -c -k --norsrc --noextattr --noacl --keepParent "${APP_DIR}" "${zip}" || fail "ditto failed"
  fi

  (cd "${BUILD}" && shasum -a 256 "$(basename "${zip}")" > "$(basename "${zip}").sha256") \
    || fail "shasum failed"
  ok "Wrote ${zip}"
  cat "${zip}.sha256"
}

case "${1:-build}" in
  build) build_app ;;
  test) run_tests ;;
  zip) make_zip ;;
  clean) rm -rf "${BUILD}"; ok "Removed ${BUILD}/" ;;
  -h|--help|help) sed -n '2,10p' "$0" ;;
  *) fail "unknown command '$1' (use: build, test, zip, clean)" ;;
esac
