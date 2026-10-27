// The summary card in the editor (design/screens/story-bible/spec.md §3): ⌥⌘R on a name at the caret, force click on a
// name (else the system's Look Up), and — only when the writer turns it on — 1 s of hover (never within 3 s of typing).
// An NSPopover below the name; the editor keeps the keyboard: Return opens the entry (when the writer asked for the
// card), Esc closes it, and any other key closes it and goes on to the text as usual.
import AppKit
import IthacaDesign
import SwiftUI

@MainActor
final class EntryCardPresenter: NSObject, NSPopoverDelegate {
    private unowned let coordinator: ManuscriptView.Coordinator
    private var model: AppModel { coordinator.model }
    private var textView: ManuscriptTextView? { coordinator.textView }

    private var popover: NSPopover?
    /// The card on screen: its entry, the name's range, and whether the writer asked for it (key / force click).
    private(set) var shown: (entry: String, range: NSRange, asked: Bool)?
    private var hoverTimer: Timer?
    private var tracking: NSTrackingArea?

    init(coordinator: ManuscriptView.Coordinator) { self.coordinator = coordinator }

    var isOpen: Bool { popover?.isShown == true }

    /// ⌥⌘R: the name under or right before the caret.
    @discardableResult
    func showAtCaret() -> Bool {
        guard let tv = textView, !tv.hasMarkedText() else { return false }
        let caret = tv.selectedRange()
        guard let hit = NameMatcher.name(at: caret.location, in: tv.string as NSString, bible: model.bible) else {
            NSSound.beep()
            return false
        }
        show(hit.entry, hit.range, asked: true)
        return true
    }

    /// Force click / hover: the name under the pointer (`index` from `characterIndex(for:)`).
    func show(at index: Int, asked: Bool) -> Bool {
        guard let tv = textView, index != NSNotFound, !model.bible.isEmpty,
              let hit = NameMatcher.name(at: index, in: tv.string as NSString, bible: model.bible, endInclusive: false) else { return false }
        if let s = shown, s.entry == hit.entry.sheet, s.range == hit.range, isOpen { return true }
        show(hit.entry, hit.range, asked: asked)
        return true
    }

    func show(_ entry: BibleEntry, _ range: NSRange, asked: Bool) {
        guard let tv = textView, let window = tv.window else { return }
        close()
        let content = EntryCardPopover(entry: entry, seen: model.cardAppearances(of: entry), model: model) { [weak self] in self?.openEntry() }
        let host = NSHostingController(rootView: content)
        host.view.appearance = tv.effectiveAppearance
        let pop = NSPopover()
        pop.contentViewController = host
        pop.behavior = .transient
        pop.animates = false
        pop.delegate = self
        pop.appearance = tv.effectiveAppearance
        pop.contentSize = host.view.fittingSize
        let screen = tv.firstRect(forCharacterRange: range, actualRange: nil)
        var rect = tv.convert(window.convertFromScreen(screen), from: nil)
        if screen == .zero { rect = NSRect(x: tv.textContainerInset.width, y: tv.textContainerInset.height, width: 1, height: 1) }
        pop.show(relativeTo: rect, of: tv, preferredEdge: .maxY)
        popover = pop
        shown = (entry.sheet, range, asked)
        // The editor keeps the keyboard.
        if window.firstResponder !== tv { window.makeFirstResponder(tv) }
        NSAccessibility.post(element: tv, notification: .announcementRequested,
                             userInfo: [.announcement: [entry.name, entry.summary].compactMap { $0 }.joined(separator: ", "),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// True when a card was open.
    @discardableResult
    func close() -> Bool {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard let pop = popover else { return false }
        popover = nil
        let wasOpen = pop.isShown
        pop.delegate = nil
        pop.close()
        shown = nil
        return wasOpen
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        shown = nil
    }

    /// Keys after the input method while the card is up.
    func doCommand(_ selector: Selector) -> Bool {
        guard isOpen, let s = shown else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        case #selector(NSResponder.insertNewline(_:)) where s.asked:
            openEntry()
            return true
        default:
            // Any other key closes the card and does what it always does.
            close()
            return false
        }
    }

    func openEntry() {
        guard let s = shown else { return }
        close()
        model.openSheet(s.entry)
    }

    // MARK: Hover (Settings › Editor, off by default)

    /// Mouse-moved events only while the preference is on.
    func updateTracking() {
        guard let tv = textView else { return }
        if model.hoverCard, tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: tv, userInfo: nil)
            tv.addTrackingArea(area)
            tracking = area
        } else if !model.hoverCard, let area = tracking {
            tv.removeTrackingArea(area)
            tracking = nil
            hoverTimer?.invalidate()
        }
    }

    static let hoverDelay: TimeInterval = 1
    static let quietAfterTyping: TimeInterval = 3

    func mouseMoved(_ event: NSEvent) {
        guard model.hoverCard, let tv = textView, let window = tv.window else { return }
        hoverTimer?.invalidate()
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let index = tv.characterIndex(for: point)
        // A card that came from hovering goes when the pointer leaves the name.
        if let s = shown, !s.asked, !NSLocationInRange(index, s.range) { close() }
        guard index != NSNotFound, !tv.hasMarkedText() else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tv = self.textView, NSEvent.pressedMouseButtons == 0,
                      Date().timeIntervalSince(tv.lastTyped) >= Self.quietAfterTyping, !tv.hasMarkedText() else { return }
                _ = self.show(at: index, asked: false)
            }
        }
    }
}
