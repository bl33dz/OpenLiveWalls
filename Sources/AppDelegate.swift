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

        switch LockScreenManager.shared.lockScreenSupportStatus(for: url) {
        case .supported:
            LockScreenManager.shared.inject(videoSourceURL: url)
            LockScreenManager.shared.reapply()
        case .unsupported(let reason):
            showLockScreenUnsupportedAlert(reason: reason)
        }
    }

    private func showLockScreenUnsupportedAlert(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Desktop wallpaper applied"
        alert.informativeText = "This video was not applied to the lock screen. \(reason)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.cleanup()
    }
}
