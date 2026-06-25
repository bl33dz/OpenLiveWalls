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
echo "APPL????" > OpenLiveWalls.app/Contents/PkgInfo
echo "Done: OpenLiveWalls.app"
echo "Run: open OpenLiveWalls.app"
