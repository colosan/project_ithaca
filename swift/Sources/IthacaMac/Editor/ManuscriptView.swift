// The manuscript editor: NSTextView on TextKit 2, plain text with Markdown kept as typed.
//
// IME rules (docs/research/2026-10-24 §6, ADR-0004):
// - The text view owns the text. SwiftUI never writes it back while typing; it loads text only on `loadToken` changes.
// - Styling only edits attributes (never characters), runs ~150 ms after the last change and never while composing —
//   some Korean input sources compose without marked text, so "no marked text" alone isn't trusted: we also wait.
// - Never touch `layoutManager` (that silently drops to TextKit 1). Debug builds assert on the switch.
// - Undo is broken into word/pause-sized steps so ⌘Z never removes one jamo at a time.
import AppKit
import IthacaDesign
import SwiftUI

struct ManuscriptView: NSViewRepresentable {
    let model: AppModel
    let sizeClass: T.Layout.SizeClass

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ManuscriptTextView(usingTextLayoutManager: true)
        let scroll = ManuscriptScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.insertionPointColor = .token(T.Color.accentPrimary)
        tv.setAccessibilityLabel(model.t(.editorLabel))
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator
        context.coordinator.textView = tv
        // Story bible items on top of the context menu (EditorEntries.swift).
        tv.extraMenuItems = { [weak c = context.coordinator] in c?.entryMenuItems() ?? [] }
        // Story bible: `@` completion, the summary card, ⌥Esc names (NameCompletion.swift, EntryCardPresenter.swift).
        tv.names = context.coordinator.names
        tv.card = context.coordinator.card
        tv.marks = context.coordinator.marks
        tv.bibleEntries = { [weak model] in model?.bible ?? [] }
        tv.onEscape = { [weak model] in
            guard let model, model.panesHidden else { return false }
            model.showPanes()
            return true
        }
        model.editor = context.coordinator
        #if DEBUG
        NotificationCenter.default.addObserver(forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: tv, queue: nil) { _ in
            assertionFailure("ManuscriptView fell back to TextKit 1 — something touched layoutManager")
        }
        #endif
        context.coordinator.configure(sizeClass: sizeClass, force: true)
        context.coordinator.load()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.configure(sizeClass: sizeClass, force: false)
        if c.loadedToken != model.loadToken { c.load() }
        c.updateFocusDim()
        c.marks.update()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate, EditorBridge {
        let model: AppModel
        weak var textView: ManuscriptTextView?
        var loadedToken = -1
        private var style = StyleKey()
        private var dirtyRange: NSRange?
        private var styleTask: Task<Void, Never>?
        private var pauseTask: Task<Void, Never>?
        private var loading = false

        init(model: AppModel) { self.model = model }

        // Story bible in the editor (spec §2–§5).
        lazy var names = NameCompletion(coordinator: self)
        lazy var card = EntryCardPresenter(coordinator: self)
        lazy var marks = NameMarks(coordinator: self)

        // MARK: EditorBridge

        var isComposing: Bool { textView?.hasMarkedText() ?? false }

        /// Commits into the sheet this view loaded (`loadedToken`). If the model already moved to another sheet,
        /// `textDidChange` ignores it — the model flushes the old sheet before switching, so nothing is lost there.
        func commitComposition() {
            guard let tv = textView, tv.hasMarkedText() else { return }
            tv.unmarkText()
            model.textDidChange(tv.string, token: loadedToken)
        }

        func select(_ range: NSRange, center: Bool) {
            guard let tv = textView else { return }
            let len = (tv.string as NSString).length
            let r = NSRange(location: min(range.location, len), length: min(range.length, max(0, len - range.location)))
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(r)
            DispatchQueue.main.async { self.reveal(center: center) }
        }

        func focus() { DispatchQueue.main.async { [weak self] in self?.textView.map { $0.window?.makeFirstResponder($0) } } }

        func showFindBar() {
            guard let tv = textView else { return }
            tv.window?.makeFirstResponder(tv)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            tv.performTextFinderAction(item)
        }

        var caretLocation: Int { textView?.selectedRange().location ?? 0 }

        // MARK: Formatting (Markdown kept as typed: these only insert or remove marks)

        /// The text view, focused, with any composition committed — or nil when there's nothing to edit.
        var editable: ManuscriptTextView? {
            guard let tv = textView, tv.isEditable else { return nil }
            tv.window?.makeFirstResponder(tv)
            commitComposition()
            return tv
        }

        /// One undoable replacement, then the selection. Bypasses the typing conveniences (no pairs, no `...`).
        func replace(_ tv: NSTextView, _ range: NSRange, with text: String, select: NSRange) {
            tv.breakUndoCoalescing()
            if let mtv = tv as? ManuscriptTextView { mtv.rawInsert(text, replacementRange: range) } else { tv.insertText(text, replacementRange: range) }
            tv.breakUndoCoalescing()
            tv.setSelectedRange(select)
        }

        func format(_ f: TextFormat) {
            guard let tv = editable else { return }
            switch f {
            case .bold: toggleWrap(tv, "**")
            case .italic: toggleWrap(tv, "*")
            case .strike: toggleWrap(tv, "~~")
            case .heading(let n): setLinePrefix(tv, String(repeating: "#", count: n) + " ")
            case .body: setLinePrefix(tv, "")
            case .quote: toggleQuote(tv)
            case .sceneBreak:
                let ns = tv.string as NSString
                let sel = tv.selectedRange()
                let atLineStart = sel.location == 0 || ns.character(at: sel.location - 1) == 0x0A
                let text = (atLineStart ? "" : "\n") + "\n* * *\n\n"
                replace(tv, sel, with: text, select: NSRange(location: sel.location + (text as NSString).length, length: 0))
            }
        }

        /// `**word**` ↔ `word`: unwraps when the selection (or the marks just around it) is already wrapped.
        private func toggleWrap(_ tv: NSTextView, _ mark: String) {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let m = (mark as NSString).length
            let inner = ns.substring(with: sel)
            // Marks inside the selection: "**word**" selected.
            if sel.length >= 2 * m, inner.hasPrefix(mark), inner.hasSuffix(mark), !(mark == "*" && inner.hasPrefix("**") && !inner.hasPrefix("***")) {
                let bare = String(inner.dropFirst(mark.count).dropLast(mark.count))
                replace(tv, sel, with: bare, select: NSRange(location: sel.location, length: (bare as NSString).length))
                return
            }
            // Marks just outside it: "word" selected inside "**word**".
            if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
               ns.substring(with: NSRange(location: sel.location - m, length: m)) == mark,
               ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == mark {
                let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
                replace(tv, outer, with: inner, select: NSRange(location: outer.location, length: sel.length))
                return
            }
            replace(tv, sel, with: mark + inner + mark, select: NSRange(location: sel.location + m, length: sel.length))
        }

        /// Heading level or body for every line the selection touches; the same heading again turns it back to body.
        private func setLinePrefix(_ tv: NSTextView, _ prefix: String) {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let lines = ns.lineRange(for: sel)
            let block = ns.substring(with: lines)
            var parts = block.components(separatedBy: "\n")
            let trailing = parts.last == "" && parts.count > 1
            if trailing { parts.removeLast() }
            let strip = { (l: String) in l.replacingOccurrences(of: #"^#{1,6}[ \t]+"#, with: "", options: .regularExpression) }
            let same = !prefix.isEmpty && parts.allSatisfy { $0.hasPrefix(prefix) && !$0.hasPrefix(prefix.dropLast() + "#") }
            let out = parts.map { l in l.isEmpty && parts.count > 1 ? l : (same ? "" : prefix) + strip(l) }.joined(separator: "\n") + (trailing ? "\n" : "")
            let delta = (out as NSString).length - (block as NSString).length
            let caret = sel.length == 0 ? NSRange(location: max(lines.location, sel.location + delta), length: 0)
                                        : NSRange(location: lines.location, length: (out as NSString).length - (trailing ? 1 : 0))
            replace(tv, lines, with: out, select: caret)
        }

        private func toggleQuote(_ tv: NSTextView) {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let lines = ns.lineRange(for: sel)
            let block = ns.substring(with: lines)
            var parts = block.components(separatedBy: "\n")
            let trailing = parts.last == "" && parts.count > 1
            if trailing { parts.removeLast() }
            let quoted = parts.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("> ") }
            let out = parts.map { l in l.isEmpty ? l : quoted ? String(l.dropFirst(2)) : "> " + l }.joined(separator: "\n") + (trailing ? "\n" : "")
            let delta = (out as NSString).length - (block as NSString).length
            let caret = sel.length == 0 ? NSRange(location: max(lines.location, sel.location + delta), length: 0)
                                        : NSRange(location: lines.location, length: (out as NSString).length - (trailing ? 1 : 0))
            replace(tv, lines, with: out, select: caret)
        }

        /// A symbol at the caret; a pair (「」) wraps the selection, or leaves the caret between the two.
        func insert(_ text: String, wrapping close: String?) {
            guard let tv = editable else { return }
            let sel = tv.selectedRange()
            let inner = (tv.string as NSString).substring(with: sel)
            let open = (text as NSString).length
            if let close {
                replace(tv, sel, with: text + inner + close, select: NSRange(location: sel.location + open, length: sel.length))
            } else {
                replace(tv, sel, with: text, select: NSRange(location: sel.location + open, length: 0))
            }
        }

        /// The symbol menu, in the writer's order (Settings › Editor): 1–9 · 0 pick the first ten, arrows and Return the rest.
        func symbolMenu() -> NSMenu {
            let menu = NSMenu()
            for (i, s) in model.symbols.enumerated() {
                let item = NSMenuItem(title: s.menuTitle(s.name.map { model.t($0) }), action: #selector(pickSymbol(_:)), keyEquivalent: i < 10 ? String((i + 1) % 10) : "")
                item.keyEquivalentModifierMask = []
                item.target = self
                item.tag = i
                if i == 10 { menu.addItem(.separator()) }
                menu.addItem(item)
            }
            return menu
        }

        /// The symbol menu at the caret.
        func showSymbols() {
            guard let tv = editable else { return }
            let menu = symbolMenu()
            var at = NSPoint(x: tv.textContainerInset.width, y: tv.textContainerInset.height)
            if let rect = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil) as NSRect?, let w = tv.window, rect != .zero {
                let inView = tv.convert(w.convertFromScreen(rect), from: nil)
                at = NSPoint(x: inView.minX, y: inView.maxY + 4)
            }
            menu.popUp(positioning: nil, at: at, in: tv)
        }

        @objc private func pickSymbol(_ item: NSMenuItem) {
            guard model.symbols.indices.contains(item.tag) else { return }
            let s = model.symbols[item.tag]
            insert(s.text, wrapping: s.close)
        }

        func findNext(_ forward: Bool) {
            guard let tv = textView else { return }
            tv.window?.makeFirstResponder(tv)
            let item = NSMenuItem()
            item.tag = (forward ? NSTextFinder.Action.nextMatch : .previousMatch).rawValue
            tv.performTextFinderAction(item)
        }

        // MARK: Loading

        func load() {
            guard let tv = textView else { return }
            // Silence change callbacks first: ending a stale composition here must not write into the new sheet.
            loading = true
            if tv.hasMarkedText() { tv.unmarkText() }
            loadedToken = model.loadToken
            tv.conveniences.reset()
            names.close()
            card.close()
            tv.string = model.text
            tv.undoManager?.removeAllActions()
            tv.isEditable = !model.editorLocked && model.sheetId != nil
            restyle(NSRange(location: 0, length: (tv.string as NSString).length))
            loading = false
            let len = (tv.string as NSString).length
            let sel = model.pendingSelection ?? NSRange(location: min(model.caret(for: model.sheetId ?? "") ?? len, len), length: 0)
            model.pendingSelection = nil
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: min(sel.length, len - min(sel.location, len))))
            tv.window?.makeFirstResponder(tv)
            DispatchQueue.main.async { [weak self] in
                self?.reveal(center: true)
                self?.updateFocusDim(force: true)
                self?.marks.update(force: true)
            }
        }

