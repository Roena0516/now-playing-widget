#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Now Playing Widget.app"
rm -rf "$PWD/build/Pear Now Playing.app"   # the app's old name (up to 1.9.4)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" build/module-cache
# --universal: Apple Silicon + Intel in one binary (for releases); otherwise this Mac's architecture only
# --dmg: also make build/NowPlayingWidget-macOS-<version>.dmg (styled window: the app next to an Applications link, see dmg-settings.py).
#        Uses dmgbuild, installed once into build/dmg-venv.
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
HELPERS=()
for ARCH in $ARCHS; do
  # the now-playing reader that /usr/bin/perl loads for the browser source (Helper/NowPlaying.m)
  xcrun clang -arch "$ARCH" -mmacosx-version-min=13.0 -dynamiclib -fobjc-arc -O2 -framework Foundation Helper/NowPlaying.m -o "build/libnowplaying-$ARCH.dylib"
  HELPERS+=("build/libnowplaying-$ARCH.dylib")
  xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx13.0" -module-cache-path "$PWD/build/module-cache" Sources/*.swift -o "build/NowPlayingWidget-$ARCH" -framework AppKit -framework CoreText -framework QuartzCore -framework Carbon
  SLICES+=("build/NowPlayingWidget-$ARCH")
done
xcrun lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/NowPlayingWidget"
xcrun lipo -create "${HELPERS[@]}" -output "$APP/Contents/Frameworks/libnowplaying.dylib"
# the version lives in one place: appVersion in Sources/Models.swift
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/Models.swift)
[ -n "$VERSION" ] || { echo "appVersion not found in Sources/Models.swift" >&2; exit 1; }
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Now Playing Widget</string>
<key>CFBundleDisplayName</key><string>Now Playing Widget</string>
<key>CFBundleIdentifier</key><string>io.github.pdh0128.pear-now-playing.macos</string>
<key>CFBundleExecutable</key><string>NowPlayingWidget</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>브라우저에서 재생 중인 YouTube Music 탭의 주소를 읽어서 곡을 알아냅니다. 다른 탭의 주소는 읽지 않습니다.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
cp ../assets/fonts/PretendardJP-Regular.ttf ../assets/fonts/PretendardJP-Medium.ttf ../assets/fonts/PretendardJP-OFL.txt Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP/Contents/Frameworks/libnowplaying.dylib"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
if [ "$DMG" = 1 ]; then
  if [ ! -x build/dmg-venv/bin/dmgbuild ]; then
    python3 -m venv build/dmg-venv
    build/dmg-venv/bin/pip install --quiet --disable-pip-version-check "dmgbuild==1.6.7" "ds-store==1.3.3" "mac-alias==2.2.3"
  fi
  # the version is in the file name so releases don't hand out same-named files
  DMG_FILE="build/NowPlayingWidget-macOS-$VERSION.dmg"
  rm -f build/NowPlayingWidget-macOS*.dmg build/PearNowPlaying-macOS*.dmg
  build/dmg-venv/bin/dmgbuild -s dmg-settings.py -D app="$APP" -D resources="$PWD/Resources" "Now Playing Widget" "$DMG_FILE" > /dev/null
  printf 'Built: %s\n' "$PWD/$DMG_FILE"
fi
