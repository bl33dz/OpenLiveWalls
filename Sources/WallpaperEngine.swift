import AppKit
import AVFoundation
import AVKit

@MainActor
final class WallpaperEngine {
    private var wallpaperWindows: [NSScreen: NSWindow] = [:]
    private var players: [URL: AVQueuePlayer] = [:]
    private var loopers: [URL: AVPlayerLooper] = [:]
    private var activeURL: URL?
    private let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow)) + 1

    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    /// Re-check interval for the state poll. Occlusion and space notifications
    /// drive the common transitions; this only backstops the cases AppKit does
    /// not announce, most importantly a window created while already covered,
    /// which never receives a change notification.
    private let pollInterval: TimeInterval = 3

    private var policy: PlaybackPolicy = PersistenceManager.shared.playbackPolicy
    private var isPaused = false
    private var screensAsleep = false

    nonisolated init() {}

    func start() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let url = self?.activeURL else { return }
                self?.applyWallpaper(url: url)
            }
        })

        // Covered/uncovered transitions for our own wallpaper windows.
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePlaybackState() }
        })

        let workspace = NSWorkspace.shared.notificationCenter

        // Entering or leaving a fullscreen space is a space switch.
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePlaybackState() }
        })

        // Nothing is visible while the displays are off.
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screensAsleep = true
                self?.updatePlaybackState()
            }
        })

        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screensAsleep = false
                self?.updatePlaybackState()
            }
        })

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePlaybackState() }
        }
    }

    /// Switches policy and applies it immediately.
    func setPolicy(_ newPolicy: PlaybackPolicy) {
        policy = newPolicy
        PersistenceManager.shared.playbackPolicy = newPolicy
        updatePlaybackState()
    }

    var currentPolicy: PlaybackPolicy { policy }

    func applyWallpaper(url: URL) {
        guard activeURL != url || wallpaperWindows.isEmpty else { return }
        activeURL = url

        let player = player(for: url)

        for screen in NSScreen.screens {
            showWallpaper(on: screen, player: player)
        }

        removeDisconnectedScreens()

        // A wallpaper applied while the desktop is already hidden must not
        // start decoding, so the state is recomputed rather than assumed.
        isPaused = shouldPauseNow()
        applyPlaybackState()
    }

    /// Starts or stops decoding to match the current policy and screen state.
    private func updatePlaybackState() {
        guard let activeURL, players[activeURL] != nil else { return }

        let shouldPause = shouldPauseNow()

        if ProcessInfo.processInfo.environment["OWL_DEBUG"] != nil {
            let msg = "[owl] policy=\(policy.rawValue) windows=\(wallpaperWindows.count) "
                + "hidden=\(ScreenState.isDesktopHidden()) fullscreen=\(ScreenState.isAnyAppFullscreen()) "
                + "shouldPause=\(shouldPause) isPaused=\(isPaused)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        guard shouldPause != isPaused else { return }
        isPaused = shouldPause
        applyPlaybackState()
    }

    /// Drives every cached player to the state it should be in.
    ///
    /// Only the wallpaper currently on screen may decode. Players kept from
    /// earlier selections are no longer attached to any layer, so leaving one
    /// running would decode video that cannot be seen.
    private func applyPlaybackState() {
        for (url, player) in players {
            if url == activeURL, !isPaused {
                player.play()
            } else {
                player.pause()
            }
        }
    }

    private func shouldPauseNow() -> Bool {
        if screensAsleep { return true }

        switch policy {
        case .always:
            return false
        case .fullscreen:
            return ScreenState.isAnyAppFullscreen()
        case .covered:
            // Fullscreen is normally a subset of "covered", but a fullscreen
            // space hides the menu bar and changes `visibleFrame`, so test both.
            return ScreenState.isDesktopHidden() || ScreenState.isAnyAppFullscreen()
        }
    }

    func cleanup() {
        pollTimer?.invalidate()
        pollTimer = nil

        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for looper in loopers.values {
            looper.disableLooping()
        }

        for player in players.values {
            player.pause()
            player.removeAllItems()
        }

        loopers.removeAll()
        players.removeAll()

        for window in wallpaperWindows.values {
            window.orderOut(nil)
        }
        wallpaperWindows.removeAll()
    }

    private func player(for url: URL) -> AVQueuePlayer {
        if let existing = players[url] {
            return existing
        }

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 0

        let player = AVQueuePlayer()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false

        players[url] = player
        loopers[url] = AVPlayerLooper(player: player, templateItem: item)

        return player
    }

    private func showWallpaper(on screen: NSScreen, player: AVQueuePlayer) {
        if let window = wallpaperWindows[screen] {
            for layer in window.contentView?.layer?.sublayers ?? [] {
                guard let playerLayer = layer as? AVPlayerLayer else { continue }
                playerLayer.player = player
            }
            window.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .init(rawValue: desktopLevel)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear

        let layer = AVPlayerLayer(player: player)
        layer.frame = screen.frame
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let host = NSView(frame: screen.frame)
        host.wantsLayer = true
        host.layer?.addSublayer(layer)

        window.contentView = host
        window.orderFrontRegardless()
        wallpaperWindows[screen] = window
    }

    private func removeDisconnectedScreens() {
        let current = Set(NSScreen.screens)

        for (screen, window) in wallpaperWindows where !current.contains(screen) {
            window.orderOut(nil)
            wallpaperWindows.removeValue(forKey: screen)
        }
    }
}
