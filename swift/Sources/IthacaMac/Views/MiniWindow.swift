// The sticky-note window (⌘4, app-shell "작은 창"): the main window shrinks to a small editor at the screen's edge —
// or the window is simply made narrow by hand (0.10.1) —
// an ordinary window other apps can cover (owner, 0.6.5); ⌘4 or "Back to Full Window" puts it back where it was. One window, one buffer — nothing to sync.
import AppKit
import IthacaDesign

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
        // Back to full: a frame saved narrow (the window was made small by hand) would land in the note again.
        let target = saved.flatMap { onScreen($0) }.flatMap { mini || !isSmall($0.width) ? $0 : nil } ?? (mini ? corner(w) : centered(w))
        apply(w)
        // The sizes passed on the way would flip the layout back and forth: the shell ignores them until it lands.
        moving = true
        w.setFrame(target, display: true, animate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + w.animationResizeTime(target) + 0.05) { moving = false }
    }

    /// The window can shrink to the note's size by hand; below the full window's minimum width it shows as the note.
    static func apply(_ w: NSWindow) {
        w.minSize = minSize
    }

    /// A ⌘4 move is under way.
    private(set) static var moving = false

    static func isSmall(_ width: Double) -> Bool { width < T.Layout.Window.minWidth }

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
