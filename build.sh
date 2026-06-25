#!/bin/bash
set -e
cd "$(dirname "$0")"
echo "Building OpenLiveWalls..."
swift build -c release
echo "Creating app bundle..."
rm -rf OpenLiveWalls.app
mkdir -p OpenLiveWalls.app/Contents/MacOS OpenLiveWalls.app/Contents/Resources
cp .build/release/OpenLiveWalls OpenLiveWalls.app/Contents/MacOS/
cp Bundle/Info.plist OpenLiveWalls.app/Contents/
cp Bundle/AppIcon.icns OpenLiveWalls.app/Contents/Resources/
echo "APPL????" > OpenLiveWalls.app/Contents/PkgInfo
# Ad-hoc sign so the app isn't rejected as "damaged" on other Macs
# (No hardened runtime, no dev cert — matches how LiveWallpaperMacOS ships)
codesign --force --deep -s - OpenLiveWalls.app
echo "Done: OpenLiveWalls.app"
echo "Run: open OpenLiveWalls.app"
