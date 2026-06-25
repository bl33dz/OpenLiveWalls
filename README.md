# OpenLiveWalls

OpenLiveWalls is a macOS menu bar app for using local video files as live desktop wallpapers and converting videos for macOS live lock screen wallpaper support.

## Tested Platform

I have only tested this on macOS 26.

The package and bundle metadata currently declare macOS 15 as the minimum target, but other macOS versions are not verified yet.

## Current Scope

For now, focus on `.mp4` and `.mov` videos as source files.

The import flow accepts MPEG-4 and QuickTime movies, converts them with `ffmpeg`, patches the required QuickTime atoms, and saves the converted wallpaper into the app's local wallpaper folder.

## Requirements

- macOS 26 for the tested setup
- Swift 6 toolchain
- `ffmpeg` with `libx265` support for import and conversion

The app looks for `ffmpeg` in:

- `/opt/homebrew/bin/ffmpeg`
- `/usr/local/bin/ffmpeg`
- `/usr/bin/ffmpeg`
- any `ffmpeg` available in `PATH`

On Homebrew, install it with:

```sh
brew install ffmpeg
```

## Build

Build the Swift package:

```sh
swift build
```

Build a release app bundle:

```sh
./build.sh
```

The app bundle is generated at:

```text
OpenLiveWalls.app
```

Generated build output and the app bundle are intentionally ignored by git.

## Local Wallpapers

The app reads local wallpapers from a `local/` folder next to the built app bundle. If the folder does not exist, the app creates it.

When importing a video, the app writes a converted `*_lock.mov` file into that `local/` folder and selects it automatically.

Local media files are ignored by git so large videos do not end up in repository history.

## Notes

- OpenLiveWalls writes into the user's `Application Support/com.apple.wallpaper` files.
- Lock screen conversion uses HEVC and QuickTime atom patching for macOS wallpaper compatibility.
- This project does not currently declare a license.
