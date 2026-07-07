#!/bin/zsh
set -euo pipefail

# =========================
# 基础配置
# =========================

APP_NAME="LongScreenShot"
EXECUTABLE_NAME="LongScreenShot"
MIN_MACOS_VERSION="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
DMG_ROOT="$BUILD_DIR/dmgroot"
DMG_TEMP="$BUILD_DIR/$APP_NAME-temp.dmg"
DMG="$BUILD_DIR/$APP_NAME.dmg"
ASSET_CATALOG="$ROOT/Assets.xcassets"
ASSET_INFO="$BUILD_DIR/assetcatalog-info.plist"

INFO_PLIST_SOURCE="$ROOT/Resources/Info.plist"

# 可选：Developer ID 签名
# 例如：
# export DEVELOPER_ID_APP="Developer ID Application: MustangYM (TEAMID)"
DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-}"

# 可选：notarytool 公证 profile
# 例如：
# export NOTARY_PROFILE="mustangym-notary"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

cd "$ROOT"

echo "==> Project root: $ROOT"
echo "==> Configuration: $CONFIGURATION"

mkdir -p "$BUILD_DIR"

# =========================
# SwiftPM 编译
# =========================

SWIFT_ARGS=()
if [[ "${LONGSCREENSHOT_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
  SWIFT_ARGS+=(--disable-sandbox)
fi

echo "==> swift build"
swift build -c "$CONFIGURATION" "${SWIFT_ARGS[@]}"

BIN_PATH="$(swift build -c "$CONFIGURATION" "${SWIFT_ARGS[@]}" --show-bin-path)"
BIN="$BIN_PATH/$EXECUTABLE_NAME"

if [[ ! -f "$BIN" ]]; then
  echo "ERROR: executable not found: $BIN"
  exit 1
fi

# =========================
# 组装 .app
# =========================

echo "==> Create app bundle: $APP"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

ditto "$BIN" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP/Contents/MacOS/$EXECUTABLE_NAME"

if [[ ! -f "$INFO_PLIST_SOURCE" ]]; then
  echo "ERROR: Info.plist not found: $INFO_PLIST_SOURCE"
  exit 1
fi

cp "$INFO_PLIST_SOURCE" "$APP/Contents/Info.plist"

# 确保 Info.plist 里的可执行文件名正确
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE_NAME" "$APP/Contents/Info.plist" >/dev/null 2>&1 || \
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $EXECUTABLE_NAME" "$APP/Contents/Info.plist"

# =========================
# 编译 Assets.xcassets
# =========================

if [[ -d "$ASSET_CATALOG" ]]; then
  echo "==> Compile asset catalog"

  rm -f "$ASSET_INFO"

  xcrun actool "$ASSET_CATALOG" \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target "$MIN_MACOS_VERSION" \
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

  if [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    echo "ERROR: Assets.car not generated"
    exit 1
  fi

  echo "==> Check AppIcon in Assets.car"
  if ! xcrun assetutil --info "$APP/Contents/Resources/Assets.car" | grep -q "AppIcon"; then
    echo "WARNING: AppIcon not found in Assets.car"
  fi

  echo "==> Check StatusBarIcon in Assets.car"
  if ! xcrun assetutil --info "$APP/Contents/Resources/Assets.car" | grep -q "StatusBarIcon"; then
    echo "WARNING: StatusBarIcon not found in Assets.car"
    echo "WARNING: 状态栏图标资源可能没有被打进 app"
  fi
else
  echo "WARNING: Assets.xcassets not found: $ASSET_CATALOG"
fi

# =========================
# 签名 .app
# =========================

echo "==> Code sign app"

if [[ -n "$DEVELOPER_ID_APP" ]]; then
  echo "==> Using Developer ID identity: $DEVELOPER_ID_APP"

  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$DEVELOPER_ID_APP" \
    "$APP"
else
  echo "WARNING: DEVELOPER_ID_APP not set, using ad-hoc signature"
  echo "WARNING: 这种签名只适合本机测试，不适合正式分发给别人"

  codesign \
    --force \
    --deep \
    --sign - \
    "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"

# 让 Finder 刷新图标缓存时更容易识别
touch "$APP"

# =========================
# 创建 DMG 根目录
# =========================

echo "==> Create DMG root"

rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"

# 重点：这里必须复制已经完整组装好的 .app
# 不要重新复制 .build/release/LongScreenShot 二进制
ditto "$APP" "$DMG_ROOT/$APP_NAME.app"

# 添加 Applications 快捷方式
ln -s /Applications "$DMG_ROOT/Applications"

# 检查 DMG 里的 app 是否真的带资源
if [[ ! -f "$DMG_ROOT/$APP_NAME.app/Contents/Resources/Assets.car" ]]; then
  echo "ERROR: Assets.car missing in DMG app"
  exit 1
fi

# =========================
# 创建 DMG
# =========================

echo "==> Create DMG"

rm -f "$DMG_TEMP"
rm -f "$DMG"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG"

# =========================
# 签名 DMG
# =========================

if [[ -n "$DEVELOPER_ID_APP" ]]; then
  echo "==> Code sign DMG"

  codesign \
    --force \
    --timestamp \
    --sign "$DEVELOPER_ID_APP" \
    "$DMG"

  codesign --verify --verbose=2 "$DMG"
fi

# =========================
# 可选：公证 DMG
# =========================

if [[ -n "$DEVELOPER_ID_APP" && -n "$NOTARY_PROFILE" ]]; then
  echo "==> Submit DMG to Apple notarization"

  xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "==> Staple notarization ticket to DMG"
  xcrun stapler staple "$DMG"

  echo "==> Verify notarization"
  xcrun stapler validate "$DMG"
else
  echo "WARNING: Skip notarization"
  echo "WARNING: 如需正式分发，请设置 DEVELOPER_ID_APP 和 NOTARY_PROFILE"
fi

echo ""
echo "DONE"
echo "App: $APP"
echo "DMG: $DMG"