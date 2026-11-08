#!/bin/bash
# Finder integration: "Make Clips with AutoClip" in the right-click menu, and AutoClip in
# Open With for video and audio (which also lets files be dropped on the Dock icon).
set -e
PLIST="$1/Contents/Info.plist"
plutil -replace NSServices -json '[{"NSMenuItem":{"default":"Make Clips with AutoClip"},"NSMessage":"makeClips","NSPortName":"AutoClip","NSRequiredContext":{},"NSSendFileTypes":["public.movie","public.audio"]}]' "$PLIST"
plutil -replace CFBundleDocumentTypes -json '[{"CFBundleTypeName":"Video or audio","CFBundleTypeRole":"Viewer","LSHandlerRank":"Alternate","LSItemContentTypes":["public.movie","public.audio"]}]' "$PLIST"
# The app icon under a name older versions never used, so macOS can't show a cached old icon
cp "$(dirname "$0")/Resources/AppIcon.icns" "$1/Contents/Resources/AutoClipIcon.icns"
rm -f "$1/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleIconFile -string "AutoClipIcon" "$PLIST"
