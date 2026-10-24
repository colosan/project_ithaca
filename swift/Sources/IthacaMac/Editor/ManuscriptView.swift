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
        let scroll = NSScrollView()
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
        private var editable: ManuscriptTextView? {
            guard let tv = textView, tv.isEditable else { return nil }
            tv.window?.makeFirstResponder(tv)
            commitComposition()
            return tv
        }

        /// One undoable replacement, then the selection.
        private func replace(_ tv: NSTextView, _ range: NSRange, with text: String, select: NSRange) {
            tv.breakUndoCoalescing()
            tv.insertText(text, replacementRange: range)
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

        /// The symbol menu at the caret: 1–9 · 0 pick the first ten, arrows and Return the rest.
        func showSymbols() {
            guard let tv = editable else { return }
            let menu = NSMenu()
            for (i, s) in Symbols.all.enumerated() {
                let item = NSMenuItem(title: s.menuTitle(model.t(s.name)), action: #selector(pickSymbol(_:)), keyEquivalent: i < 10 ? String((i + 1) % 10) : "")
                item.keyEquivalentModifierMask = []
                item.target = self
                item.tag = i
                if i == 10 { menu.addItem(.separator()) }
                menu.addItem(item)
            }
            var at = NSPoint(x: tv.textContainerInset.width, y: tv.textContainerInset.height)
            if let rect = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil) as NSRect?, let w = tv.window, rect != .zero {
                let inView = tv.convert(w.convertFromScreen(rect), from: nil)
                at = NSPoint(x: inView.minX, y: inView.maxY + 4)
            }
            menu.popUp(positioning: nil, at: at, in: tv)
        }

        @objc private func pickSymbol(_ item: NSMenuItem) {
            let s = Symbols.all[item.tag]
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
            }
        }

        /// Fonts and paragraph styles follow the text-size, markup and spelling preferences.
        func configure(sizeClass: T.Layout.SizeClass, force: Bool) {
            guard let tv = textView else { return }
            let key = StyleKey(size: model.textSize, spacing: model.lineSpacing, width: model.lineWidth, markup: model.markup, sizeClass: sizeClass, spell: model.spellCheckActive, readOnly: model.editorLocked)
            tv.isEditable = !model.editorLocked && model.sheetId != nil
            tv.padX = T.Layout.Editor.paddingX(sizeClass)
            tv.typewriter = model.typewriter
            tv.measure = (T.Layout.Editor.measure * model.lineWidth.scale).rounded()
            guard force || key != style else { return }
            style = key
            tv.isContinuousSpellCheckingEnabled = key.spell
            tv.updateInsets()
            tv.typingAttributes = Styles.base(model.textSize, model.lineSpacing)
            tv.setValue(NSAttributedString(string: "\(model.t(.sheetPlaceholderTitle))\n\(model.t(.sheetPlaceholderBody))",
                                           attributes: Styles.base(model.textSize, model.lineSpacing).merging([.foregroundColor: NSColor.token(T.Color.inkTertiary)]) { $1 }),
                        forKey: "placeholderAttributedString")
            if !isComposing { restyle(NSRange(location: 0, length: (tv.string as NSString).length)) }
        }

        // MARK: Changes

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !loading else { return }
            dirtyRange = dirtyRange.map { NSUnionRange($0, editedRange) } ?? editedRange
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView, !loading, let storage = tv.textStorage else { return }
            // No copy of the text per keystroke: the model takes one when it needs it (save, counts).
            model.textDidChange(token: loadedToken) { Self.nativeCopy(storage.string as NSString) }
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

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView, !loading, !tv.hasMarkedText() else { return }
            model.rememberCaret(tv.selectedRange().location)
            updateFocusDim()
            if model.typewriter { DispatchQueue.main.async { [weak self] in self?.reveal(center: false) } }
        }

        private func schedulePauseBreak() {
            pauseTask?.cancel()
            pauseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1000))
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

        /// `--selftest-perf`: what a markup-mode or text-size change costs.
        func debugRestyleAll() { restyle(NSRange(location: 0, length: (textView?.string as NSString?)?.length ?? 0)) }

        private func restyle(_ range: NSRange) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let ns = storage.string as NSString
            guard ns.length > 0 else { tv.typingAttributes = Styles.base(model.textSize, model.lineSpacing); return }
            let start = min(range.location, ns.length)
            let para = ns.paragraphRange(for: NSRange(location: start, length: min(range.length, ns.length - start)))
            let selection = tv.selectedRanges
            storage.beginEditing()
            Styles.apply(to: storage, in: para, size: model.textSize, spacing: model.lineSpacing, markup: model.markup)
            storage.endEditing()
            tv.selectedRanges = selection
            // New characters take the style of the line the caret is on.
            let caret = min(tv.selectedRange().location, ns.length)
            let line = ns.paragraphRange(for: NSRange(location: caret, length: 0))
            let heading = TextMetrics.isHeading(Substring(ns.substring(with: line)))
            tv.typingAttributes = heading ? Styles.heading(model.textSize, model.lineSpacing) : Styles.base(model.textSize, model.lineSpacing)
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

        private static func textRange(_ r: NSRange, in tcs: NSTextContentStorage) -> NSTextRange? {
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
    }
}

