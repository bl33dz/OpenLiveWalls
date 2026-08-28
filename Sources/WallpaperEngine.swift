import AppKit
import AVFoundation
import AVKit

@MainActor
final class WallpaperEngine {
    private var wallpaperWindows: [NSScreen: NSWindow] = [:]

    // Players are per screen, not per URL. An AVPlayer renders into a single
    // AVPlayerLayer: attaching one player to several layers leaves every layer
    // but the last frozen on whatever frame it happened to hold.
    private var players: [NSScreen: AVQueuePlayer] = [:]
    private var loopers: [NSScreen: AVPlayerLooper] = [:]
    private var playerURLs: [NSScreen: URL] = [:]

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
    private var pausedScreens: Set<NSScreen> = []
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
                self?.applyWallpaper(url: url, force: true)
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
        applyWallpaper(url: url, force: false)
    }

    /// - Parameter force: rebuild even when the URL is unchanged, used when the
    ///   screen layout changes and displays may have come or gone.
    private func applyWallpaper(url: URL, force: Bool) {
        guard force || activeURL != url || wallpaperWindows.isEmpty else { return }
        activeURL = url

        for screen in NSScreen.screens {
            let player = player(for: url, on: screen)
            showWallpaper(on: screen, player: player)
        }

        removeDisconnectedScreens()

        // A wallpaper applied while a desktop is already hidden must not start
        // decoding there, so state is recomputed rather than assumed.
        pausedScreens = []
        for screen in players.keys where shouldPause(on: screen) {
            pausedScreens.insert(screen)
        }
        applyPlaybackState()
    }

    /// Starts or stops decoding per screen to match policy and screen state.
    private func updatePlaybackState() {
        guard activeURL != nil, !players.isEmpty else { return }

        var next: Set<NSScreen> = []
        for screen in players.keys where shouldPause(on: screen) {
            next.insert(screen)
        }

        if ProcessInfo.processInfo.environment["OWL_DEBUG"] != nil {
            let states = players.keys.map { screen in
                let size = screen.frame.size
                return "\(Int(size.width))x\(Int(size.height))="
                    + (next.contains(screen) ? "paused" : "playing")
            }.sorted().joined(separator: " ")
            let msg = "[owl] policy=\(policy.rawValue) screens=\(players.count) \(states)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        guard next != pausedScreens else { return }
        pausedScreens = next
        applyPlaybackState()
    }

    /// Drives each screen's player to the state that screen should be in.
    private func applyPlaybackState() {
        for (screen, player) in players {
            if pausedScreens.contains(screen) {
                player.pause()
            } else {
                player.play()
            }
        }
    }

    private func shouldPause(on screen: NSScreen) -> Bool {
        if screensAsleep { return true }

        switch policy {
        case .always:
            return false
        case .fullscreen:
            return ScreenState.isFullscreen(screen)
        case .covered:
            // Fullscreen is normally a subset of "covered", but a fullscreen
            // space hides the menu bar and changes visibleFrame, so test both.
            return ScreenState.isHidden(screen) || ScreenState.isFullscreen(screen)
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

        for screen in Array(players.keys) {
            teardownPlayer(for: screen)
        }

        for window in wallpaperWindows.values {
            window.orderOut(nil)
        }
        wallpaperWindows.removeAll()
        pausedScreens.removeAll()
    }

    private func player(for url: URL, on screen: NSScreen) -> AVQueuePlayer {
        if let existing = players[screen], playerURLs[screen] == url {
            return existing
        }

        teardownPlayer(for: screen)

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 0

        let player = AVQueuePlayer()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false

        players[screen] = player
        loopers[screen] = AVPlayerLooper(player: player, templateItem: item)
        playerURLs[screen] = url

        return player
    }

    private func teardownPlayer(for screen: NSScreen) {
        loopers[screen]?.disableLooping()
        players[screen]?.pause()
        players[screen]?.removeAllItems()

        loopers.removeValue(forKey: screen)
        players.removeValue(forKey: screen)
        playerURLs.removeValue(forKey: screen)
        pausedScreens.remove(screen)
    }

    private func showWallpaper(on screen: NSScreen, player: AVQueuePlayer) {
        // Window content coordinates start at zero regardless of where the
        // screen sits in the global layout, so a screen frame with a non-zero
        // origin must not be used to position content inside the window.
        let contentBounds = CGRect(origin: .zero, size: screen.frame.size)

        if let window = wallpaperWindows[screen] {
            window.setFrame(screen.frame, display: true)
            for layer in window.contentView?.layer?.sublayers ?? [] {
                guard let playerLayer = layer as? AVPlayerLayer else { continue }
                playerLayer.player = player
                playerLayer.frame = contentBounds
            }
            window.contentView?.frame = contentBounds
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
        layer.frame = contentBounds
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let host = NSView(frame: contentBounds)
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

        for screen in Array(players.keys) where !current.contains(screen) {
            teardownPlayer(for: screen)
        }
    }
}
