#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP="$ROOT/build/LongScreenShot.app"
ASSET_CATALOG="$ROOT/Assets.xcassets"
ASSET_INFO="$ROOT/build/assetcatalog-info.plist"

cd "$ROOT"
SWIFT_ARGS=()
if [[ "${LONGSCREENSHOT_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
  SWIFT_ARGS+=(--disable-sandbox)
fi
swift build -c "$CONFIGURATION" "${SWIFT_ARGS[@]}"
BIN_PATH="$(swift build -c "$CONFIGURATION" "${SWIFT_ARGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/LongScreenShot" "$APP/Contents/MacOS/LongScreenShot"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -d "$ASSET_CATALOG" ]]; then
  rm -f "$ASSET_INFO"
  xcrun actool "$ASSET_CATALOG" \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --target-device mac \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_INFO" >/dev/null

  if [[ -f "$ASSET_INFO" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
    ICON_FILE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$ASSET_INFO" 2>/dev/null || true)
    ICON_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$ASSET_INFO" 2>/dev/null || true)
    if [[ -n "$ICON_FILE" ]]; then
      /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $ICON_FILE" "$APP/Contents/Info.plist"
    fi
    if [[ -n "$ICON_NAME" ]]; then
      /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $ICON_NAME" "$APP/Contents/Info.plist"
    fi
  fi
fi
codesign --force --deep --sign - "$APP"

echo "$APP"