/// The text view itself: centered measure, room below the last line, plain-text pasteboard.
final class ManuscriptTextView: NSTextView {
    var padX: CGFloat = T.Layout.Editor.paddingX(.large)
    var typewriter = false
    /// Line length cap (editor.measure × the line-width preference).
    var measure: CGFloat = T.Layout.Editor.measure

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
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        var s = pb.string(forType: .string)
        if s == nil, let rtf = pb.data(forType: .rtf) { s = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string }
        if s == nil, let html = pb.data(forType: .html) { s = NSAttributedString(html: html, documentAttributes: nil)?.string }
        guard let text = s?.normalizedNewlines else { return super.paste(sender) }
        breakUndoCoalescing()
        insertText(text, replacementRange: selectedRange())
        breakUndoCoalescing()
    }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
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

    private static func paragraph(lineHeight: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.lineBreakMode = .byWordWrapping
        // Korean wraps at word boundaries like printed Korean; long unbroken runs still break.
        p.lineBreakStrategy = [.hangulWordPriority]
        return p
    }

    private static func attrs(_ t: TextStyleToken, scale: Double = 1, spacing: LineSpacing = .normal) -> [NSAttributedString.Key: Any] {
        let base = Fonts.ns(t)
        let font = scale == 1 ? base : (NSFont(descriptor: base.fontDescriptor, size: (t.size * scale).rounded()) ?? base)
        let lineHeight = (t.lineHeight * scale * spacing.scale).rounded()
        let natural = font.ascender - font.descender
        return [
            .font: font,
            .paragraphStyle: paragraph(lineHeight: lineHeight),
            .foregroundColor: NSColor.token(T.Color.inkPrimary),
            .baselineOffset: max(0, (lineHeight - natural) / 2),
            .kern: t.tracking * font.pointSize,
        ]
    }

    static func base(_ size: TextSize, _ spacing: LineSpacing = .normal) -> [NSAttributedString.Key: Any] { attrs(token(size), spacing: spacing) }

    /// Headings scale with the chosen text size.
    static func heading(_ size: TextSize, _ spacing: LineSpacing = .normal) -> [NSAttributedString.Key: Any] {
        attrs(T.Typography.editorHeading, scale: token(size).size / T.Typography.editorBody.size, spacing: spacing)
    }

    private static let headingRe = try! NSRegularExpression(pattern: #"^(#{1,6})([ \t]+)"#, options: [.anchorsMatchLines])
    private static let listRe = try! NSRegularExpression(pattern: #"^[ \t]*([-*+>]|\d+\.)[ \t]+"#, options: [.anchorsMatchLines])
    private static let emphasisRe = try! NSRegularExpression(pattern: #"(\*\*|__|\*|_|~~|`)(?=\S)(.+?)(?<=\S)\1"#)

    static func apply(to storage: NSTextStorage, in range: NSRange, size: TextSize, spacing: LineSpacing = .normal, markup: MarkupMode) {
        let ns = storage.string as NSString
        storage.setAttributes(base(size, spacing), range: range)
        let markColor: NSColor = switch markup {
        case .show: .token(T.Color.inkSecondary)
        case .dim: .token(T.Color.inkMarkup)
        case .hide: .clear
        }
        ns.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
            if let m = headingRe.firstMatch(in: storage.string, range: line) {
                storage.setAttributes(heading(size, spacing), range: line)
                storage.addAttribute(.foregroundColor, value: markColor, range: NSRange(location: m.range.location, length: m.range(at: 1).length))
                return
            }
            if let m = listRe.firstMatch(in: storage.string, range: line) {
                storage.addAttribute(.foregroundColor, value: markColor, range: m.range(at: 1))
            }
            if TextMetrics.isSceneBreak(Substring(ns.substring(with: line))) {
                storage.addAttribute(.foregroundColor, value: NSColor.token(T.Color.inkTertiary), range: line)
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

/// Symbols web-novel writers type often: the first ten are on 1–9 · 0 in the symbol menu (⌘/).
struct Symbol {
    let text: String
    var close: String? = nil
    let name: L10nKey
    func menuTitle(_ label: String) -> String { "\(text)\(close ?? "")    \(label)" }
}

enum Symbols {
    static let all: [Symbol] = [
        Symbol(text: "…", name: .symbolEllipsis),
        Symbol(text: "「", close: "」", name: .symbolCornerBracket),
        Symbol(text: "『", close: "』", name: .symbolDoubleCornerBracket),
        Symbol(text: "\u{201C}", close: "\u{201D}", name: .symbolDoubleQuote),
        Symbol(text: "\u{2018}", close: "\u{2019}", name: .symbolSingleQuote),
        Symbol(text: "―", name: .symbolDash),
        Symbol(text: "·", name: .symbolMiddleDot),
        Symbol(text: "※", name: .symbolReference),
        Symbol(text: "♡", name: .symbolHeart),
        Symbol(text: "★", name: .symbolStar),
        Symbol(text: "《", close: "》", name: .symbolDoubleAngle),
        Symbol(text: "〈", close: "〉", name: .symbolAngle),
        Symbol(text: "【", close: "】", name: .symbolLenticular),
        Symbol(text: "♥", name: .symbolHeartFilled),
        Symbol(text: "☆", name: .symbolStarOutline),
        Symbol(text: "♪", name: .symbolNote),
        Symbol(text: "～", name: .symbolTilde),
        Symbol(text: "→", name: .symbolArrow),
        Symbol(text: "×", name: .symbolTimes),
        Symbol(text: "○", name: .symbolCircle),
        Symbol(text: "●", name: .symbolCircleFilled),
        Symbol(text: "◆", name: .symbolDiamond),
        Symbol(text: "■", name: .symbolSquare),
        Symbol(text: "▶", name: .symbolTriangle),
    ]
}
