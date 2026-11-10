// The author's note field (app-shell spec, manuscripts and blank pages; ADR-0012): a manuscript shows its note in a
// field of its own under the text — a hairline, a small label and a text view of its own, no box — never as a heading
// in the manuscript. The stored text does not change: the body, then the note heading line, then the note
// (`TextMetrics.noteParts` / `joinNote`). Blank pages and story bible entries have no field and show their text as is.
//
// The field is a subview of the manuscript text view, in room kept free below the last line: the text view's bottom
// inset grows by that room (`ManuscriptTextView.noteRoom`), and the field sits at its top, just below the last line.
// It moves again whenever the text view's frame changes, so it follows TextKit's layout and scrolls with the manuscript.
import AppKit
import IthacaDesign
import SwiftUI

/// The note's own text view: plain text both ways, its own undo stack, ↑ on the first line back to the manuscript.
final class NoteTextView: NSTextView {
    var onUpFromTop: (() -> Void)?
    private let undo = UndoManager()
    override var undoManager: UndoManager? { undo }

    override func moveUp(_ sender: Any?) {
        let atTop = selectedRange() == NSRange(location: 0, length: 0)
        super.moveUp(sender)
        if atTop { onUpFromTop?() }
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((string as NSString).substring(with: selectedRange()), forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0, isEditable else { return }
        copy(sender)
        delete(sender)
    }

    override func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string)?.normalizedNewlines else { return super.paste(sender) }
        breakUndoCoalescing()
        insertText(s, replacementRange: selectedRange())
        breakUndoCoalescing()
    }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
}

