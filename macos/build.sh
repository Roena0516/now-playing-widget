#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Pear Now Playing.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$PWD/build/module-cache" Sources/*.swift -o "$APP/Contents/MacOS/PearNowPlaying" -framework AppKit -framework CoreText -framework QuartzCore -framework Carbon
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Pear Now Playing</string>
<key>CFBundleDisplayName</key><string>Pear Now Playing</string>
<key>CFBundleIdentifier</key><string>io.github.pdh0128.pear-now-playing.macos</string>
<key>CFBundleExecutable</key><string>PearNowPlaying</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
cp ../assets/fonts/PretendardJP-Regular.ttf ../assets/fonts/PretendardJP-Medium.ttf ../assets/fonts/PretendardJP-OFL.txt "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
