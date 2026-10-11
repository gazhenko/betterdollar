#!/bin/bash
# Build, run and test BetterDollar. SIM_UDID picks the simulator (defaults to the first available iPhone 17 Pro).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SIM_UDID="${SIM_UDID:-$(xcrun simctl list devices available | grep -m1 "iPhone 17 Pro (" | grep -oE '[0-9A-F-]{36}')}"
DERIVED="$ROOT/build/DerivedData"
FLAGS=(-skipPackagePluginValidation -skipMacroValidation)
ACTION="${1:-help}"; [[ $# -gt 0 ]] && shift
mkdir -p build/logs

xcode() {
  xcodebuild -project BetterDollar.xcodeproj -scheme BetterDollar -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIM_UDID" -derivedDataPath "$DERIVED" "${FLAGS[@]}" CODE_SIGNING_ALLOWED=NO "$@"
}
boot() { xcrun simctl boot "$SIM_UDID" 2>/dev/null || true; }

case "$ACTION" in
  generate) xcodegen generate ;;
  build) xcodegen generate; xcode build ;;
  run)
    xcodegen generate; xcode build; boot
    xcrun simctl install "$SIM_UDID" "$DERIVED/Build/Products/Debug-iphonesimulator/BetterDollar.app"
    xcrun simctl launch --terminate-running-process "$SIM_UDID" com.gazhenko.betterdollar "$@" ;;
  test-core) (cd Packages/BetterDollarCore && swift test) ;;
  test-coach)
    (cd Packages/BetterDollarCoach && xcodebuild -scheme BetterDollarCoach -destination 'platform=macOS' \
      -derivedDataPath "$ROOT/build/DerivedData-coach" "${FLAGS[@]}" test) ;;
  test-ui)
    xcodegen generate; boot
    xcode -parallel-testing-enabled NO -resultBundlePath "build/logs/ui-$(date +%Y%m%d-%H%M%S).xcresult" test "$@" ;;
  screenshot) xcrun simctl io "$SIM_UDID" screenshot "${1:?Usage: scripts/dev.sh screenshot <png>}" ;;
  device)
    # Install on a connected iPhone with a free Personal Team: scripts/dev.sh device <TEAM_ID> <xcodebuild device id> <devicectl id>
    xcodegen generate
    xcodebuild -project BetterDollar.xcodeproj -scheme BetterDollar -configuration Debug -destination "id=$2" \
      -derivedDataPath "$ROOT/build/device" "${FLAGS[@]}" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
      DEVELOPMENT_TEAM="$1" build
    xcrun devicectl device install app --device "$3" "$ROOT/build/device/Build/Products/Debug-iphoneos/BetterDollar.app" ;;
  *) echo "Usage: scripts/dev.sh generate|build|run [args]|test-core|test-coach|test-ui|screenshot <png>|device <team> <id> <coredevice id>" ;;
esac
