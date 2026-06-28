#!/bin/bash
# Package the macOS ace_macos executable + its dylib + resources into a runnable
# .app bundle. Signing (M9 notarization) is a separate step that needs an Apple
# Developer certificate.
#
# Usage: package_app.sh <out_dir> <app_name> [dest_dir]
#   out_dir : the gn out dir, e.g. .../out/arkui-x
#   app_name: bundle name without .app, e.g. ArkUI-X
#   dest_dir: where to write <app_name>.app (default: <out_dir>)
set -e

OUT_DIR="${1:?out_dir required}"
APP_NAME="${2:?app_name required}"
DEST_DIR="${3:-$OUT_DIR}"

EXE="$OUT_DIR/arkui/ace_engine/ace_macos"
DYLIB="$OUT_DIR/arkui/ace_engine_cross/libace_container_scope.dylib"
RES_SRC="$OUT_DIR/arkui/ace_engine/arkui-x"

APP="$DEST_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"

[ -f "$EXE" ] || { echo "missing exe: $EXE"; exit 1; }
[ -f "$DYLIB" ] || { echo "missing dylib: $DYLIB"; exit 1; }
[ -d "$RES_SRC" ] || { echo "missing resources: $RES_SRC"; exit 1; }

echo "=> building $APP"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS"

# 1) executable
cp "$EXE" "$MACOS_DIR/ace_macos"

# 2) dylib into Contents/Frameworks; the exe references it via a cwd-relative
#    install name (arkui/ace_engine_cross/...), which breaks once double-clicked
#    (cwd = /). Rewrite that reference to an @executable_path-relative one.
cp "$DYLIB" "$FRAMEWORKS/libace_container_scope.dylib"
install_name_tool -change \
  "arkui/ace_engine_cross/libace_container_scope.dylib" \
  "@executable_path/../Frameworks/libace_container_scope.dylib" \
  "$MACOS_DIR/ace_macos"

# 3) resources go under Contents/Resources (the asset manager resolves them at
#    [NSBundle mainBundle].resourcePath + "/arkui-x", which for an .app is
#    Contents/Resources/arkui-x). Placing them at the bundle root would leave
#    "unsealed contents" that break code signing.
mkdir -p "$CONTENTS/Resources"
cp -R "$RES_SRC" "$CONTENTS/Resources/arkui-x"

# 4) Info.plist
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.arkui.x.$APP_NAME</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>ace_macos</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 5) ad-hoc sign, bottom-up. The exe was modified by install_name_tool, which
#    invalidates its linker signature, so it MUST be re-signed; sign the nested
#    dylib and exe first, then seal the whole bundle. A broken/partial signature is
#    what makes macOS distrust the app and prompt for a pile of privacy permissions.
#    --deep is deprecated; sign each item explicitly. (Real Developer-ID signing +
#    notarization is the remaining M9 step, blocked on a certificate.)
BUNDLE_ID="com.arkui.x.$APP_NAME"
codesign --force --sign - "$FRAMEWORKS/libace_container_scope.dylib"
codesign --force --sign - --identifier "$BUNDLE_ID" "$MACOS_DIR/ace_macos"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
echo "=> signature:"
codesign --verify --strict "$APP" && echo "   verify OK" || echo "   verify FAILED"
codesign -dv "$APP" 2>&1 | grep -iE "Identifier=" | head -1

echo "=> done: $APP"
du -sh "$APP"
