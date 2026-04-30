#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="06GOLP"
EXECUTABLE_NAME="GOLP"
BUILD_DIR="$ROOT_DIR/Build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

CONFIG="${1:-debug}"

echo "Building Swift executable ($CONFIG)..."
cd "$ROOT_DIR"
swift build --configuration "$CONFIG"

echo "Preparing app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/.build/$CONFIG/$EXECUTABLE_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/App/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/App/menubarIcon.png" "$RESOURCES_DIR/menubarIcon.png"
cp "$ROOT_DIR/App/menubarIcon@2x.png" "$RESOURCES_DIR/menubarIcon@2x.png"

echo "App bundle created at:"
echo "  $APP_DIR"
