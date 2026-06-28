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
RES_SRC="$OUT_DIR/arkui/ace_engine/arkui-x"

APP="$DEST_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"

[ -f "$EXE" ] || { echo "missing exe: $EXE"; exit 1; }
[ -d "$RES_SRC" ] || { echo "missing resources: $RES_SRC"; exit 1; }

echo "=> building $APP"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS"

# 1) executable
cp "$EXE" "$MACOS_DIR/ace_macos"

# 2) auto-collect dylib dependencies into Contents/Frameworks.
#    The build links several dylibs with cwd-relative install names
#    (e.g. arkui/ace_engine_cross/libace_container_scope.dylib,
#    thirdparty/libxml2/libxml2.dylib). They resolve when run from out/arkui-x
#    but break once double-clicked (a .app launches with cwd=/, and dyld loads
#    libraries BEFORE our constructor can chdir). Rather than hard-code each one,
#    walk otool -L transitively: copy every cwd-relative dep (path not starting
#    with / or @) into Frameworks and rewrite the reference to @executable_path.
collect_deps() {
  # $1 = mach-o binary whose cwd-relative deps should be vendored + rewritten
  local binary="$1" dep base src
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    base="$(basename "$dep")"
    if [ ! -f "$FRAMEWORKS/$base" ]; then
      # locate the source dylib: prefer the verbatim relative path under the out
      # dir, else fall back to a basename search (covers unstripped_dylib/ etc.)
      src="$OUT_DIR/$dep"
      [ -f "$src" ] || src="$(find "$OUT_DIR" -name "$base" -type f 2>/dev/null | head -1)"
      if [ -n "$src" ] && [ -f "$src" ]; then
        cp "$src" "$FRAMEWORKS/$base"; chmod u+w "$FRAMEWORKS/$base"
        collect_deps "$FRAMEWORKS/$base"   # recurse: this dylib's own deps
      else
        echo "  ⚠ dependency not found, skipping: $dep"
      fi
    fi
    install_name_tool -change "$dep" "@executable_path/../Frameworks/$base" "$binary" 2>/dev/null || true
  done < <(otool -L "$binary" | awk 'NR>1{print $1}' | grep -vE '^/|^@')
}
collect_deps "$MACOS_DIR/ace_macos"
echo "=> vendored $(ls -1 "$FRAMEWORKS" 2>/dev/null | wc -l | tr -d ' ') dylib(s) into Frameworks"

# 3) resources go under Contents/Resources (the asset manager resolves them at
#    [NSBundle mainBundle].resourcePath + "/arkui-x", which for an .app is
#    Contents/Resources/arkui-x). Placing them at the bundle root would leave
#    "unsealed contents" that break code signing.
mkdir -p "$CONTENTS/Resources"
cp -R "$RES_SRC" "$CONTENTS/Resources/arkui-x"

# 3b) ICU data. The build links ICU's stubdata (empty), so i18n's InitIcuData
#     points ICU at ./icu/ at runtime (cwd = resource root after the constructor
#     chdir). Ship the real icudt<ver>l.dat there so @ohos.intl DateTimeFormat/
#     NumberFormat have locale data; without it every .format() returns empty.
ICU_DAT="$(find "$OUT_DIR" -name 'icudt*l.dat' -type f 2>/dev/null | head -1)"
if [ -n "$ICU_DAT" ]; then
  mkdir -p "$CONTENTS/Resources/icu"
  cp "$ICU_DAT" "$CONTENTS/Resources/icu/"
  echo "=> bundled ICU data: $(basename "$ICU_DAT")"
else
  echo "  ⚠ ICU data (icudt*l.dat) not found under $OUT_DIR — intl formatting will be empty"
fi

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
for dylib in "$FRAMEWORKS"/*.dylib; do
  [ -f "$dylib" ] && codesign --force --sign - "$dylib"
done
codesign --force --sign - --identifier "$BUNDLE_ID" "$MACOS_DIR/ace_macos"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
echo "=> signature:"
codesign --verify --strict "$APP" && echo "   verify OK" || echo "   verify FAILED"
codesign -dv "$APP" 2>&1 | grep -iE "Identifier=" | head -1

echo "=> done: $APP"
du -sh "$APP"
