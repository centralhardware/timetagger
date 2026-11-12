#!/bin/sh
# Builds TimeTaggerBar.app (a menu-bar-only app) into ./build.
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/TimeTaggerBar
APP=build/TimeTaggerBar.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"

# App icon: every size macOS asks for, from the 1024 px AppIcon.png.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TimeTaggerBar</string>
  <key>CFBundleIdentifier</key><string>app.timetagger.bar</string>
  <key>CFBundleExecutable</key><string>TimeTaggerBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.5.5</string>
  <key>CFBundleVersion</key><string>0.5.5</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Sign with the same certificate every release when CI provides one. The keychain trusts the
# app by its signature: an ad-hoc signature changes with every build, so macOS would ask for
# keychain access again after each update, and the app sits frozen behind that prompt.
if [ -n "$MACOS_CERT_P12" ]; then
  KC="$PWD/build/signing.keychain-db"
  security delete-keychain "$KC" 2>/dev/null || true
  security create-keychain -p ci "$KC"
  security set-keychain-settings "$KC"
  security unlock-keychain -p ci "$KC"
  echo "$MACOS_CERT_P12" | base64 --decode > build/cert.p12
  security import build/cert.p12 -k "$KC" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign
  rm build/cert.p12
  security set-key-partition-list -S apple-tool:,apple: -s -k ci "$KC" >/dev/null
  # codesign only looks in the search list. The cert is self-signed (not trusted), so name it by hash.
  OLD_KCS=$(security list-keychains -d user | tr -d '"')
  security list-keychains -d user -s "$KC" $OLD_KCS
  HASH=$(security find-certificate -c "TimeTaggerBar Signing" -Z "$KC" | awk '/SHA-1/ {print $NF}')
  codesign --force --keychain "$KC" --sign "$HASH" "$APP"
  security list-keychains -d user -s $OLD_KCS
  security delete-keychain "$KC"
else
  codesign --force --sign - "$APP"
fi

# Standard drag-to-Applications installer window.
rm -rf build/TimeTaggerBar.dmg build/dmg && mkdir build/dmg && cp -R "$APP" build/dmg/
create-dmg \
  --volname TimeTaggerBar \
  --window-size 600 380 \
  --icon-size 112 \
  --icon TimeTaggerBar.app 160 170 \
  --app-drop-link 440 170 \
  --hide-extension TimeTaggerBar.app \
  --no-internet-enable \
  build/TimeTaggerBar.dmg build/dmg
echo "Built build/TimeTaggerBar.dmg"
