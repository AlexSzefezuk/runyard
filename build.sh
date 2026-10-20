#!/bin/zsh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Runyard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp .build/release/Runyard "$APP/Contents/MacOS/Runyard"
cp .build/release/RunyardCLI "$APP/Contents/Helpers/runyard"
iconutil -c icns assets/icons/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp assets/icons/MenuBarIcon.pdf "$APP/Contents/Resources/MenuBarIcon.pdf"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Runyard</string>
    <key>CFBundleIdentifier</key><string>local.runyard</string>
    <key>CFBundleExecutable</key><string>Runyard</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/runyard"
codesign --force --sign - "$APP"
if [[ "$1" == "--install" ]]; then
  pkill -x Runyard || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/Runyard.app
  cp -R "$APP" ~/Applications/
  mkdir -p ~/.local/bin
  ln -sf ~/Applications/Runyard.app/Contents/Helpers/runyard ~/.local/bin/runyard
  open ~/Applications/Runyard.app
  echo "Instalado em ~/Applications/Runyard.app"
fi
