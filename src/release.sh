#!/bin/bash
# Builds AutoClip for release: one app that runs on Apple Silicon and Intel Macs, packed in a DMG.
#
#   ./release.sh 3.39.0 312            build and package into ./release-out
#   ./release.sh 3.39.0 312 --publish  also publish it as a GitHub release (needs gh signed in)
#
# Signing: with no settings the app gets an ad-hoc signature, as before. Once there's an Apple
# Developer account, set these (e.g. in ~/.autoclip-signing, which this script reads) and the app is
# signed with Developer ID, notarized by Apple and stapled, so it opens with no warnings:
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="autoclip"   # made once with: xcrun notarytool store-credentials autoclip
#
# ARM_ONLY=1 skips the Intel half (quicker test builds).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?version, e.g. 3.39.0}"
BUILD="${2:?build number, e.g. 312}"
PUBLISH="${3:-}"
[ -f "$HOME/.autoclip-signing" ] && source "$HOME/.autoclip-signing"
SIGN_ID="${SIGN_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

OUT="release-out"
APP="$OUT/AutoClip.app"
STAGE="$OUT/stage"
mkdir -p "$OUT"

step() { printf '\n== %s\n' "$*"; }

step "Building for Apple Silicon"
swift build -c release
ARM=".build/arm64-apple-macosx/release"

if [ "${ARM_ONLY:-}" != "1" ]; then
    step "Building for Intel"
    swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86
    X86=".build-x86/x86_64-apple-macosx/release"
fi

step "Checking no test hooks are in the release"
hooks=$(strings "$ARM/AutoClip" | grep -c AC_TEST || true)
[ "$hooks" = "0" ] || { echo "Found $hooks AC_TEST hooks in the release binary. Stopping."; exit 1; }

step "Putting the app together"
rm -rf "$APP" "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
if [ -n "${X86:-}" ]; then
    lipo -create "$ARM/AutoClip" "$X86/AutoClip" -output "$APP/Contents/MacOS/AutoClip"
else
    cp "$ARM/AutoClip" "$APP/Contents/MacOS/AutoClip"
fi
lipo -archs "$APP/Contents/MacOS/AutoClip"
cp -R "$ARM/AutoClip_AutoClip.bundle" "$APP/Contents/Resources/"
cp Sample/sample-sermon.json Sample/sample-sermon.mp4 ../website/help.html "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
./plist-extras.sh "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

step "Signing"
if [ -n "$SIGN_ID" ]; then
    codesign --force --deep --options runtime --timestamp \
        --entitlements AutoClip.entitlements -s "$SIGN_ID" "$APP"
else
    echo "(no Developer ID set: ad-hoc signature)"
    codesign --force --deep -s - "$APP"
fi
codesign --verify --deep --strict "$APP"

step "Making the DMG"
DMG="$OUT/AutoClip-$VERSION.dmg"
rm -f "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AutoClip" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$SIGN_ID" ]; then
    codesign --force --timestamp -s "$SIGN_ID" "$DMG"
    if [ -n "$NOTARY_PROFILE" ]; then
        step "Notarizing with Apple (usually a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature -v "$DMG"
    fi
fi

cp "$DMG" "$OUT/AutoClip.dmg"
( cd "$OUT" && shasum -a 256 AutoClip.dmg > AutoClip.dmg.sha256 )

step "Checking the DMG opens and holds the right version"
MNT=$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}')
got=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MNT/AutoClip.app/Contents/Info.plist")
archs=$(lipo -archs "$MNT/AutoClip.app/Contents/MacOS/AutoClip")
codesign --verify --deep --strict "$MNT/AutoClip.app"
hdiutil detach "$MNT" -quiet
[ "$got" = "$VERSION" ] || { echo "DMG holds $got, not $VERSION"; exit 1; }
echo "OK: AutoClip $got ($archs) in $DMG"

if [ "$PUBLISH" = "--publish" ]; then
    step "Publishing the GitHub release"
    NOTES="${NOTES:-AutoClip $VERSION}"
    gh release create "v$VERSION" "$DMG" "$OUT/AutoClip.dmg" "$OUT/AutoClip.dmg.sha256" \
        --title "AutoClip $VERSION" --notes "$NOTES"
fi
