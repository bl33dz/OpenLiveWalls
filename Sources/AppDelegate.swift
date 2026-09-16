import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menu = MenuBarController()
    private let engine = WallpaperEngine()
    private let gallery = GalleryWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start()

        menu.wallpaperSelected = { [weak self] path in
            self?.apply(path)
        }

        menu.policyChanged = { [weak self] policy in
            self?.engine.setPolicy(policy)
        }

        menu.galleryRequested = { [weak self] in
            self?.gallery.show()
        }

        gallery.model.onApply = { [weak self] wallpaper in
            self?.apply(wallpaper.path)
        }

        if let saved = PersistenceManager.shared.lastWallpaperPath,
           FileManager.default.fileExists(atPath: saved) {
            apply(saved)
        }

        if ProcessInfo.processInfo.environment["OWL_OPEN_GALLERY"] != nil {
            gallery.show()
        }
    }

    private func apply(_ path: String) {
        let url = URL(fileURLWithPath: path)

        PersistenceManager.shared.lastWallpaperPath = path
        engine.applyWallpaper(url: url)
        gallery.model.markCurrent(path)

        switch LockScreenManager.shared.lockScreenSupportStatus(for: url) {
        case .supported:
            Task {
                await LockScreenManager.shared.inject(videoSourceURL: url)
                LockScreenManager.shared.reapply()
            }
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
