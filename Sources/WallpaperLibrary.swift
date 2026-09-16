import Foundation
import Synchronization

/// A converted wallpaper in the library folder.
struct Wallpaper: Identifiable, Hashable, Sendable {
    let url: URL
    /// Part of equality, so a file replaced under the same name counts as a
    /// different wallpaper and anything cached for the old file is dropped.
    let modified: Date

    var id: String { url.path }
    var path: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The `local/` folder next to the app bundle, holding converted `.mov` files.
enum WallpaperLibrary {
    static let directory = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("local", isDirectory: true)

    private struct CheckedFile {
        let modified: Date
        let size: Int
        let supported: Bool
    }

    /// The support check reads the whole file, so results are kept per file
    /// version and only files that changed on disk are read again.
    private static let checked = Mutex<[String: CheckedFile]>([:])

    /// Supported wallpapers, sorted by name. Reads unchecked files in full, so
    /// call it off the main thread when the library may have changed.
    static func scan() -> [Wallpaper] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            return []
        }

        do {
            // Listing a symlinked folder by URL fails, so follow the link first.
            let files = try fm.contentsOfDirectory(
                at: directory.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            return files
                .compactMap(supportedWallpaper)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            print("[Library] Failed to scan local/: \(error)")
            return []
        }
    }

    private static func supportedWallpaper(at url: URL) -> Wallpaper? {
        guard url.pathExtension.lowercased() == "mov" else { return nil }

        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? 0
        let wallpaper = Wallpaper(url: url, modified: modified)

        if let hit = checked.withLock({ $0[url.path] }), hit.modified == modified, hit.size == size {
            return hit.supported ? wallpaper : nil
        }

        let supported: Bool
        switch LockScreenManager.shared.lockScreenSupportStatus(for: url) {
        case .supported:
            supported = true
        case .unsupported:
            supported = false
        }

        checked.withLock {
            $0[url.path] = CheckedFile(modified: modified, size: size, supported: supported)
        }
        return supported ? wallpaper : nil
    }
}
