// The author's note in the editor (app-shell spec, manuscripts and blank pages; ADR-0012): the note heading line and
// everything after it sit in a soft box below the manuscript, the heading small like a label, the note in ink.secondary,
// a copy button on the heading line. A manuscript sheet without a note shows an add button under its last line: it
// appends the heading (one undo step) and puts the caret below it. The text stays as typed — the box is drawn behind
// it, the buttons float in the clip view (the add button sits in the scroll-past room under the text view).
import AppKit
import IthacaDesign
import SwiftUI

extension Styles {
    /// The note's text (also the typing attributes there): body size, ink.secondary, never the first-line indent.
    static func note(_ size: TextSize, _ spacing: LineSpacing = .normal) -> [NSAttributedString.Key: Any] {
        var a = base(size, spacing)
        a[.foregroundColor] = NSColor.token(T.Color.inkSecondary)
        return a
    }

    /// One line of the note (`line` without its break). The heading gets the label look and room above for the box.
    static func styleNoteLine(_ storage: NSTextStorage, _ ns: NSString, line: NSRange, heading: Bool, size: TextSize, spacing: LineSpacing, markColor: NSColor) {
        guard heading else {
            storage.setAttributes(note(size, spacing), range: line)
            return
        }
        var a = entrySection(size, spacing)
        if let p = (a[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            p.paragraphSpacingBefore = (lineHeight(size, spacing) * AuthorNoteBox.gapLines).rounded()
            a[.paragraphStyle] = p
        }
        storage.setAttributes(a, range: line)
        let marks = (ns.substring(with: line) as NSString).range(of: #"^#{1,6}"#, options: .regularExpression)
        if marks.location != NSNotFound { storage.addAttribute(.foregroundColor, value: markColor, range: NSRange(location: line.location, length: marks.length)) }
    }
}

@MainActor
final class AuthorNoteBox {
    /// Room between the manuscript and the box, in lines.
    static let gapLines: CGFloat = 1.5
    private static let padX = T.Space.s200, padY = T.Space.s150

    unowned let coordinator: ManuscriptView.Coordinator
    /// UTF-16 location of the heading line, nil without a note.
    private(set) var start: Int?
    private var pending = false

    private lazy var copyButton = host(KitButton(coordinator.model.t(.noteCopy), icon: .copy, variant: .ghost) { [weak self] in
        self?.coordinator.model.copyAuthorNote()
    })
    private lazy var addButton = host(KitButton(coordinator.model.t(.noteAdd), icon: .add, variant: .ghost) { [weak self] in
        self?.coordinator.addAuthorNote()
    })

    init(coordinator: ManuscriptView.Coordinator) { self.coordinator = coordinator }

    private func host(_ button: some View) -> NSHostingView<AnyView> {
        let v = NSHostingView(rootView: AnyView(button.fixedSize()))
        v.sizingOptions = [.intrinsicContentSize]
        v.isHidden = true
        return v
    }

    /// After a frame change: layout settles first.
    func setNeedsUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.update()
        }
    }

    /// Where the note starts, which button shows and where: after load, each restyle, frame and model changes.
    func update() {
        guard let tv = coordinator.textView, let clip = tv.enclosingScrollView?.contentView else { return }
        let model = coordinator.model
        let ns = tv.string as NSString
        let newStart = TextMetrics.noteStart(ns, from: Styles.entryFrontMatterEnd(ns))
        if newStart != start { start = newStart; tv.needsDisplay = true }
        for b in [copyButton, addButton] where b.superview !== clip { clip.addSubview(b) }
        let manuscript = model.sheet?.episode != nil && model.openEntry == nil
        let editable = tv.isEditable && !model.editorLocked
        // Copy: on the heading line, right edge of the box.
        if let start, let head = lineRect(start, in: tv) {
            let size = copyButton.fittingSize
            let x = tv.textContainerOrigin.x + textWidth(tv) + Self.padX / 2 - size.width
            place(copyButton, NSRect(x: x, y: head.midY - size.height / 2, width: size.width, height: size.height), from: tv, in: clip)
        } else {
            copyButton.isHidden = true
        }
        // Add: a manuscript sheet without a note, under its last line.
        if start == nil, manuscript, editable, let tlm = tv.textLayoutManager {
            let size = addButton.fittingSize
            let bottom = tv.textContainerOrigin.y + max(tlm.usageBoundsForTextContainer.maxY, 0)
            let y = bottom + (Styles.lineHeight(model.textSize, model.lineSpacing) * 0.75).rounded()
            // The ghost button's own padding lines its label up with the text.
            place(addButton, NSRect(x: tv.textContainerOrigin.x - T.Space.s150, y: y, width: size.width, height: size.height), from: tv, in: clip)
        } else {
            addButton.isHidden = true
        }
    }

