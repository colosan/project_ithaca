// `@` name completion (design/screens/story-bible/spec.md §2) and the underline of names in the text (§5).
//
// Input rules (docs/research/2026-10-27-story-bible-v2.md: three reviews):
// - Only opens when called: `@` typed at a line start, after whitespace or after an opening quote / bracket.
//   `@@` leaves a single `@` and no panel; anywhere else (`me@mail`) `@` is just a character.
// - The panel never takes key focus (a non-activating child panel): the editor keeps receiving every key.
// - The filter includes the syllable still being composed (marked text sits in the text storage).
// - Keys arrive in `textView(_:doCommandBy:)`, after the input method: Return while a syllable is composing reaches
//   us after the input method committed it, and `commit` re-reads the query from the text anyway.
// - Inserting replaces `@…` with the name (or the alias that matched) as one undo step (Coordinator.replace).
import AppKit
import IthacaDesign
import SwiftUI

@MainActor
@Observable
final class NameListState {
    var rows: [NameCandidate] = []
    var selected = 0
}

@MainActor
final class NameCompletion {
    private unowned let coordinator: ManuscriptView.Coordinator
    private var model: AppModel { coordinator.model }
    private var textView: ManuscriptTextView? { coordinator.textView }

    /// Where the `@` sits while the panel is open.
    private(set) var anchor: Int?
    let state = NameListState()
    private var panel: NamePanel?
    /// The last committed input was a typed `@` (set in `willInsert`, read in `textDidChange`).
    private var typedAt = false
    private var observers: [NSObjectProtocol] = []

    init(coordinator: ManuscriptView.Coordinator) { self.coordinator = coordinator }

    var isOpen: Bool { anchor != nil }

    /// Characters after which `@` opens the panel (besides line start and whitespace).
    static let openers: Set<Character> = ["\"", "'", "“", "‘", "「", "『", "(", "[", "{", "《", "〈", "【", "<", "（", "［"]

