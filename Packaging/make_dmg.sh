#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# make_dmg.sh  —  06GOLP DMG 패키저
# ─────────────────────────────────────────────────────────
set -e

APP_NAME="06GOLP"
EXECUTABLE_NAME="GOLP"
VOL_NAME="06GOLP"
VERSION="1.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_BASENAME="${1:-${APP_NAME}-${VERSION}}"
OUTPUT_BASENAME="${OUTPUT_BASENAME%.dmg}"
OUTPUT="${ROOT_DIR}/Releases/${VERSION}/${OUTPUT_BASENAME}.dmg"
BG_IMG="${ROOT_DIR}/06golp.png"

if [ ! -f "$BG_IMG" ]; then
  echo "Error: 배경 이미지가 없습니다: $BG_IMG"; exit 1
fi

echo "▶ 1/4  Release 빌드 중…"
cd "$ROOT_DIR"
swift build --configuration release

TEMP_DIR=$(mktemp -d)
APP_SRC_DIR="$TEMP_DIR/app_stage"
APP_BUNDLE_NAME="$APP_NAME.app"
APP_BUNDLE="$APP_SRC_DIR/$APP_BUNDLE_NAME"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/App/Info.plist"           "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/App/AppIcon.icns"         "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/App/menubarIcon.png"      "$RESOURCES_DIR/menubarIcon.png"
cp "$ROOT_DIR/App/menubarIcon@2x.png"   "$RESOURCES_DIR/menubarIcon@2x.png"

echo "    ✓ $APP_BUNDLE"

codesign --force --sign - --deep --timestamp=none "$APP_BUNDLE"

echo "▶ 2/4  스테이징 구성 중…"
DMG_TEMP="${TEMP_DIR}/dmg_temp"
mkdir -p "${DMG_TEMP}/.background"

cp -R "${APP_BUNDLE}"  "${DMG_TEMP}/${APP_BUNDLE_NAME}"
ln -s /Applications    "${DMG_TEMP}/Applications"
cp "${BG_IMG}"         "${DMG_TEMP}/.background/background.png"

echo "▶ 3/4  DMG 생성 및 Finder 창 설정 중…"

if [ -d "/Volumes/${VOL_NAME}" ]; then
  hdiutil detach "/Volumes/${VOL_NAME}" -force >/dev/null 2>&1 || true
fi

hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${DMG_TEMP}" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "${TEMP_DIR}/temp.dmg" >/dev/null

hdiutil attach "${TEMP_DIR}/temp.dmg" -readwrite -noverify -noautoopen >/dev/null
sleep 2

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "${VOL_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 740, 580}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 80
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "${APP_BUNDLE_NAME}" of container window to {195, 240}
    set position of item "Applications"       of container window to {445, 240}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync; sleep 2

for attempt in 1 2 3; do
  hdiutil detach "/Volumes/${VOL_NAME}" >/dev/null 2>&1 && break || sleep 1
done
hdiutil detach "/Volumes/${VOL_NAME}" -force >/dev/null 2>&1 || true

for i in 1 2 3 4 5; do
  [ ! -d "/Volumes/${VOL_NAME}" ] && break; sleep 1
done

echo "▶ 4/4  압축 DMG 변환 중…"
mkdir -p "$(dirname "${OUTPUT}")"
rm -f "${OUTPUT}"
hdiutil convert "${TEMP_DIR}/temp.dmg" -format UDZO -o "${OUTPUT}" >/dev/null
rm -rf "${TEMP_DIR}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ ${OUTPUT}"
echo "  크기: $(du -sh "${OUTPUT}" | cut -f1)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
