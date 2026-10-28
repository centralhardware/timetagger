#!/bin/sh
# Builds TimeTaggerBar.app (a menu-bar-only app) into ./build.
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/TimeTaggerBar
APP=build/TimeTaggerBar.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TimeTaggerBar</string>
  <key>CFBundleIdentifier</key><string>app.timetagger.bar</string>
  <key>CFBundleExecutable</key><string>TimeTaggerBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
(cd build && ditto -c -k --keepParent TimeTaggerBar.app TimeTaggerBar.zip)
rm -rf build/dmg && mkdir build/dmg && cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -volname TimeTaggerBar -srcfolder build/dmg -ov -format UDZO build/TimeTaggerBar.dmg
echo "Built $APP and build/TimeTaggerBar.dmg"