    static func canOpen(_ ns: NSString, at at: Int) -> Bool {
        guard at > 0 else { return true }
        let prev = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: at - 1))
        guard let c = prev.first else { return true }
        return c.isWhitespace || c.isNewline || openers.contains(c)
    }

    // MARK: Input hooks (ManuscriptTextView.insertText, Coordinator)

    /// Committed input before it is inserted. True = handled here (the `@` of `@@`): the view must not insert it.
    func willInsert(_ s: String, replacementRange: NSRange) -> Bool {
        typedAt = false
        guard s == "@", let tv = textView, !tv.hasMarkedText(), tv.selectedRanges.count == 1 else { return false }
        let sel = tv.selectedRange()
        if let a = anchor, sel.length == 0, sel.location == a + 1 {
            close()
            announce(model.t(.bibleCompleteClosed))
            return true
        }
        typedAt = replacementRange.location == NSNotFound || replacementRange == sel
        return false
    }

    func textDidChange() {
        guard let tv = textView else { return }
        if typedAt, anchor == nil {
            typedAt = false
            let ns = tv.string as NSString
            let caret = tv.selectedRange().location
            if caret >= 1, ns.character(at: caret - 1) == 0x40, Self.canOpen(ns, at: caret - 1), !model.bible.isEmpty {
                open(at: caret - 1)
            }
            return
        }
        typedAt = false
        if anchor != nil { update() }
    }

    func selectionChanged() { if anchor != nil { update() } }

    /// Keys after the input method. True = handled (the text view does nothing more with it).
    func doCommand(_ selector: Selector, shift: Bool) -> Bool {
        guard isOpen else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⇧Return: keep `@` and what was typed, just close.
            if shift { close(); return true }
            return commit()
        case #selector(NSResponder.insertTab(_:)): return commit()
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    // MARK: Panel

    private func open(at at: Int) {
        anchor = at
        state.selected = 0
        update()
        guard isOpen else { return }
        if let tv = textView {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: tv.window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                },
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: tv.enclosingScrollView?.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                },
            ]
        }
        announce(model.t(.bibleCompleteOpened, ["count": state.rows.count], count: state.rows.count) + " " + rowSpeech(state.selected))
    }

    func close() {
        guard anchor != nil else { return }
        anchor = nil
        state.rows = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    /// The query is everything from after `@` to the caret, the composing syllable included.
    private var queryEnd: Int? {
        guard let tv = textView else { return nil }
        let sel = tv.selectedRange()
        if tv.hasMarkedText() { return NSMaxRange(tv.markedRange()) }
        return sel.length == 0 ? sel.location : nil
    }

    var query: String? {
        guard let tv = textView, let a = anchor, let end = queryEnd, end > a else { return nil }
        let ns = tv.string as NSString
        guard a < ns.length, ns.character(at: a) == 0x40, end <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: a + 1, length: end - a - 1))
    }

    /// Re-filters from the text; closes when the `@` is gone, the caret left, a space was typed or nothing matches.
    private func update() {
        guard let q = query, !q.contains(where: { $0.isWhitespace || $0.isNewline }) else { close(); return }
        let rows = NameMatcher.candidates(q, in: model.bible)
        guard !rows.isEmpty else { close(); return }
        let keep = state.rows.indices.contains(state.selected) ? state.rows[state.selected].id : nil
        state.rows = rows
        state.selected = keep.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        show()
    }

    private func show() {
        guard let tv = textView, let window = tv.window else { return }
        let panel = self.panel ?? {
            let p = NamePanel()
            let host = NSHostingView(rootView: NameListView(state: state, model: model) { [weak self] i in
                self?.state.selected = i
                _ = self?.commit()
            })
            p.contentView = host
            self.panel = p
            return p
        }()
        panel.appearance = tv.effectiveAppearance
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        place()
        if !panel.isVisible { panel.orderFront(nil) }
    }

    /// Below the `@` (above it when the screen ends first).
    private func place() {
        guard let tv = textView, let panel, let a = anchor, let host = panel.contentView else { return }
        let rect = tv.firstRect(forCharacterRange: NSRange(location: a, length: 1), actualRange: nil)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        var origin = NSPoint(x: rect.minX - T.Space.s100, y: rect.minY - size.height - T.Space.s50)
        if let screen = tv.window?.screen, origin.y < screen.visibleFrame.minY { origin.y = rect.maxY + T.Space.s50 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    var panelFrame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    private func move(_ delta: Int) {
        guard !state.rows.isEmpty else { return }
        state.selected = (state.selected + delta + state.rows.count) % state.rows.count
        announce(rowSpeech(state.selected))
    }

    /// Replaces `@…` with the selected name. False when nothing was inserted (the key then does its usual thing).
    @discardableResult
    func commit() -> Bool {
        guard let tv = textView else { return false }
        // A syllable still composing is part of the query: commit it and filter again before picking.
        if tv.hasMarkedText() { tv.unmarkText() }
        update()
        guard let a = anchor, state.rows.indices.contains(state.selected), let end = queryEnd else { close(); return false }
        let pick = state.rows[state.selected]
        close()
        let name = pick.text as NSString
        coordinator.replace(tv, NSRange(location: a, length: end - a), with: pick.text, select: NSRange(location: a + name.length, length: 0))
        announce(model.t(.bibleCompleteInserted, ["name": pick.text]))
        return true
    }

    // MARK: VoiceOver

    func rowTitle(_ c: NameCandidate) -> String { c.alias ? "\(c.text) · \(c.entry.name)" : c.text }

    private func rowSpeech(_ i: Int) -> String {
        guard state.rows.indices.contains(i) else { return "" }
        let c = state.rows[i]
        return [rowTitle(c), c.entry.summary, c.entry.lastSeen.map(model.appearanceLabel)].compactMap { $0 }.joined(separator: ", ")
    }

    private func announce(_ text: String) {
        guard let tv = textView, !text.isEmpty else { return }
        NSAccessibility.post(element: tv, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Never key, never main: the manuscript keeps the keyboard while the list is up.
final class NamePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct NameListView: View {
    let state: NameListState
    let model: AppModel
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.rows.enumerated()), id: \.element.id) { i, c in
                NameRow(candidate: c, selected: i == state.selected, model: model)
                    .contentShape(Rectangle())
                    .onTapGesture { pick(i) }
            }
        }
        .padding(T.Space.s50)
        .frame(width: T.Layout.Pane.inspectorDefault + T.Space.s400)
        .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: T.Radius.panel).strokeBorder(Color.lineSubtle, lineWidth: T.Size.strokeHairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.t(.bibleCompleteLabel))
    }
}

private struct NameRow: View {
    let candidate: NameCandidate
    let selected: Bool
    let model: AppModel

