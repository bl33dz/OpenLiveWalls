import AppKit
import SwiftUI

/// Owns the wallpaper gallery window. The window is created once and reused;
/// its preview stops whenever the window is closed, minimised or hidden.
@MainActor
final class GalleryWindowController: NSObject, NSWindowDelegate {
    let model = GalleryModel()
    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window

        model.screenShape = ScreenShape(window.screen ?? NSScreen.main)
        model.reload()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.setVisible(true)
    }

    private func makeWindow() -> NSWindow {
        let window = GalleryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Wallpapers"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Video reads best on a dark surround, whatever the system appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 540)
        window.contentView = NSHostingView(rootView: GalleryView(model: model))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("GalleryWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.setVisible(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, window.isVisible else { return }
        model.setVisible(window.occlusionState.contains(.visible))
    }

    func windowDidChangeScreen(_ notification: Notification) {
        model.screenShape = ScreenShape(window?.screen)
    }
}

/// The app runs without a main menu, so Command-W is handled here.
private final class GalleryWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
