#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building AutoClip..."
swift build -c release

APP=".build/AutoClip.app"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/AutoClip "$APP/Contents/MacOS/AutoClip"

# The built-in sample sermon and the help guide live outside the Swift build
mkdir -p "$APP/Contents/Resources"
cp Sample/sample-sermon.mp4 Sample/sample-sermon.json ../website/help.html "$APP/Contents/Resources/"

# Practice mode records with the camera and microphone (added to existing bundles too)
set_usage() {
    /usr/libexec/PlistBuddy -c "Set :$1 $2" "$APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$APP/Contents/Info.plist" 2>/dev/null || true
}

if [ ! -f "$APP/Contents/Info.plist" ]; then
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AutoClip</string>
    <key>CFBundleIdentifier</key>
    <string>com.autoclip.app.dev</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AutoClip</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSQuitAlwaysKeepsWindows</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>AutoClip records your practice runs so it can assess your delivery.</string>
    <key>NSCameraUsageDescription</key>
    <string>AutoClip records your practice runs on camera so it can assess your stage presence.</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
</dict>
</plist>
PLIST
fi
./plist-extras.sh "$APP"
set_usage NSMicrophoneUsageDescription "AutoClip records your practice runs so it can assess your delivery."
set_usage NSCameraUsageDescription "AutoClip records your practice runs on camera so it can assess your stage presence."

echo "Relaunching..."
pkill -f "AutoClip.app" 2>/dev/null || true
sleep 0.5
open "$APP"
echo "Done."
