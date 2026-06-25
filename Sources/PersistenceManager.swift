import Foundation

final class PersistenceManager: @unchecked Sendable {
    static let shared = PersistenceManager()
    private let defaults = UserDefaults.standard
    private let fm = FileManager.default

    private var sharedDir: URL {
        let paths = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("OpenLiveWalls", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var lastWallpaperPath: String? {
        get { defaults.string(forKey: "lastWallpaperPath") }
        set {
            defaults.set(newValue, forKey: "lastWallpaperPath")
            if let path = newValue {
                let fileURL = sharedDir.appendingPathComponent("current_wallpaper.txt")
                try? path.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    var isLockScreenEnabled: Bool {
        get { defaults.bool(forKey: "lockScreenEnabled") }
        set { defaults.set(newValue, forKey: "lockScreenEnabled") }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "launchedBefore") }
        set { defaults.set(newValue, forKey: "launchedBefore") }
    }

    private init() {}
}
