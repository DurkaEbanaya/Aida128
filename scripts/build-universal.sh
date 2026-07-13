#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0-rc.1}"
MARKETING_VERSION="${MARKETING_VERSION:-${VERSION%%-*}}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build-universal}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$ROOT/dist}"
X86_BUILD="$BUILD_ROOT/x86_64"
ARM_BUILD="$BUILD_ROOT/arm64"
APP="$OUTPUT_ROOT/Aida128.app"
PACKAGE_DIR="$OUTPUT_ROOT/Aida128-$VERSION-universal2"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION must be a semantic artifact version" >&2
  exit 64
fi
if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "MARKETING_VERSION must contain one to three numeric components" >&2
  exit 64
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "BUILD_NUMBER must be a positive integer" >&2
  exit 64
fi

rm -rf "$BUILD_ROOT" "$OUTPUT_ROOT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PACKAGE_DIR"

swift build --package-path "$ROOT" -c release \
  --triple x86_64-apple-macosx13.0 --scratch-path "$X86_BUILD"
swift build --package-path "$ROOT" -c release \
  --triple arm64-apple-macosx13.0 --scratch-path "$ARM_BUILD"

X86_PRODUCTS="$X86_BUILD/x86_64-apple-macosx/release"
ARM_PRODUCTS="$ARM_BUILD/arm64-apple-macosx/release"

lipo -create "$X86_PRODUCTS/aida128" "$ARM_PRODUCTS/aida128" \
  -output "$APP/Contents/MacOS/Aida128"
lipo -create "$X86_PRODUCTS/aida128-bench" "$ARM_PRODUCTS/aida128-bench" \
  -output "$PACKAGE_DIR/aida128-bench"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Aida128</string>
  <key>CFBundleExecutable</key><string>Aida128</string>
  <key>CFBundleIdentifier</key><string>dev.durkaebanaya.aida128</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Aida128</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$MARKETING_VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD_NUMBER" ]]

chmod +x "$APP/Contents/MacOS/Aida128" "$PACKAGE_DIR/aida128-bench"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/Aida128" -verify_arch x86_64 arm64
lipo "$PACKAGE_DIR/aida128-bench" -verify_arch x86_64 arm64

cp -R "$APP" "$PACKAGE_DIR/Aida128.app"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$PACKAGE_DIR/"

ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" \
  "$OUTPUT_ROOT/Aida128-$VERSION-universal2.zip"

(
  cd "$OUTPUT_ROOT"
  shasum -a 256 "Aida128-$VERSION-universal2.zip" > "Aida128-$VERSION-SHA256SUMS.txt"
  shasum -a 256 -c "Aida128-$VERSION-SHA256SUMS.txt"
)

echo "Built: $OUTPUT_ROOT/Aida128-$VERSION-universal2.zip"
lipo -info "$APP/Contents/MacOS/Aida128"
lipo -info "$PACKAGE_DIR/aida128-bench"