    private func place(_ v: NSView, _ rect: NSRect, from tv: NSTextView, in clip: NSClipView) {
        let r = tv.convert(rect, to: clip).integral
        if v.frame != r { v.frame = r }
        v.isHidden = false
    }

    private func textWidth(_ tv: NSTextView) -> CGFloat { max(0, tv.bounds.width - 2 * tv.textContainerInset.width) }

    /// The first line fragment of the paragraph at `location`, in the text view's coordinates.
    private func lineRect(_ location: Int, in tv: NSTextView) -> NSRect? {
        guard let tlm = tv.textLayoutManager, let tcs = tlm.textContentManager as? NSTextContentStorage,
              let tr = ManuscriptView.Coordinator.textRange(NSRange(location: location, length: 0), in: tcs) else { return nil }
        tlm.ensureLayout(for: tr)
        var found: NSRect?
        tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, rect, _, _ in
            found = rect
            return false
        }
        guard let rect = found else { return nil }
        let o = tv.textContainerOrigin
        // The segment of an empty range is the caret's: use the line's full height from the fragment instead.
        let frag = tlm.textLayoutFragment(for: tr.location)
        let line = frag?.textLineFragments.first.map { $0.typographicBounds.offsetBy(dx: frag!.layoutFragmentFrame.minX, dy: frag!.layoutFragmentFrame.minY) }
        let r = line ?? rect
        return NSRect(x: o.x + r.minX, y: o.y + r.minY, width: r.width, height: r.height)
    }

    /// The box: from just above the heading to below the last line, the text width plus a margin on each side.
    func boxRect(in tv: NSTextView) -> NSRect? {
        guard let start, let tlm = tv.textLayoutManager, let head = lineRect(start, in: tv) else { return nil }
        let o = tv.textContainerOrigin
        let bottom = max(o.y + tlm.usageBoundsForTextContainer.maxY, head.maxY)
        return NSRect(x: o.x - Self.padX, y: head.minY - Self.padY, width: textWidth(tv) + 2 * Self.padX, height: bottom - head.minY + 2 * Self.padY)
    }

    func drawBackground(in tv: NSTextView, dirtyRect: NSRect) {
        guard let box = boxRect(in: tv), box.intersects(dirtyRect) else { return }
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: T.Radius.control, yRadius: T.Radius.control)
        NSColor.token(T.Color.surfaceList).setFill()
        path.fill()
        NSColor.token(T.Color.lineSubtle).setStroke()
        path.lineWidth = T.Size.strokeHairline
        path.stroke()
    }

    // Self-test.
    var debugCopyVisible: Bool { !copyButton.isHidden }
    var debugAddVisible: Bool { !addButton.isHidden }
    func debugAdd() { coordinator.addAuthorNote() }
}

extension ManuscriptView.Coordinator {
    /// the add-note button: the heading after the manuscript (a blank line between), the caret on the line below. One undo step.
    func addAuthorNote() {
        guard let tv = editable else { return }
        let ns = tv.string as NSString
        var end = ns.length
        while end > 0, ns.character(at: end - 1) == 0x0A { end -= 1 }
        let lead = end == 0 ? "" : "\n\n"
        let text = lead + "## " + model.t(.noteTitle) + "\n"
        let range = NSRange(location: end, length: ns.length - end)
        replace(tv, range, with: text, select: NSRange(location: end + (text as NSString).length, length: 0))
        DispatchQueue.main.async { [weak self] in self?.reveal(center: false) }
    }
}