    var body: some View {
        let e = candidate.entry
        HStack(spacing: T.Space.s100) {
            Icon(e.kind.icon, size: T.Size.iconSm, color: selected ? .inkPrimary : .inkTertiary)
            Text(candidate.alias ? "\(candidate.text) · \(e.name)" : candidate.text)
                .textStyle(.label, weight: T.Typography.heading.weight)
                .foregroundStyle(Color.inkPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if let s = e.summary {
                Text(s).textStyle(.caption).foregroundStyle(Color.inkTertiary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: T.Space.s50)
            // Episode number only: a sheet title here would crowd the summary out (the card shows it).
            if let n = e.lastSeen?.number {
                Text(model.t(.bibleEpisode, ["number": n])).textStyle(.caption).foregroundStyle(Color.inkTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, T.Space.s100)
        .frame(maxWidth: .infinity, minHeight: T.Size.controlSm, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(selected ? Color.surfaceSelected : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Underline (spec §5): drawn over the text, like the focus-mode dimming never touching the storage
//
// TextKit 2 rendering attributes would be the natural fit, but NSTextLayoutManager draws only colors from them
// (`.backgroundColor` shows, `.underlineStyle` does not, macOS 14–26). So the text view draws a dotted line under
// each name's text segments itself, after its own drawing (ManuscriptTextView.draw).

@MainActor
final class NameMarks {
    private unowned let coordinator: ManuscriptView.Coordinator
    private var model: AppModel { coordinator.model }
    private var applied: (generation: Int, on: Bool)?
    /// Name ranges to underline in the text view's current text.
    private(set) var ranges: [NSRange] = []

    init(coordinator: ManuscriptView.Coordinator) { self.coordinator = coordinator }

    /// Takes the mentions once per refresh (or when the preference flips). Never while composing:
    /// the next refresh (they wait for the composition too) picks them up.
    func update(force: Bool = false) {
        guard let tv = coordinator.textView else { return }
        let key = (generation: model.mentionsGeneration, on: model.underlineNames)
        guard force || applied.map({ $0.generation != key.generation || $0.on != key.on }) ?? true else { return }
        guard !tv.hasMarkedText() else { return }
        applied = key
        let before = ranges
        ranges = []
        if model.underlineNames {
            let ns = tv.string as NSString
            for m in model.sheetMentions where NSMaxRange(m.range) <= ns.length {
                // Only where the text still says that name (the mentions are a second old).
                guard let e = model.entry(m.entry), e.names.contains(where: { $0.text == ns.substring(with: m.range) }) else { continue }
                ranges.append(m.range)
            }
        }
        if before != ranges { tv.needsDisplay = true }
    }

    /// A text edit (from the storage delegate): names before it stay, names in the edited paragraph go until the
    /// next refresh (nothing drifts onto the wrong letters), names after it move along.
    func edited(_ range: NSRange, delta: Int, in ns: NSString) {
        guard !ranges.isEmpty else { return }
        let start = min(range.location, ns.length)
        let para = ns.paragraphRange(for: NSRange(location: start, length: min(range.length, ns.length - start)))
        let oldEnd = NSMaxRange(para) - delta
        ranges = ranges.compactMap { r in
            if NSMaxRange(r) <= para.location { return r }
            if r.location >= oldEnd { return NSRange(location: r.location + delta, length: r.length) }
            return nil
        }
    }

    /// ManuscriptTextView.draw: a dotted ink.tertiary line under each name, on every line fragment it spans.
    func draw(in tv: NSTextView, dirtyRect: NSRect) {
        guard !ranges.isEmpty, let tlm = tv.textLayoutManager, let tcs = tlm.textContentManager as? NSTextContentStorage else { return }
        let origin = tv.textContainerOrigin
        let path = NSBezierPath()
        path.lineWidth = 1
        path.setLineDash([1, 2], count: 2, phase: 0)
        for r in ranges {
            guard let tr = ManuscriptView.Coordinator.textRange(r, in: tcs) else { continue }
            tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, rect, baseline, _ in
                let y = (origin.y + rect.minY + baseline + 2).rounded() + 0.5
                guard y >= dirtyRect.minY - 4, y <= dirtyRect.maxY + 4 else { return true }
                path.move(to: NSPoint(x: origin.x + rect.minX, y: y))
                path.line(to: NSPoint(x: origin.x + rect.maxX, y: y))
                return true
            }
        }
        NSColor.token(T.Color.inkTertiary).setStroke()
        path.stroke()
    }

    /// Self-test: names underlined now.
    func debugUnderlined() -> Int { ranges.count }
}

// MARK: EditorBridge (⌥Esc, ⌥⌘R)

extension ManuscriptView.Coordinator {
    func completeName() {
        guard let tv = textView, tv.isEditable else { return }
        tv.window?.makeFirstResponder(tv)
        if tv.hasMarkedText() { commitComposition() }
        names.close()
        tv.complete(nil)
    }

    @discardableResult
    func showEntryCard() -> Bool {
        guard let tv = textView else { return false }
        tv.window?.makeFirstResponder(tv)
        return card.showAtCaret()
    }
}
