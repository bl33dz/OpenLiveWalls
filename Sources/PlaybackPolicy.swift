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

/// Per-screen state queries backing `PlaybackPolicy`.
///
/// `NSWindow.occlusionState` is the obvious tool here and it does not work for
/// this window. A wallpaper window sits at desktop level with
/// `.canJoinAllSpaces`, so AppKit mirrors it onto every space and reports
/// `.visible` as long as *any* space shows it - measured as `visible=true`
/// with a screen fully covered by opaque windows. Coverage is therefore
/// computed directly from the window server's geometry instead.
///
/// Every query is per screen: with one display covered and another showing the
/// desktop, only the covered one should stop decoding.
@MainActor
enum ScreenState {
    /// True when no part of the wallpaper is showing on `screen`.
    ///
    /// Coverage is tested against the screen's `visibleFrame`, which already
    /// excludes the menu bar and Dock - regions the wallpaper never owns and
    /// which no ordinary window would ever cover.
    static func isHidden(_ screen: NSScreen) -> Bool {
        guard let region = visibleRegion(for: screen) else { return false }

        let covers = normalWindowRects()
        guard !covers.isEmpty else { return false }

        return isCovered(region, by: covers)
    }

    /// True when a window exactly fills `screen`, including the menu bar strip.
    ///
    /// A zoomed (green-button) window stops below the menu bar, so it stays
    /// clear of this test; only a real fullscreen space matches a full display
    /// frame at the origin.
    static func isFullscreen(_ screen: NSScreen) -> Bool {
        guard let display = displayBounds(for: screen),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double] else { continue }

            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if fits(rect, display) { return true }
        }

        return false
    }

    /// `screen` bounds in the window server's flipped global space, which is
    /// the space `kCGWindowBounds` reports in.
    private static func displayBounds(for screen: NSScreen) -> CGRect? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }

    /// The screen's wallpaper-bearing area, converted from AppKit's
    /// bottom-left origin to the window server's top-left origin.
    ///
    /// The flip is measured against the primary screen's height, since global
    /// window coordinates are anchored to the primary display's top edge.
    private static func visibleRegion(for screen: NSScreen) -> CGRect? {
        let screens = NSScreen.screens
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else {
            return nil
        }
        let flipHeight = primary.frame.maxY
        let frame = screen.visibleFrame

        return CGRect(x: frame.origin.x,
                      y: flipHeight - frame.maxY,
                      width: frame.width,
                      height: frame.height)
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

    /// Edge gaps thinner than this are structural rather than visible
    /// wallpaper. macOS leaves a few points between a window's bottom edge and
    /// the Dock, and a secondary display can report a `visibleFrame` spanning
    /// its whole height while a menu bar strip at the top is covered by no
    /// ordinary window. Measured at 4pt and 30pt respectively on a two-display
    /// setup, which is why requiring total coverage never paused anything.
    private static let sliverLimit: CGFloat = 40

    /// Uncovered fraction at or below this still counts as hidden.
    private static let visibleAreaTolerance: CGFloat = 0.005

    /// Coverage test by rectangle subtraction: whittle `target` down by each
    /// covering rect, discard edge slivers, and judge the rest by area.
    ///
    /// Area rather than emptiness is the deciding rule because a strip a few
    /// points tall along one edge is not someone looking at their wallpaper,
    /// while a genuinely visible patch of desktop is chunky in both dimensions.
    private static func isCovered(_ target: CGRect, by rects: [CGRect]) -> Bool {
        let targetArea = target.width * target.height
        guard targetArea > 0 else { return true }

        var remaining = [target]

        for rect in rects {
            if remaining.isEmpty { return true }
            remaining = remaining
                .flatMap { subtract(rect, from: $0) }
                .filter { $0.width > 1 && $0.height > 1 }
        }

        let meaningful = remaining.filter { min($0.width, $0.height) > sliverLimit }
        let uncovered = meaningful.reduce(CGFloat.zero) { $0 + $1.width * $1.height }

        return uncovered / targetArea <= visibleAreaTolerance
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

    private static func fits(_ rect: CGRect, _ display: CGRect) -> Bool {
        abs(rect.origin.x - display.origin.x) <= 1
            && abs(rect.origin.y - display.origin.y) <= 1
            && abs(rect.width - display.width) <= 1
            && abs(rect.height - display.height) <= 1
    }
}