        /// Fonts and paragraph styles follow the text-size, markup and spelling preferences.
        func configure(sizeClass: T.Layout.SizeClass, force: Bool) {
            guard let tv = textView else { return }
            let key = StyleKey(size: model.textSize, spacing: model.lineSpacing, width: model.lineWidth, markup: model.markup, sizeClass: sizeClass, spell: model.spellCheckActive,
                               readOnly: model.editorLocked, indent: model.firstLineIndent)
            tv.isEditable = !model.editorLocked && model.sheetId != nil
            tv.conveniences.options = ConvenienceOptions(pairs: model.autoPairs, ellipsis: model.ellipsis.replacement)
            if tv.isAutomaticTextReplacementEnabled != model.textReplacement { tv.isAutomaticTextReplacementEnabled = model.textReplacement }
            tv.padX = T.Layout.Editor.paddingX(sizeClass)
            tv.typewriter = model.typewriter
            card.updateTracking()
            tv.measure = (T.Layout.Editor.measure * model.lineWidth.scale).rounded()
            // Cheap and guarded: typewriter scrolling changes the room below the last line without a restyle.
            tv.updateInsets()
            guard force || key != style else { return }
            style = key
            tv.isContinuousSpellCheckingEnabled = key.spell
            tv.typingAttributes = Styles.base(model.textSize, model.lineSpacing, indent: key.indent)
            tv.setValue(NSAttributedString(string: "\(model.t(.sheetPlaceholderTitle))\n\(model.t(.sheetPlaceholderBody))",
                                           attributes: Styles.base(model.textSize, model.lineSpacing).merging([.foregroundColor: NSColor.token(T.Color.inkTertiary)]) { $1 }),
                        forKey: "placeholderAttributedString")
            if !isComposing { restyle(NSRange(location: 0, length: (tv.string as NSString).length)) }
        }

