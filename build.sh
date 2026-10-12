#!/bin/zsh
# Builds DynamicNotch.app into ./build. Pass --install to copy it to
# /Applications and (re)launch it.
set -euo pipefail
cd "${0:A:h}"

APP=build/DynamicNotch.app
CONFIG=release

swift build -c $CONFIG --arch arm64
BIN=$(swift build -c $CONFIG --arch arm64 --show-bin-path)

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/DynamicNotch $BIN/notch $APP/Contents/MacOS/
cp hooks/notch.zsh $APP/Contents/Resources/

# The Now Playing helper runs inside /usr/bin/perl (arm64e), so build it for both.
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch arm64e -mmacosx-version-min=14.0 \
  -framework Foundation Helper/MediaRemoteHelper.m -o $APP/Contents/Resources/MediaRemoteHelper.dylib

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.amirali.dynamicnotch</string>
  <key>CFBundleName</key><string>Dynamic Notch</string>
  <key>CFBundleDisplayName</key><string>Dynamic Notch</string>
  <key>CFBundleExecutable</key><string>DynamicNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Dynamic Notch listens to the music that's playing so the equalizer moves with it. Audio is analyzed on your Mac and never recorded or stored.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Dynamic Notch shows when Bluetooth devices like AirPods connect.</string>
</dict>
</plist>
PLIST

# Sign with a stable local certificate so privacy permissions (Full Disk
# Access, System Audio Recording…) survive rebuilds; ad-hoc signatures change
# every build and macOS would forget the grants. Create it once with
# scripts/make-signing-cert.sh.
IDENTITY=$(security find-certificate -c "Dynamic Notch Local Signing" -Z ~/Library/Keychains/login.keychain-db 2>/dev/null \
  | awk '/SHA-1 hash:/ {print $3}')
if [[ -z $IDENTITY ]]; then
  echo "warning: no 'Dynamic Notch Local Signing' certificate; signing ad-hoc (permissions reset each build)." >&2
  echo "         run scripts/make-signing-cert.sh once to fix that." >&2
  IDENTITY=-
fi
codesign --force --sign $IDENTITY $APP/Contents/Resources/MediaRemoteHelper.dylib
codesign --force --sign $IDENTITY --identifier com.amirali.dynamicnotch.cli $APP/Contents/MacOS/notch
codesign --force --sign $IDENTITY --identifier com.amirali.dynamicnotch $APP
echo "Built $APP"

if [[ ${1:-} == --install ]]; then
  pkill -x DynamicNotch 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/DynamicNotch.app
  cp -R $APP /Applications/
  open /Applications/DynamicNotch.app
  echo "Installed and launched /Applications/DynamicNotch.app"
fi
