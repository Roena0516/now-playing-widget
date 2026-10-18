#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Pear Now Playing.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache
# --universal: Apple Silicon + Intel in one binary (for releases); otherwise this Mac's architecture only
# --dmg: also make build/PearNowPlaying-macOS.dmg (the app next to an Applications link, for drag-and-drop install)
ARCHS=$(uname -m)
DMG=0
for ARG in "$@"; do
  case "$ARG" in
    --universal) ARCHS="arm64 x86_64" ;;
    --dmg) DMG=1 ;;
    *) echo "unknown option: $ARG" >&2; exit 1 ;;
  esac
done
SLICES=()
for ARCH in $ARCHS; do
  xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx13.0" -module-cache-path "$PWD/build/module-cache" Sources/*.swift -o "build/PearNowPlaying-$ARCH" -framework AppKit -framework CoreText -framework QuartzCore -framework Carbon
  SLICES+=("build/PearNowPlaying-$ARCH")
done
xcrun lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/PearNowPlaying"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Pear Now Playing</string>
<key>CFBundleDisplayName</key><string>Pear Now Playing</string>
<key>CFBundleIdentifier</key><string>io.github.pdh0128.pear-now-playing.macos</string>
<key>CFBundleExecutable</key><string>PearNowPlaying</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1.5.1</string>
<key>CFBundleShortVersionString</key><string>1.5.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
cp ../assets/fonts/PretendardJP-Regular.ttf ../assets/fonts/PretendardJP-Medium.ttf ../assets/fonts/PretendardJP-OFL.txt "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
if [ "$DMG" = 1 ]; then
  STAGE="$PWD/build/dmg"
  rm -rf "$STAGE" build/PearNowPlaying-macOS.dmg
  mkdir -p "$STAGE"
  ditto --norsrc "$APP" "$STAGE/Pear Now Playing.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Pear Now Playing" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/PearNowPlaying-macOS.dmg
  rm -rf "$STAGE"
  printf 'Built: %s\n' "$PWD/build/PearNowPlaying-macOS.dmg"
fi