        // MARK: Changes

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !loading else { return }
            dirtyRange = dirtyRange.map { NSUnionRange($0, editedRange) } ?? editedRange
            marks.edited(editedRange, delta: delta, in: textStorage.string as NSString)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView, !loading, let storage = tv.textStorage else { return }
            // No copy of the text per keystroke: the model takes one when it needs it (save, counts).
            model.textDidChange(token: loadedToken) { Self.nativeCopy(storage.string as NSString) }
            names.textDidChange()
            if breakAfterChange { breakAfterChange = false; tv.breakUndoCoalescing() }
            scheduleStyle()
            schedulePauseBreak()
            DispatchQueue.main.async { [weak self] in self?.reveal(center: false) }
        }

        /// Undo per word: after a space, punctuation or line break (outside composition) the next typing starts a new undo step.
        private var breakAfterChange = false
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Drops, services, dictation…: any insert carrying \r (or U+2028/9) goes in as \n instead.
            if let s = replacementString, !textView.hasMarkedText(), s.normalizedNewlines != s {
                textView.insertText(s.normalizedNewlines, replacementRange: range)
                return false
            }
            if let s = replacementString, !textView.hasMarkedText(),
               s.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) }) {
                breakAfterChange = true
            }
            return true
        }

        /// Keys after the input method: the `@` list and the card get them first.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let shift = NSApp.currentEvent.map { $0.type == .keyDown && $0.modifierFlags.contains(.shift) } ?? false
            if names.doCommand(selector, shift: shift) { return true }
            return card.doCommand(selector)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if !loading { names.selectionChanged() }
            guard let tv = textView, !loading, !tv.hasMarkedText() else { return }
            model.rememberCaret(tv.selectedRange().location)
            updateFocusDim()
            // Typewriter centering follows the caret only: recentering under a mouse drag or a growing selection
            // would move the text away from the pointer / the end being extended.
            if model.typewriter, tv.selectedRange().length == 0, NSEvent.pressedMouseButtons == 0 {
                DispatchQueue.main.async { [weak self] in self?.reveal(center: false) }
            }
        }

        private func schedulePauseBreak() {
            pauseTask?.cancel()
            pauseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Wait.ms(1000))
                guard let self, !Task.isCancelled, let tv = textView, !tv.hasMarkedText() else { return }
                tv.breakUndoCoalescing()
            }
        }

        private func scheduleStyle() {
            styleTask?.cancel()
            styleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, let tv = textView else { return }
                if tv.hasMarkedText() { scheduleStyle(); return }
                if let r = dirtyRange { dirtyRange = nil; restyle(r) }
                updateFocusDim(force: true)
            }
        }

        // MARK: Styling (attributes only)

        /// A native Swift String in one bulk copy + transcode. A bridged NSString is walked through `characterAtIndex:`
        /// by every later scan (and `makeContiguousUTF8` on it copies one character at a time — ~10 ms at 120k).
        static func nativeCopy(_ ns: NSString) -> String {
            let n = ns.length
            guard n > 0 else { return "" }
            let buf = UnsafeMutableBufferPointer<unichar>.allocate(capacity: n)
            defer { buf.deallocate() }
            ns.getCharacters(buf.baseAddress!, range: NSRange(location: 0, length: n))
            return String(decoding: buf, as: UTF16.self)
        }

        private var styledAsEntry = false

        /// `--selftest-perf`: what a markup-mode or text-size change costs.
        func debugRestyleAll() { restyle(NSRange(location: 0, length: (textView?.string as NSString?)?.length ?? 0)) }

        private func restyle(_ range: NSRange) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let ns = storage.string as NSString
            let indent = model.firstLineIndent
            guard ns.length > 0 else { tv.typingAttributes = Styles.base(model.textSize, model.lineSpacing, indent: indent); return }
            let start = min(range.location, ns.length)
            var para = ns.paragraphRange(for: NSRange(location: start, length: min(range.length, ns.length - start)))
            // A sheet becoming (or no longer being) an entry restyles every line: its `## ` titles change look.
            let entry = Styles.entryFrontMatterEnd(ns) > 0
            if entry != styledAsEntry { styledAsEntry = entry; para = NSRange(location: 0, length: ns.length) }
            let selection = tv.selectedRanges
            storage.beginEditing()
            Styles.apply(to: storage, in: para, size: model.textSize, spacing: model.lineSpacing, markup: model.markup, indent: indent)
            storage.endEditing()
            tv.selectedRanges = selection
            // New characters take the style of the line the caret is on.
            let caret = min(tv.selectedRange().location, ns.length)
            let line = ns.paragraphRange(for: NSRange(location: caret, length: 0))
            let lineText = ns.substring(with: line)
            let heading = TextMetrics.isHeading(Substring(lineText))
            tv.typingAttributes = heading && entry && lineText.hasPrefix("## ") ? Styles.entrySection(model.textSize, model.lineSpacing)
                : heading ? Styles.heading(model.textSize, model.lineSpacing) : Styles.base(model.textSize, model.lineSpacing, indent: indent)
        }

        // MARK: Focus mode (rendering attributes: drawn on top, storage untouched)

        private var dimmed: NSRange?

        func updateFocusDim(force: Bool = false) {
            guard let tv = textView, let tlm = tv.textLayoutManager, let tcs = tlm.textContentManager as? NSTextContentStorage else { return }
            let ns = tv.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard model.focusMode, ns.length > 0 else {
                if dimmed != nil { tlm.removeRenderingAttribute(.foregroundColor, for: tlm.documentRange); dimmed = nil }
                return
            }
            if tv.hasMarkedText() { return }
            let caret = min(tv.selectedRange().location, ns.length)
            var keep = ns.paragraphRange(for: NSRange(location: caret, length: 0))
            if model.focusScope == .sentence {
                var found = keep
                ns.enumerateSubstrings(in: keep, options: .bySentences) { _, r, enclosing, stop in
                    if NSLocationInRange(caret, enclosing) || caret == NSMaxRange(enclosing) { found = r; stop.pointee = true }
                }
                keep = found
            }
            guard force || keep != dimmed else { return }
            dimmed = keep
            tlm.removeRenderingAttribute(.foregroundColor, for: tlm.documentRange)
            let dim = NSColor.token(T.Color.inkPrimary).withAlphaComponent(T.Opacity.focusDim)
            for r in [NSRange(location: 0, length: keep.location), NSRange(location: NSMaxRange(keep), length: full.length - NSMaxRange(keep))] where r.length > 0 {
                if let tr = Self.textRange(r, in: tcs) { tlm.addRenderingAttribute(.foregroundColor, value: dim, for: tr) }
            }
        }

        static func textRange(_ r: NSRange, in tcs: NSTextContentStorage) -> NSTextRange? {
            guard let s = tcs.location(tcs.documentRange.location, offsetBy: r.location),
                  let e = tcs.location(s, offsetBy: r.length) else { return nil }
            return NSTextRange(location: s, end: e)
        }

        // MARK: Scrolling

        /// Keep the caret line off the bottom edge (three lines of air), or centered with typewriter scrolling.
        func reveal(center: Bool) {
            guard let tv = textView, let scroll = tv.enclosingScrollView, let window = tv.window else { return }
            let screen = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
            guard screen != .zero else { return }
            let caret = tv.convert(window.convertFromScreen(screen), from: nil)
            let visible = scroll.documentVisibleRect
            let line = Styles.lineHeight(model.textSize, model.lineSpacing)
            var y: CGFloat?
            if center || model.typewriter {
                y = caret.midY - visible.height / (model.typewriter ? 2 : 3)
            } else if caret.maxY + line * 3 > visible.maxY {
                y = caret.maxY + line * 3 - visible.height
            } else if caret.minY < visible.minY {
                y = caret.minY - line
            }
            guard var target = y else { return }
            let maxY = max(0, tv.frame.height - visible.height + scroll.contentInsets.bottom)
            target = min(max(0, target), maxY)
            if abs(target - visible.minY) > 0.5 {
                scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: target))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    struct StyleKey: Equatable {
        var size: TextSize = .normal
        var spacing: LineSpacing = .normal
        var width: LineWidth = .normal
        var markup: MarkupMode = .dim
        var sizeClass: T.Layout.SizeClass = .large
        var spell = false
        var readOnly = false
        var indent = false
    }
}

