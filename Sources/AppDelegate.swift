import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menu = MenuBarController()
    private let engine = WallpaperEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start()

        menu.wallpaperSelected = { [weak self] path in
            self?.apply(path)
        }

        if let saved = PersistenceManager.shared.lastWallpaperPath,
           FileManager.default.fileExists(atPath: saved) {
            apply(saved)
        }
    }

    private func apply(_ path: String) {
        let url = URL(fileURLWithPath: path)

        PersistenceManager.shared.lastWallpaperPath = path
        engine.applyWallpaper(url: url)
        LockScreenManager.shared.inject(videoSourceURL: url)
        LockScreenManager.shared.reapply()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.cleanup()
    }
}
