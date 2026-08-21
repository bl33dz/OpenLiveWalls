import AppKit

/// Controls when the desktop wallpaper stops decoding.
///
/// Video playback on an unwatched desktop is pure waste: the wallpaper window
/// sits below every app window, so whenever something covers it the decoder is
/// producing frames nobody sees.
enum PlaybackPolicy: String, CaseIterable {
    /// Never pause. Original behaviour.
    case always
    /// Pause while any app occupies a fullscreen space.
    case fullscreen
    /// Pause whenever no part of the wallpaper is visible.
    case covered

    var title: String {
        switch self {
        case .always: return "Always Play"
        case .fullscreen: return "Pause in Fullscreen"
        case .covered: return "Pause When Covered"
        }
    }

    var detail: String {
        switch self {
        case .always: return "Wallpaper decodes continuously."
        case .fullscreen: return "Stops while an app is in fullscreen."
        case .covered: return "Stops whenever windows hide the desktop."
        }
    }
}

/// Screen-state queries backing `PlaybackPolicy`.
///
/// `NSWindow.occlusionState` is the obvious tool here and it does not work for
/// this window. A wallpaper window sits at desktop level with
/// `.canJoinAllSpaces`, so AppKit mirrors it onto every space and reports
/// `.visible` as long as *any* space shows it — measured as `visible=true`
/// with a screen fully covered by opaque windows. Coverage is therefore
/// computed directly from the window server's geometry instead.
@MainActor
enum ScreenState {
    /// True when no part of the wallpaper is showing on any display.
    ///
    /// Coverage is tested against each screen's `visibleFrame`, which already
    /// excludes the menu bar and Dock — regions the wallpaper never owns and
    /// which no ordinary window would ever cover.
    static func isDesktopHidden() -> Bool {
        let regions = visibleRegions()
        guard !regions.isEmpty else { return false }

        let covers = normalWindowRects()
        guard !covers.isEmpty else { return false }

        return regions.allSatisfy { isCovered($0, by: covers) }
    }

    /// Each screen's wallpaper-bearing area, in the window server's flipped
    /// global coordinate space so it can be compared with `kCGWindowBounds`.
    private static func visibleRegions() -> [CGRect] {
        let screens = NSScreen.screens
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else {
            return []
        }
        let flipHeight = primary.frame.maxY

        return screens.map { screen in
            let frame = screen.visibleFrame
            return CGRect(x: frame.origin.x,
                          y: flipHeight - frame.maxY,
                          width: frame.width,
                          height: frame.height)
        }
    }

    /// Opaque, on-screen, ordinary application windows.
    ///
    /// Layer 0 is the deciding filter: it admits real app windows while
    /// excluding the Dock, menu bar, wallpaper layers and this app's own
    /// window. The Dock in particular reports a full-screen opaque frame that
    /// would otherwise make every screen look covered.
    private static func normalWindowRects() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var rects: [CGRect] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) >= 0.99,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double] else { continue }

            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if rect.width > 1, rect.height > 1 { rects.append(rect) }
        }
        return rects
    }

    /// Exact coverage test by rectangle subtraction: whittle `target` down by
    /// each covering rect and report whether anything survives.
    private static func isCovered(_ target: CGRect, by rects: [CGRect]) -> Bool {
        var remaining = [target]

        for rect in rects {
            if remaining.isEmpty { return true }
            remaining = remaining
                .flatMap { subtract(rect, from: $0) }
                // Sliver tolerance: shadows and rounded corners leave sub-pixel
                // gaps that should not count as visible wallpaper.
                .filter { $0.width > 2 && $0.height > 2 }
        }

        return remaining.isEmpty
    }

    /// `rect` minus `cut`, as up to four non-overlapping pieces.
    private static func subtract(_ cut: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(cut)
        guard !overlap.isNull, !overlap.isEmpty else { return [rect] }

        var pieces: [CGRect] = []
        if overlap.minY > rect.minY {
            pieces.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY))
        }
        if overlap.maxY < rect.maxY {
            pieces.append(CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY))
        }
        if overlap.minX > rect.minX {
            pieces.append(CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height))
        }
        if overlap.maxX < rect.maxX {
            pieces.append(CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height))
        }
        return pieces
    }

    /// True when a window exactly fills a display, including the menu bar strip.
    ///
    /// A zoomed (green-button) window stops below the menu bar, so it stays
    /// clear of this test; only a real fullscreen space matches a full display
    /// frame at the origin.
    static func isAnyAppFullscreen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let displays = displayFrames()
        guard !displays.isEmpty else { return false }

        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double] else { continue }

            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)

            // A fullscreen window matches its display frame outright. Allow a
            // point of slack for rounding on scaled displays.
            if displays.contains(where: { fits(rect, $0) }) { return true }
        }

        return false
    }

    /// Display bounds in the window server's flipped, global coordinate space,
    /// which is what `kCGWindowBounds` reports.
    private static func displayFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.map { CGDisplayBounds($0) }
    }

    private static func fits(_ rect: CGRect, _ display: CGRect) -> Bool {
        abs(rect.origin.x - display.origin.x) <= 1
            && abs(rect.origin.y - display.origin.y) <= 1
            && abs(rect.width - display.width) <= 1
            && abs(rect.height - display.height) <= 1
    }
}