/// Clicks on the empty page below the text (short sheets, the scroll-past room at the end) land in the text view:
/// the caret goes to the nearest position, and a drag from there selects.
final class ManuscriptScrollView: NSScrollView {
    override func mouseDown(with event: NSEvent) {
        guard let tv = documentView as? NSTextView else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(tv)
        tv.mouseDown(with: event)
    }

    /// The text view's context menu there too, not nothing.
    override func rightMouseDown(with event: NSEvent) {
        guard let tv = documentView as? NSTextView else { return super.rightMouseDown(with: event) }
        window?.makeFirstResponder(tv)
        tv.rightMouseDown(with: event)
    }
}

/// The text view itself: centered measure, room below the last line, plain-text pasteboard.
final class ManuscriptTextView: NSTextView {
    var padX: CGFloat = T.Layout.Editor.paddingX(.large)
    var typewriter = false
    /// Line length cap (editor.measure × the line-width preference).
    var measure: CGFloat = T.Layout.Editor.measure
    /// Pairs and `...` while typing (EditorConveniences.swift).
    let conveniences = EditorConveniences()

    /// Story bible hooks (NameCompletion.swift, EntryCardPresenter.swift); the coordinator owns them.
    weak var names: NameCompletion?
    weak var card: EntryCardPresenter?
    weak var marks: NameMarks?
    var bibleEntries: () -> [BibleEntry] = { [] }
    /// Last key input (typing or composing): hover cards stay away for a while after it.
    private(set) var lastTyped = Date.distantPast

