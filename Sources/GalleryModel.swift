import AppKit
import AVFoundation
import Observation

/// Facts about a wallpaper shown under the preview.
struct WallpaperDetails: Sendable {
    let pixelSize: CGSize
    let duration: Double
    let frameRate: Float
    let fileSize: Int64
}

/// Geometry of the display the preview imitates.
struct ScreenShape: Equatable {
    /// Width over height.
    var aspect: CGFloat
    /// Menu bar height as a fraction of screen height; zero when it auto-hides.
    var menuBarFraction: CGFloat

    static let fallback = ScreenShape(aspect: 16 / 10, menuBarFraction: 0.03)

    init(aspect: CGFloat, menuBarFraction: CGFloat) {
        self.aspect = aspect
        self.menuBarFraction = menuBarFraction
    }

    @MainActor
    init(_ screen: NSScreen?) {
        guard let screen, screen.frame.height > 0 else {
            self = .fallback
            return
        }
        let frame = screen.frame
        aspect = frame.width / frame.height
        menuBarFraction = max(0, frame.maxY - screen.visibleFrame.maxY) / frame.height
    }
}

@MainActor
@Observable
final class GalleryModel {
    private(set) var wallpapers: [Wallpaper] = []
    private(set) var isLoading = false
    private(set) var selection: Wallpaper.ID?
    private(set) var currentPath: String?
    private(set) var thumbnails: [Wallpaper: NSImage] = [:]
    private(set) var details: [Wallpaper: WallpaperDetails] = [:]
    /// Only exists while the gallery window is on screen, so a closed or
    /// hidden gallery does not keep a second video decoding.
    private(set) var player: AVQueuePlayer?
    var screenShape = ScreenShape.fallback

    @ObservationIgnored var onApply: ((Wallpaper) -> Void)?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var previewing: Wallpaper?
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var reloadAgain = false

    /// Concurrent thumbnail decodes; each one opens a hardware decoder session.
    private let thumbnailConcurrency = 4

    var selected: Wallpaper? {
        wallpapers.first { $0.id == selection }
    }

    func isCurrent(_ wallpaper: Wallpaper) -> Bool {
        wallpaper.path == currentPath
    }

    // MARK: Library

    func reload() {
        guard !isLoading else {
            reloadAgain = true
            return
        }
        isLoading = true

        Task {
            let found = await Task.detached(priority: .userInitiated) {
                WallpaperLibrary.scan()
            }.value

            wallpapers = found
            currentPath = PersistenceManager.shared.lastWallpaperPath

            let kept = Set(found)
            thumbnails = thumbnails.filter { kept.contains($0.key) }
            details = details.filter { kept.contains($0.key) }

            if selected == nil {
                select(found.first { isCurrent($0) }?.id ?? found.first?.id)
            } else {
                // Restarts only if the file was replaced under the same name.
                startPreview()
                loadDetails()
            }

            isLoading = false
            loadThumbnails()

            if reloadAgain {
                reloadAgain = false
                reload()
            }
        }
    }

    /// Called when a wallpaper is applied from anywhere in the app.
    func markCurrent(_ path: String) {
        currentPath = path
        if isVisible, !wallpapers.contains(where: { $0.path == path }) {
            reload()
        }
    }

    // MARK: Selection

    func select(_ id: Wallpaper.ID?) {
        guard id != selection else { return }
        selection = id
        startPreview()
        loadDetails()
    }

    func moveSelection(by offset: Int) {
        guard !wallpapers.isEmpty else { return }
        let index = wallpapers.firstIndex { $0.id == selection } ?? 0
        let next = min(max(index + offset, 0), wallpapers.count - 1)
        select(wallpapers[next].id)
    }

    func apply(_ wallpaper: Wallpaper) {
        guard !isCurrent(wallpaper) else { return }
        onApply?(wallpaper)
    }

    func revealInFinder(_ wallpaper: Wallpaper) {
        NSWorkspace.shared.activateFileViewerSelecting([wallpaper.url])
    }

    func openLibraryFolder() {
        NSWorkspace.shared.open(WallpaperLibrary.directory)
    }

    // MARK: Preview

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            startPreview()
        } else {
            stopPreview()
        }
    }

    private func startPreview() {
        guard player == nil || previewing != selected else { return }
        stopPreview()
        guard isVisible, let wallpaper = selected else { return }

        let item = AVPlayerItem(asset: AVURLAsset(url: wallpaper.url))
        let player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        self.player = player
        previewing = wallpaper
        player.play()
    }

    private func stopPreview() {
        looper?.disableLooping()
        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
        previewing = nil
    }

    // MARK: Thumbnails and details

    private func loadThumbnails() {
        let pending = wallpapers.filter { thumbnails[$0] == nil }
        guard !pending.isEmpty else { return }
        let concurrency = thumbnailConcurrency

        Task {
            await withTaskGroup(of: (Wallpaper, NSImage?).self) { group in
                var queue = pending[...]

                func enqueue() {
                    guard let wallpaper = queue.popFirst() else { return }
                    group.addTask { (wallpaper, await Self.thumbnail(for: wallpaper.url)) }
                }

                for _ in 0..<concurrency { enqueue() }

                for await (wallpaper, image) in group {
                    if let image, wallpapers.contains(wallpaper) {
                        thumbnails[wallpaper] = image
                    }
                    enqueue()
                }
            }
        }
    }

    private func loadDetails() {
        guard let wallpaper = selected, details[wallpaper] == nil else { return }

        Task {
            if let loaded = await Self.details(for: wallpaper.url) {
                details[wallpaper] = loaded
            }
        }
    }

    private nonisolated static func thumbnail(for url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        // Two seconds in, matching the lock screen preview, which skips the
        // black or faded first frame many loops start on.
        let time = CMTime(seconds: 2, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private nonisolated static func details(for url: URL) async -> WallpaperDetails? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let properties = try? await track.load(.naturalSize, .nominalFrameRate, .preferredTransform) else {
            return nil
        }

        let (size, rate, transform) = properties
        let oriented = size.applying(transform)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        return WallpaperDetails(
            pixelSize: CGSize(width: abs(oriented.width), height: abs(oriented.height)),
            duration: duration.seconds,
            frameRate: rate,
            fileSize: Int64(fileSize)
        )
    }
}
