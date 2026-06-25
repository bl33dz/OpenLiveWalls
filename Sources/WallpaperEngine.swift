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

    private var screenObserver: NSObjectProtocol?

    nonisolated init() {}

    func start() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let url = self?.activeURL else { return }
                self?.applyWallpaper(url: url)
            }
        }
    }

    func applyWallpaper(url: URL) {
        guard activeURL != url || wallpaperWindows.isEmpty else { return }
        activeURL = url

        let player = player(for: url)

        for screen in NSScreen.screens {
            showWallpaper(on: screen, player: player)
        }

        removeDisconnectedScreens()
        player.play()
    }

    func cleanup() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }

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