    /// Committed input from the keyboard / input method. Composition (marked text) passes straight through.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        lastTyped = Date()
        card?.close()
        if let s = (string as? String) ?? (string as? NSAttributedString)?.string {
            if names?.willInsert(s, replacementRange: replacementRange) == true { return }
            if conveniences.insert(s, replacementRange: replacementRange, in: self) { return }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        lastTyped = Date()
        card?.close()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        if conveniences.deleteBackward(in: self) { return }
        super.deleteBackward(sender)
    }

    /// Inserts without the typing conveniences: formatting, symbols, paste and the conveniences' own changes.
    func rawInsert(_ string: Any, replacementRange: NSRange) { super.insertText(string, replacementRange: replacementRange) }
    func rawDeleteBackward() { super.deleteBackward(nil) }

    /// Runs `body` as an undo step of its own, apart from what this key press already registered (the typed character),
    /// so ⌘Z first takes back only the automatic change.
    func separateUndoStep(_ body: () -> Void) {
        breakUndoCoalescing()
        if let um = undoManager, um.groupsByEvent, um.groupingLevel == 1 {
            // The event's automatic group holds the typed character: close it and open the next one,
            // which AppKit closes at the end of the event as it would have closed its own.
            um.endUndoGrouping()
            um.beginUndoGrouping()
            body()
        } else if let um = undoManager {
            um.beginUndoGrouping()
            body()
            um.endUndoGrouping()
        } else {
            body()
        }
        breakUndoCoalescing()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    func updateInsets() {
        // The line stops at the chosen measure however wide the window gets; the rest is margin on both sides.
        let side = max(padX, (bounds.width - measure) / 2)
        if abs(textContainerInset.width - side) > 0.5 { textContainerInset = NSSize(width: side, height: T.Space.s300) }
        if let scroll = enclosingScrollView {
            // Let the last line scroll up to the comfortable band instead of sitting on the bottom edge.
            let bottom = (scroll.contentSize.height * (typewriter ? 0.5 : 0.4)).rounded()
            if abs(scroll.contentInsets.bottom - bottom) > 0.5 { scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0) }
        }
    }

