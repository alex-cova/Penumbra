#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

APP_NAME="Umbra"
BUNDLE_ID="com.umbra.editor"
VERSION="$(tr -d '[:space:]' < VERSION)"
CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-$root/dist}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ENTITLEMENTS="$root/Example/Resources/Umbra.entitlements"
INFO_PLIST_TEMPLATE="$root/Example/Resources/Info.plist"
ICON_SOURCE="$root/Example/umbra.icon"

echo "==> Building Umbra ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product Umbra

BIN_PATH="$(swift build -c "$CONFIGURATION" --product Umbra --show-bin-path)"
BINARY="$BIN_PATH/Umbra"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

SPARKLE_FRAMEWORK="$(find "$root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework" -path '*/Sparkle.framework' -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" || ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: Sparkle.framework not found; run 'swift build -c $CONFIGURATION --product Umbra' first" >&2
  exit 1
fi
mkdir -p "$APP_DIR/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# On-device models (MLX) need their compiled Metal kernels at run time. SwiftPM builds them into a
# resource bundle next to the binary; Umbra looks for `Contents/Resources/mlx.metallib` and tells MLX
# where it is, and without it the on-device provider reports "this build has no MLX shaders".
MLX_METALLIB="$BIN_PATH/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [[ -f "$MLX_METALLIB" ]]; then
  cp "$MLX_METALLIB" "$APP_DIR/Contents/Resources/mlx.metallib"
else
  echo "warning: $MLX_METALLIB not found; on-device models will be unavailable in this build" >&2
fi

cp "$INFO_PLIST_TEMPLATE" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_DIR/Contents/Info.plist"

if [[ -d "$ICON_SOURCE" ]]; then
  echo "==> Compiling app icon from umbra.icon…"
  ICON_STAGING="$(mktemp -d)"
  xcrun actool "$ICON_SOURCE" \
    --compile "$ICON_STAGING" \
    --app-icon umbra \
    --output-partial-info-plist "$ICON_STAGING/partial.plist" \
    --include-all-app-icons \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --platform macosx
  for artifact in Assets.car umbra.icns; do
    if [[ -f "$ICON_STAGING/$artifact" ]]; then
      cp "$ICON_STAGING/$artifact" "$APP_DIR/Contents/Resources/"
    fi
  done
  rm -rf "$ICON_STAGING"
elif [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$APP_DIR/Contents/Resources/umbra.icns"
fi

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing with identity: $SIGN_IDENTITY"
  codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR"
else
  echo "==> Skipping codesign (set CODESIGN_IDENTITY to sign)"
fi

ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-macOS.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
echo "==> Created $ZIP_PATH"

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_NOTARIZATION_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" && -n "$SIGN_IDENTITY" ]]; then
  echo "==> Submitting for notarization…"
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_NOTARIZATION_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  echo "==> Stapling ticket…"
  xcrun stapler staple "$APP_DIR"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
  echo "==> Re-packed stapled app to $ZIP_PATH"
fi

echo "Done."
