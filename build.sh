#!/bin/sh
# Builds Aeris Keeper.app (menu bar only, no Dock icon) next to this script.
set -e
cd "$(dirname "$0")"
APP="Aeris Keeper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R Fonts "$APP/Contents/Resources/"
# App icon: every size macOS asks for, from the 1024px master (regenerate it with Icon/make-icon.swift).
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Icon/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Icon/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Universal binary (Apple Silicon + Intel), runs on macOS 13 and later.
BUILD=$(mktemp -d)
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos13 Keeper.swift -o "$BUILD/$arch"
done
lipo -create "$BUILD/arm64" "$BUILD/x86_64" -output "$APP/Contents/MacOS/AerisKeeper"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.aeris.keeper</string>
  <key>CFBundleName</key><string>Aeris Keeper</string>
  <key>CFBundleExecutable</key><string>AerisKeeper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