    // Plain text only, both ways: HTML/RTF on the clipboard doubles blank lines on serial platforms.
    // Copy and cut write the string themselves: narrowing `writablePasteboardTypes` made the TextKit 2 view
    // write an empty clipboard.
    private var selectedPlainText: String {
        let ns = string as NSString
        return selectedRanges.map { ns.substring(with: $0.rangeValue) }.joined(separator: "\n")
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(selectedPlainText, forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0, isEditable else { return }
        copy(sender)
        breakUndoCoalescing()
        // `delete` removes every selected range (⌥-drag column selections too), as one undo step.
        delete(sender)
        breakUndoCoalescing()
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        var s = pb.string(forType: .string)
        if s == nil, let rtf = pb.data(forType: .rtf) { s = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string }
        if s == nil, let html = pb.data(forType: .html) { s = NSAttributedString(html: html, documentAttributes: nil)?.string }
        guard let text = s?.normalizedNewlines else { return super.paste(sender) }
        breakUndoCoalescing()
        rawInsert(text, replacementRange: selectedRange())
        breakUndoCoalescing()
    }

    /// Home / End / Page Up / Page Down move the caret (line start · line end · a page), with ⇧ extending the
    /// selection, instead of AppKit's scroll-only default: writers coming from Windows editors expect the caret to follow.
    static let caretKeys: [UInt16: (Selector, Selector)] = [
        115: (#selector(moveToBeginningOfLine(_:)), #selector(moveToBeginningOfLineAndModifySelection(_:))),
        119: (#selector(moveToEndOfLine(_:)), #selector(moveToEndOfLineAndModifySelection(_:))),
        116: (#selector(pageUp(_:)), #selector(pageUpAndModifySelection(_:))),
        121: (#selector(pageDown(_:)), #selector(pageDownAndModifySelection(_:))),
    ]

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        if !hasMarkedText(), flags.isEmpty || flags == .shift, let pair = Self.caretKeys[event.keyCode] {
            doCommand(by: flags == .shift ? pair.1 : pair.0)
            return
        }
        super.keyDown(with: event)
    }

    /// Esc, in order (spec §2): the input method's composition (it never reaches us while marked) → the `@` list →
    /// the card → focus mode / editor only (`onEscape`, true when it did something) → the standard word completion.
    var onEscape: (() -> Bool)?
    override func cancelOperation(_ sender: Any?) {
        if !hasMarkedText() {
            if let names, names.isOpen { names.close(); return }
            if card?.close() == true { return }
            if onEscape?() == true { return }
        }
        super.cancelOperation(sender)
    }

    /// ⌥Esc / F5: the story bible's names and aliases that start with the word first, the system's words after.
    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let system = super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index) ?? []
        let ns = string as NSString
        guard NSMaxRange(charRange) <= ns.length else { return system }
        let ours = NameMatcher.completions(ns.substring(with: charRange), in: bibleEntries())
        guard !ours.isEmpty else { return system }
        index.pointee = 0
        return ours + system.filter { !ours.contains($0) }
    }

    /// The word before the caret without a particle after it ("벼리에" → "벼리"), when only the bare word starts a name.
    override var rangeForUserCompletion: NSRange {
        let r = super.rangeForUserCompletion
        let ns = string as NSString
        guard r.location != NSNotFound, r.length > 1, NSMaxRange(r) <= ns.length else { return r }
        let entries = bibleEntries()
        guard !entries.isEmpty else { return r }
        let word = ns.substring(with: r)
        guard NameMatcher.completions(word, in: entries).isEmpty else { return r }
        for j in NameMatcher.josa where word.hasSuffix(j) && word.count > j.count {
            let stem = String(word.dropLast(j.count))
            if !NameMatcher.completions(stem, in: entries).isEmpty { return NSRange(location: r.location, length: (stem as NSString).length) }
        }
        return r
    }

    /// Force click on a name: its card. Anywhere else: the system's Look Up.
    override func quickLook(with event: NSEvent) {
        if let window, let card, card.show(at: characterIndex(for: window.convertPoint(toScreen: event.locationInWindow)), asked: true) { return }
        super.quickLook(with: event)
    }

    /// Story bible names underlined (Settings › Editor): drawn on top, the text and its attributes untouched.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        marks?.draw(in: self, dirtyRect: dirtyRect)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        card?.mouseMoved(event)
    }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }

