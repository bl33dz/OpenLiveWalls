import AppKit
import ServiceManagement

@MainActor
final class MenuBarController {
    var wallpaperSelected: ((String) -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let localDir: URL
    private var cachedFiles: [(name: String, path: String)] = []

    init() {
        let base = Bundle.main.bundleURL
            .deletingLastPathComponent()
        localDir = base.appendingPathComponent("local", isDirectory: true)
        setupMenu()
        scanLocalFolder()
    }

    private func setupMenu() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "OpenLiveWalls")
            button.action = #selector(showMenu)
            button.target = self
        }
    }

    @objc private func showMenu() {
        scanLocalFolder()

        let menu = NSMenu()
        addWallpaperItems(to: menu)
        addFileActions(to: menu)
        addAppActions(to: menu)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)

        DispatchQueue.main.async {
            self.statusItem.menu = nil
        }
    }

    private func addWallpaperItems(to menu: NSMenu) {
        if cachedFiles.isEmpty {
            let item = NSMenuItem(title: "No supported wallpapers found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let currentKey = PersistenceManager.shared.lastWallpaperPath
        for file in cachedFiles {
            let item = NSMenuItem(title: file.name, action: #selector(selectWallpaper(_:)), keyEquivalent: "")
            item.representedObject = file.path
            item.target = self
            item.state = (file.path == currentKey) ? .on : .off
            menu.addItem(item)
        }
    }

    private func addFileActions(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Local Folder", action: #selector(openLocalFolder), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: "Refresh Wallpapers", action: #selector(refreshWallpapers), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let importItem = NSMenuItem(title: "Import & Convert to Lock Screen…", action: #selector(importAndConvert), keyEquivalent: "i")
        importItem.target = self
        menu.addItem(importItem)
    }

    private func addAppActions(to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launchItem.target = self
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About OpenLiveWalls", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func scanLocalFolder() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: localDir.path) else {
            try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
            return
        }
        do {
            let files = try fm.contentsOfDirectory(at: localDir, includingPropertiesForKeys: nil)
            cachedFiles = files
                .filter { isSupportedWallpaper($0) }
                .map { (name: $0.lastPathComponent, path: $0.path) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            print("[MenuBar] Failed to scan local/: \(error)")
            cachedFiles = []
        }
    }

    private func isSupportedWallpaper(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "mov" else { return false }

        switch LockScreenManager.shared.lockScreenSupportStatus(for: url) {
        case .supported:
            return true
        case .unsupported:
            return false
        }
    }

    @objc private func selectWallpaper(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        wallpaperSelected?(path)
    }

    @objc private func openLocalFolder() {
        NSWorkspace.shared.open(localDir)
    }

    @objc private func refreshWallpapers() {
        scanLocalFolder()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("[MenuBar] Failed to toggle launch at login: \(error)")
        }
    }

    @objc private func importAndConvert() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let nameAlert = NSAlert()
        nameAlert.messageText = "Wallpaper Name"
        nameAlert.informativeText = "Enter a name for this wallpaper:"

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = url.deletingPathExtension().lastPathComponent
        nameAlert.accessoryView = textField
        nameAlert.addButton(withTitle: "Convert")
        nameAlert.addButton(withTitle: "Cancel")
        guard nameAlert.runModal() == .alertFirstButtonReturn else { return }

        let name = textField.stringValue.trimmingCharacters(in: .whitespaces)
        let displayName = name.isEmpty ? url.deletingPathExtension().lastPathComponent : name

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Converting: " + displayName
        win.level = .floating
        win.center()

        let spinner = NSProgressIndicator(frame: NSRect(x: 12, y: 220, width: 16, height: 16))
        spinner.style = .spinning
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: "Encoding " + displayName + "...")
        label.frame = NSRect(x: 34, y: 218, width: 370, height: 20)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 396, height: 200))
        let logBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        let logTextColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        let logFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = logBackgroundColor

        let logView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
        logView.isEditable = false
        logView.isRichText = true
        logView.drawsBackground = true
        logView.font = logFont
        logView.textColor = logTextColor
        logView.backgroundColor = logBackgroundColor
        logView.insertionPointColor = logTextColor
        logView.typingAttributes = [
            .font: logFont,
            .foregroundColor: logTextColor
        ]
        scroll.documentView = logView

        win.contentView?.addSubview(spinner)
        win.contentView?.addSubview(label)
        win.contentView?.addSubview(scroll)
        win.orderFront(nil)

        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            if let output = String(data: fileHandle.availableData, encoding: .utf8),
               !output.isEmpty {
                DispatchQueue.main.async {
                    let outputFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
                    let outputColor = NSColor(calibratedWhite: 0.92, alpha: 1)
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: outputFont,
                        .foregroundColor: outputColor
                    ]
                    let start = logView.textStorage?.length ?? 0
                    logView.textStorage?.append(NSAttributedString(string: output, attributes: attributes))
                    let length = (logView.textStorage?.length ?? start) - start
                    logView.textStorage?.addAttributes(attributes, range: NSRange(location: start, length: length))
                    logView.scrollToEndOfDocument(nil)
                }
            }
        }

        DispatchQueue.global().async {
            do {
                try LockScreenManager.shared.convertAndInject(source: url, name: displayName, outputPipe: pipe)
                DispatchQueue.main.async {
                    win.orderOut(nil)
                    self.refreshWallpapers()

                    let localDir = Bundle.main.bundleURL
                        .deletingLastPathComponent()
                        .appendingPathComponent("local", isDirectory: true)
                    let dest = localDir.appendingPathComponent(displayName + "_lock.mov")
                    self.wallpaperSelected?(dest.path)
                }
            } catch {
                DispatchQueue.main.async {
                    win.orderOut(nil)
                    let alert = NSAlert()
                    alert.messageText = "Conversion failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "OpenLiveWalls"
        alert.informativeText = "Live wallpapers from local files."
        alert.icon = nil
        alert.runModal()
    }
}
