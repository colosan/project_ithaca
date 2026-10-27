// The sticky-note window (⌘4, app-shell "작은 창"): the main window shrinks to a small editor at the screen's edge and
// floats over other apps; ⌘4 or "Back to Full Window" puts it back where it was. One window, one buffer — nothing to sync.
import AppKit

@MainActor
enum MiniWindow {
    static let size = NSSize(width: 360, height: 480)
    static let minSize = NSSize(width: 260, height: 220)
    private static let fullKey = "ithaca.fullFrame", miniKey = "ithaca.miniFrame"

    /// `mini` changed: remember the frame being left, move to the other one.
    static func toggle(_ w: NSWindow, mini: Bool, defaults: UserDefaults) {
        if w.styleMask.contains(.fullScreen) {
            // Leave full screen first; the frame can only change after the animation.
            w.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { toggle(w, mini: mini, defaults: defaults) }
            return
        }
        defaults.set(NSStringFromRect(w.frame), forKey: mini ? fullKey : miniKey)
        let saved = defaults.string(forKey: mini ? miniKey : fullKey).map(NSRectFromString)
        let target = saved.flatMap { onScreen($0) } ?? (mini ? corner(w) : centered(w))
        apply(w, mini: mini)
        w.setFrame(target, display: true, animate: true)
    }

    /// Level and minimum size only (launch in mini mode: the window already has the small frame).
    static func apply(_ w: NSWindow, mini: Bool) {
        w.level = mini ? .floating : .normal
        w.minSize = mini ? minSize : NSSize(width: 480, height: 560)
        if mini { w.collectionBehavior.insert(.fullScreenAuxiliary) } else { w.collectionBehavior.remove(.fullScreenAuxiliary) }
    }

    /// Top-right corner of the window's screen, inset like a note stuck to the edge.
    private static func corner(_ w: NSWindow) -> NSRect {
        let v = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        return NSRect(x: v.maxX - size.width - 24, y: v.maxY - size.height - 24, width: size.width, height: size.height)
    }

    private static func centered(_ w: NSWindow) -> NSRect {
        let v = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let s = NSSize(width: min(1240, v.width), height: min(800, v.height))
        return NSRect(x: v.midX - s.width / 2, y: v.midY - s.height / 2, width: s.width, height: s.height)
    }

    /// A saved frame only if it is still mostly on a connected screen.
    private static func onScreen(_ r: NSRect) -> NSRect? {
        guard r.width > 100, r.height > 100,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersection(r).width > r.width / 2 }) else { return nil }
        return r
    }
}
