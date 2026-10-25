import AppKit
import AVFoundation
import AVKit

@MainActor
final class WallpaperEngine {
    // Everything per display is keyed by `DisplayID`, never by `NSScreen`.
    //
    // NSScreen compares equal by display ID, but each instance holds its own
    // snapshot of frame and visibleFrame, and AppKit hands out new instances
    // when the layout changes. A Swift dictionary keeps whichever equal key it
    // saw first, so an NSScreen-keyed table silently retains an instance whose
    // geometry describes a layout that no longer exists. Seen in practice: a
    // key captured while an external display held the Dock kept reporting no
    // Dock inset on the built-in for days, so the Dock's own strip read as
    // visible wallpaper and the covered policy never paused. Geometry is read
    // from `NSScreen.screens` at the moment it is needed instead.
    private var wallpaperWindows: [DisplayID: NSWindow] = [:]

    // Players are per display, not per URL. An AVPlayer renders into a single
    // AVPlayerLayer: attaching one player to several layers leaves every layer
    // but the last frozen on whatever frame it happened to hold.
    private var players: [DisplayID: AVQueuePlayer] = [:]
    private var loopers: [DisplayID: AVPlayerLooper] = [:]
    private var playerURLs: [DisplayID: URL] = [:]

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
    private var pausedDisplays: Set<DisplayID> = []
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

        let live = liveScreens()
        for (display, screen) in live {
            let player = player(for: url, on: display)
            showWallpaper(on: screen, display: display, player: player)
        }

        removeDisconnectedDisplays(keeping: Set(live.keys))

        // A wallpaper applied while a desktop is already hidden must not start
        // decoding there, so state is recomputed rather than assumed.
        pausedDisplays = displaysToPause(live)
        applyPlaybackState()
    }

    /// Starts or stops decoding per screen to match policy and screen state.
    private func updatePlaybackState() {
        guard activeURL != nil, !players.isEmpty else { return }

        let live = liveScreens()
        let next = displaysToPause(live)

        if ProcessInfo.processInfo.environment["OWL_DEBUG"] != nil {
            let states = players.keys.map { display in
                let shape = live[display].map { screen in
                    let visible = screen.visibleFrame
                    return "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
                        + " visible@y\(Int(visible.minY))h\(Int(visible.height))"
                } ?? "gone"
                return "display\(display)[\(shape)]=" + (next.contains(display) ? "paused" : "playing")
            }.sorted().joined(separator: " ")
            let msg = "[owl] policy=\(policy.rawValue) displays=\(players.count) \(states)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        guard next != pausedDisplays else { return }
        pausedDisplays = next
        applyPlaybackState()
    }

    /// The displays attached right now, each with the `NSScreen` instance
    /// AppKit currently vends for it - the only instance whose geometry can be
    /// trusted.
    private func liveScreens() -> [DisplayID: NSScreen] {
        var live: [DisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let display = screen.displayID { live[display] = screen }
        }
        return live
    }

    /// Displays whose player should be stopped. A player whose display is no
    /// longer attached is stopped too: it cannot be seen, and leaving it
    /// running until the next rebuild would decode for nothing.
    private func displaysToPause(_ live: [DisplayID: NSScreen]) -> Set<DisplayID> {
        Set(players.keys.filter { display in
            guard let screen = live[display] else { return true }
            return shouldPause(on: screen)
        })
    }

    /// Drives each screen's player to the state that screen should be in.
    private func applyPlaybackState() {
        for (display, player) in players {
            if pausedDisplays.contains(display) {
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

        for display in Array(players.keys) {
            teardownPlayer(for: display)
        }

        for window in wallpaperWindows.values {
            window.orderOut(nil)
        }
        wallpaperWindows.removeAll()
        pausedDisplays.removeAll()
    }

    private func player(for url: URL, on display: DisplayID) -> AVQueuePlayer {
        if let existing = players[display], playerURLs[display] == url {
            return existing
        }

        teardownPlayer(for: display)

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 0

        let player = AVQueuePlayer()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false

        players[display] = player
        loopers[display] = AVPlayerLooper(player: player, templateItem: item)
        playerURLs[display] = url

        return player
    }

    private func teardownPlayer(for display: DisplayID) {
        loopers[display]?.disableLooping()
        players[display]?.pause()
        players[display]?.removeAllItems()

        loopers.removeValue(forKey: display)
        players.removeValue(forKey: display)
        playerURLs.removeValue(forKey: display)
        pausedDisplays.remove(display)
    }

    /// - Parameter screen: must be the live instance for `display`; its frame
    ///   positions the window.
    private func showWallpaper(on screen: NSScreen, display: DisplayID, player: AVQueuePlayer) {
        // Window content coordinates start at zero regardless of where the
        // screen sits in the global layout, so a screen frame with a non-zero
        // origin must not be used to position content inside the window.
        let contentBounds = CGRect(origin: .zero, size: screen.frame.size)

        if let window = wallpaperWindows[display] {
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
        wallpaperWindows[display] = window
    }

    private func removeDisconnectedDisplays(keeping current: Set<DisplayID>) {
        for (display, window) in wallpaperWindows where !current.contains(display) {
            window.orderOut(nil)
            wallpaperWindows.removeValue(forKey: display)
        }

        for display in Array(players.keys) where !current.contains(display) {
            teardownPlayer(for: display)
        }
    }
}