    /// Drops are text: colors, fonts, rulers and images would only put stray attributes on a plain-text manuscript
    /// (a dropped color painted the selection until the next restyle).
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let text: Set<String> = [NSPasteboard.PasteboardType.string.rawValue, "NSStringPboardType", NSPasteboard.PasteboardType.rtf.rawValue,
                                 NSPasteboard.PasteboardType.rtfd.rawValue, NSPasteboard.PasteboardType.html.rawValue,
                                 NSPasteboard.PasteboardType.URL.rawValue, NSPasteboard.PasteboardType.fileURL.rawValue,
                                 "NSFilenamesPboardType", "Apple URL pasteboard type", "WebURLsWithTitlesPboardType"]
        return super.acceptableDragTypes.filter { text.contains($0.rawValue) }
    }

    /// The standard menu minus what breaks or means nothing in a plain-text manuscript:
    /// Font (font and color panels) and Layout Orientation (vertical text isn't supported).
    /// Items put on top of the context menu (story bible: make an entry from the selection, add a field).
    var extraMenuItems: (() -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        if let extra = extraMenuItems?(), !extra.isEmpty {
            for (i, item) in (extra + [.separator()]).enumerated() { menu.insertItem(item, at: i) }
        }
        let drop: Set<String> = ["orderFrontFontPanel:", "changeLayoutOrientation:"]
        for item in menu.items.reversed() {
            if let sub = item.submenu, sub.items.contains(where: { $0.action.map { drop.contains(NSStringFromSelector($0)) } ?? false }) {
                menu.removeItem(item)
            }
        }
        // No doubled or trailing separators left behind.
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        var i = menu.items.count - 1
        while i > 0 { if menu.items[i].isSeparatorItem && menu.items[i - 1].isSeparatorItem { menu.removeItem(at: i) }; i -= 1 }
        return menu
    }
}

/// Manuscript attributes from the editor tokens.
@MainActor
enum Styles {
    static func token(_ size: TextSize) -> TextStyleToken {
        switch size {
        case .small: T.Typography.editorSmall
        case .normal: T.Typography.editorBody
        case .large: T.Typography.editorLarge
        }
    }

    static func lineHeight(_ size: TextSize, _ spacing: LineSpacing = .normal) -> CGFloat { (token(size).lineHeight * spacing.scale).rounded() }

    private static func paragraph(lineHeight: CGFloat, indent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.firstLineHeadIndent = indent
        p.lineBreakMode = .byWordWrapping
        // Korean wraps at word boundaries like printed Korean; long unbroken runs still break.
        p.lineBreakStrategy = [.hangulWordPriority]
        return p
    }

    private static func attrs(_ t: TextStyleToken, scale: Double = 1, spacing: LineSpacing = .normal, indent: Bool = false) -> [NSAttributedString.Key: Any] {
        let base = Fonts.ns(t)
        let font = scale == 1 ? base : (NSFont(descriptor: base.fontDescriptor, size: (t.size * scale).rounded()) ?? base)
        let lineHeight = (t.lineHeight * scale * spacing.scale).rounded()
        let natural = font.ascender - font.descender
        return [
            .font: font,
            // First-line indent is 1 em, drawn only: the text itself never gets spaces.
            .paragraphStyle: paragraph(lineHeight: lineHeight, indent: indent ? font.pointSize : 0),
            .foregroundColor: NSColor.token(T.Color.inkPrimary),
            .baselineOffset: max(0, (lineHeight - natural) / 2),
            .kern: t.tracking * font.pointSize,
        ]
    }

    static func base(_ size: TextSize, _ spacing: LineSpacing = .normal, indent: Bool = false) -> [NSAttributedString.Key: Any] {
        attrs(token(size), spacing: spacing, indent: indent)
    }

    /// Headings scale with the chosen text size.
    static func heading(_ size: TextSize, _ spacing: LineSpacing = .normal) -> [NSAttributedString.Key: Any] {
        attrs(T.Typography.editorHeading, scale: token(size).size / T.Typography.editorBody.size, spacing: spacing)
    }

