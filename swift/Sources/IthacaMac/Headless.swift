// Test and snapshot runs (--selftest*, --snapshot): every window stays invisible and click-through, so a run
// never covers the owner's screen. Drawing still happens — snapshots cache views, not the screen — and the
// window server may clamp an off-screen origin back on screen, so moving windows away is not enough.
import AppKit

@MainActor
enum Headless {
    private static var observer: NSObjectProtocol?

    /// Hides every window the run opens from now on (panels and popovers too).
    static func enable() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.windows.forEach(hide) }
        }
    }

    static func hide(_ w: NSWindow) {
        guard w.alphaValue != 0 || !w.ignoresMouseEvents else { return }
        w.alphaValue = 0
        w.ignoresMouseEvents = true
    }
}