@MainActor
final class AuthorNoteField: NSView, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    /// Room between the manuscript and the field, in lines.
    static let gapLines: CGFloat = 2
    private static let labelGap = T.Space.s150, textGap = T.Space.s50

    unowned let coordinator: ManuscriptView.Coordinator
    let textView = NoteTextView(usingTextLayoutManager: true)
    private let label = NSTextField(labelWithString: "")
    private var styleTask: Task<Void, Never>?
    private var pending = false

    override var isFlipped: Bool { true }

    init(coordinator: ManuscriptView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        let tv = textView
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.insertionPointColor = .token(T.Color.accentPrimary)
        tv.delegate = self
        tv.textStorage?.delegate = self
        tv.onUpFromTop = { [weak coordinator] in coordinator?.focusBodyEnd() }
        label.font = Fonts.ns(T.Typography.caption)
        label.textColor = .token(T.Color.inkTertiary)
        addSubview(label)
        addSubview(tv)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var text: String { textView.string }
    var isComposing: Bool { textView.hasMarkedText() }
    var hasFocus: Bool { window?.firstResponder === textView }

    /// A sheet loaded: the note's text (nil hides the field: not a manuscript).
    func load(_ note: String?) {
        let model = coordinator.model
        guard let note else {
            textView.string = ""
            show(false)
            return
        }
        if textView.hasMarkedText() { textView.unmarkText() }
        label.stringValue = model.t(.noteTitle)
        textView.setAccessibilityLabel(model.t(.noteTitle))
        textView.string = note
        textView.undoManager?.removeAllActions()
        configure()
        restyle()
        show(true)
    }

    /// A turn later: loads run inside a SwiftUI update, and changing views there sent SwiftUI round in a cycle.
    private func show(_ shown: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isHidden == shown { isHidden = !shown }
            relayout()
        }
    }

    /// Text size, line spacing, markup look and read-only follow the manuscript.
    func configure() {
        let model = coordinator.model
        textView.isEditable = coordinator.textView?.isEditable ?? false
        textView.isContinuousSpellCheckingEnabled = model.spellCheckActive
        textView.typingAttributes = Styles.base(model.textSize, model.lineSpacing)
        textView.setValue(NSAttributedString(string: model.t(.notePlaceholder),
                                             attributes: Styles.base(model.textSize, model.lineSpacing).merging([.foregroundColor: NSColor.token(T.Color.inkTertiary)]) { $1 }),
                          forKey: "placeholderAttributedString")
        restyle()
        setNeedsRelayout()
    }

    /// Markdown marks dimmed as in the manuscript; attributes only, never while composing.
    private func restyle() {
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        let model = coordinator.model
        let selection = textView.selectedRanges
        storage.beginEditing()
        Styles.apply(to: storage, in: NSRange(location: 0, length: storage.length), size: model.textSize, spacing: model.lineSpacing, markup: model.markup)
        storage.endEditing()
        textView.selectedRanges = selection
        textView.typingAttributes = Styles.base(model.textSize, model.lineSpacing)
    }

    func focus(at location: Int) {
        guard !isHidden else { return }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: min(location, (textView.string as NSString).length), length: 0))
        DispatchQueue.main.async { [weak self] in self?.revealCaret() }
    }

    func select(_ range: NSRange) {
        let len = (textView.string as NSString).length
        let at = min(range.location, len)
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: at, length: min(range.length, len - at)))
        DispatchQueue.main.async { [weak self] in self?.revealCaret() }
    }

    private func revealCaret() {
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    // MARK: Changes

    /// Every change of the note's characters, undo included (undo posts no text-did-change).
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        coordinator.noteDidChange()
        setNeedsRelayout()
    }

    func textDidChange(_ notification: Notification) {
        relayout()
        styleTask?.cancel()
        styleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            if textView.hasMarkedText() { return }
            restyle()
        }
        DispatchQueue.main.async { [weak self] in self?.revealCaret() }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if let s = replacementString, !textView.hasMarkedText(), s.normalizedNewlines != s {
            textView.insertText(s.normalizedNewlines, replacementRange: range)
            return false
        }
        return true
    }

    // MARK: Layout

    /// After a frame change of the manuscript: its layout settles first.
    func setNeedsRelayout() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.relayout()
        }
    }

    /// Sizes the field to its text and puts it below the manuscript's last line, at the foot of the page when the text is short.
    func relayout() {
        guard let host = coordinator.textView else { return }
        guard !isHidden else {
            host.noteRoom = 0
            host.pageHeight = 0
            return
        }
        let model = coordinator.model
        let width = max(0, host.bounds.width - 2 * host.textContainerInset.width)
        let labelSize = label.fittingSize
        // The text's own height (one line at least, for the placeholder).
        if abs(textView.frame.width - width) > 0.5 { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
        var textHeight = Styles.lineHeight(model.textSize, model.lineSpacing)
        if let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            textHeight = max(textHeight, tlm.usageBoundsForTextContainer.height.rounded(.up))
        }
        // Hairline at the top, the label under it, then the text — lined up with the manuscript's left edge.
        // (A label cell draws its text 2 pt in from its frame.)
        let labelY = T.Size.strokeHairline + Self.labelGap
        let textY = labelY + labelSize.height + Self.textGap
        let height = textY + textHeight
        label.frame = NSRect(x: -2, y: labelY, width: labelSize.width, height: labelSize.height)
        textView.frame = NSRect(x: 0, y: textY, width: width, height: textHeight)
        let gap = (Styles.lineHeight(model.textSize, model.lineSpacing) * Self.gapLines).rounded()
        // Below the last line laid out (the text view can be taller than its text: it fills the visible page).
        var used = host.textLayoutManager?.usageBoundsForTextContainer.maxY ?? 0
        // An empty sheet shows its two-line hint (more when wrapped): the note goes below that.
        if host.string.isEmpty, host.hint != nil { used = max(used, host.hintRect.maxY - host.textContainerOrigin.y) }
        let top = ManuscriptTextView.topInset
        let bottom = host.textContainerOrigin.y + used
        // A short manuscript leaves the note at the foot of the page, not stuck under its last line or the placeholder
        // (0.11.1): the room below the text grows to fill the page. A longer one pushes the note down; it follows the text.
        host.noteRoom = gap + height
        let page = host.enclosingScrollView?.contentSize.height ?? 0
        host.pageHeight = page
        let y = max(bottom + gap, page - top - height)
        let frame = NSRect(x: host.textContainerOrigin.x, y: y, width: width, height: height).integral
        if self.frame != frame { self.frame = frame }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.token(T.Color.lineSubtle).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: T.Size.strokeHairline).fill()
    }

    /// A click on the label or the room around it: into the note, at its end.
    override func mouseDown(with event: NSEvent) {
        focus(at: (textView.string as NSString).length)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

extension ManuscriptView.Coordinator {
    /// Rewrite's "bring the original over": the manuscript replaced as one undo step; the note field is left alone.
    func replaceBody(with text: String) {
        guard let tv = textView, tv.isEditable else { return }
        tv.window?.makeFirstResponder(tv)
        commitComposition()
        replace(tv, NSRange(location: 0, length: (tv.string as NSString).length), with: text, select: NSRange(location: 0, length: 0))
        DispatchQueue.main.async { [weak self] in self?.reveal(center: true) }
    }

    /// ↑ from the note's first line: back to the end of the manuscript.
    func focusBodyEnd() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        DispatchQueue.main.async { [weak self] in self?.reveal(center: false) }
    }
}
