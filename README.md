# OpenLiveWalls

OpenLiveWalls is a small macOS menu bar app for running local video files as live desktop wallpapers and preparing compatible lock screen wallpaper assets.

## Requirements

- macOS 15 or later
- Swift 6 toolchain
- `ffmpeg` for import and conversion workflows. The app looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, and `PATH`.

## Build

```sh
swift build
```

To create the app bundle:

```sh
./build.sh
```

The bundle is generated at `OpenLiveWalls.app/` and is intentionally ignored by git.

## Local Wallpapers

Put `.gif`, `.mp4`, or `.mov` files in a sibling `local/` folder next to the built app bundle. The app creates and scans that folder at runtime. Local media files are intentionally ignored so large wallpaper videos do not end up in repository history.

## Notes

- The app writes wallpaper data into the user's `Application Support/com.apple.wallpaper` files.
- Lock screen conversion uses HEVC and patches QuickTime atoms for macOS wallpaper compatibility.
- This project does not currently declare a license.