    private static let headingRe = try! NSRegularExpression(pattern: #"^(#{1,6})([ \t]+)"#, options: [.anchorsMatchLines])
    private static let listRe = try! NSRegularExpression(pattern: #"^[ \t]*([-*+>]|\d+\.)[ \t]+"#, options: [.anchorsMatchLines])
    /// Longer than any real word (Korean words run to about ten syllables).
    private static let longRunRe = try! NSRegularExpression(pattern: #"[^\s]{16,}"#)
    private static let emphasisRe = try! NSRegularExpression(pattern: #"(\*\*|__|\*|_|~~|`)(?=\S)(.+?)(?<=\S)\1"#)

    /// End of the front matter block (a `---` first line through the next `---` line, ADR-0010), or 0 when there is none.
    /// Only the first few dozen lines are looked at: a block is a handful of `key: value` lines.
    static func frontMatterEnd(_ ns: NSString) -> Int {
        func line(at i: Int) -> (NSRange, Bool) {
            let r = ns.lineRange(for: NSRange(location: i, length: 0))
            return (r, ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines) == "---")
        }
        guard ns.length >= 3, line(at: 0).1 else { return 0 }
        var at = NSMaxRange(line(at: 0).0)
        for _ in 0..<40 where at < ns.length {
            let (r, fence) = line(at: at)
            if fence { return NSMaxRange(r) }
            at = NSMaxRange(r)
        }
        return 0
    }

    static func apply(to storage: NSTextStorage, in range: NSRange, size: TextSize, spacing: LineSpacing = .normal, markup: MarkupMode, indent: Bool = false) {
        let ns = storage.string as NSString
        storage.setAttributes(base(size, spacing, indent: indent), range: range)
        let markColor: NSColor = switch markup {
        case .show: .token(T.Color.inkSecondary)
        case .dim: .token(T.Color.inkMarkup)
        case .hide: .clear
        }
        // Lines that aren't prose keep a flush first line: the front matter block, scene breaks (headings use their own style).
        let flat = indent ? base(size, spacing)[.paragraphStyle] : nil
        let frontMatter = indent ? frontMatterEnd(ns) : 0
        // Story bible entries (EntryStyles.swift): 0 for every other sheet.
        let entryEnd = entryFrontMatterEnd(ns)
        ns.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, line, enclosing, _ in
            if line.location < entryEnd {
                styleFrontMatterLine(storage, ns, line: enclosing, blockEnd: entryEnd, size: size, spacing: spacing)
                return
            }
            if let m = headingRe.firstMatch(in: storage.string, range: line) {
                if entryEnd > 0, isEntrySection(m.range(at: 1)) {
                    styleEntrySection(storage, line: line, marks: m.range(at: 1), size: size, spacing: spacing, markColor: markColor)
                    return
                }
                storage.setAttributes(heading(size, spacing), range: line)
                storage.addAttribute(.foregroundColor, value: markColor, range: NSRange(location: m.range.location, length: m.range(at: 1).length))
                return
            }
            if let m = listRe.firstMatch(in: storage.string, range: line) {
                // Line-start marks stay visible even in "hide": a dialogue dash ("- ") is part of the text.
                let lineMark: NSColor = markup == .hide ? .token(T.Color.inkMarkup) : markColor
                storage.addAttribute(.foregroundColor, value: lineMark, range: m.range(at: 1))
            }
            let sceneBreak = TextMetrics.isSceneBreak(Substring(ns.substring(with: line)))
            if sceneBreak {
                storage.addAttribute(.foregroundColor, value: NSColor.token(T.Color.inkTertiary), range: line)
            }
            if let flat, sceneBreak || line.location < frontMatter {
                storage.addAttribute(.paragraphStyle, value: flat, range: line)
            }
            // Word wrap keeps Korean words whole, but a long run typed without spaces is not a word: wrapped whole it
            // jumps to the next line and strands what came before (a space typed in front looked like a line break).
            // Such a paragraph breaks between syllables instead.
            if longRunRe.firstMatch(in: storage.string, range: line) != nil,
               let p = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                p.lineBreakStrategy = []
                storage.addAttribute(.paragraphStyle, value: p, range: enclosing)
            }
            for m in emphasisRe.matches(in: storage.string, range: line) {
                let mark = m.range(at: 1).length
                switch ns.substring(with: m.range(at: 1)) {
                case "**", "__": storage.addAttribute(.font, value: Fonts.ns(token(size), weight: 700), range: m.range)
                case "*", "_": storage.addAttribute(.obliqueness, value: 0.18, range: m.range)
                case "~~": storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
                default: break
                }
                storage.addAttribute(.foregroundColor, value: markColor, range: NSRange(location: m.range.location, length: mark))
                storage.addAttribute(.foregroundColor, value: markColor, range: NSRange(location: NSMaxRange(m.range) - mark, length: mark))
            }
        }
    }
}
