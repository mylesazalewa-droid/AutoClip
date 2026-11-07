#!/bin/bash
# Finder integration: "Make Clips with AutoClip" in the right-click menu, and AutoClip in
# Open With for video and audio (which also lets files be dropped on the Dock icon).
set -e
PLIST="$1/Contents/Info.plist"
plutil -replace NSServices -json '[{"NSMenuItem":{"default":"Make Clips with AutoClip"},"NSMessage":"makeClips","NSPortName":"AutoClip","NSRequiredContext":{},"NSSendFileTypes":["public.movie","public.audio"]}]' "$PLIST"
plutil -replace CFBundleDocumentTypes -json '[{"CFBundleTypeName":"Video or audio","CFBundleTypeRole":"Viewer","LSHandlerRank":"Alternate","LSItemContentTypes":["public.movie","public.audio"]}]' "$PLIST"
