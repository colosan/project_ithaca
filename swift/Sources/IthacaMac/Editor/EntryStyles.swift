// How a story bible entry looks in the editor (design/screens/story-bible §1): attributes only, the text stays as typed.
// - Front matter: the `---` fences dim (ink.markup), `key:` a small bold label in ink.tertiary, the value in body ink,
//   a little room after the block.
// - `## ` section titles read as field labels: marks dim, the title small and bold in ink.secondary, room above.
// Only for texts the core parses as entries; plain sheets (a `---` scene break first) are untouched.
import AppKit
import IthacaCore
import IthacaDesign

extension Styles {
    /// Labels (front matter keys, section titles) against the manuscript size.
    static let entryLabelScale = 0.85

    /// End of the front matter when the text is an entry (its `종류` / `kind` is known), else 0.
    /// Cheap: only the block itself goes to the core, never the whole sheet.
    static func entryFrontMatterEnd(_ ns: NSString) -> Int {
        let end = frontMatterEnd(ns)
        guard end > 0, IthacaCore.parseEntry(text: ns.substring(to: end)) != nil else { return 0 }
        return end
    }

    private static func labelFont(_ size: TextSize) -> NSFont {
        let t = token(size)
        let bold = Fonts.ns(t, weight: T.Typography.heading.weight)
        return NSFont(descriptor: bold.fontDescriptor, size: (t.size * entryLabelScale).rounded()) ?? bold
    }

    /// The body paragraph style (never the first-line indent) with extra room before / after.
    private static func flatParagraph(_ size: TextSize, _ spacing: LineSpacing, before: CGFloat = 0, after: CGFloat = 0) -> NSParagraphStyle {
        let p = ((base(size, spacing)[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        return p
    }

    /// One line of an entry's front matter (`line` from the paragraph enumeration, its break included).
    static func styleFrontMatterLine(_ storage: NSTextStorage, _ ns: NSString, line: NSRange, blockEnd: Int, size: TextSize, spacing: LineSpacing) {
        let text = ns.substring(with: line)
        let room = (lineHeight(size, spacing) * 0.5).rounded()
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            storage.addAttribute(.foregroundColor, value: NSColor.token(T.Color.inkMarkup), range: line)
            // The closing fence: some air before the name.
            let closing = NSMaxRange(line) >= blockEnd
            storage.addAttribute(.paragraphStyle, value: flatParagraph(size, spacing, after: closing ? room : 0), range: line)
            return
        }
        storage.addAttribute(.paragraphStyle, value: flatParagraph(size, spacing), range: line)
        let colon = (text as NSString).rangeOfCharacter(from: CharacterSet(charactersIn: ":："))
        guard colon.location != NSNotFound else { return }
        let key = NSRange(location: line.location, length: colon.location + colon.length)
        storage.addAttribute(.font, value: labelFont(size), range: key)
        storage.addAttribute(.foregroundColor, value: NSColor.token(T.Color.inkTertiary), range: key)
    }

    /// Attributes of an entry's `## ` line (also the typing attributes there).
    static func entrySection(_ size: TextSize, _ spacing: LineSpacing = .normal) -> [NSAttributedString.Key: Any] {
        var a = base(size, spacing)
        a[.font] = labelFont(size)
        a[.foregroundColor] = NSColor.token(T.Color.inkSecondary)
        a[.paragraphStyle] = flatParagraph(size, spacing, before: (lineHeight(size, spacing) * 0.25).rounded())
        return a
    }

    /// An entry's `## title` line: the label look, the `##` marks in the markup color.
    static func styleEntrySection(_ storage: NSTextStorage, line: NSRange, marks: NSRange, size: TextSize, spacing: LineSpacing, markColor: NSColor) {
        storage.setAttributes(entrySection(size, spacing), range: line)
        storage.addAttribute(.foregroundColor, value: markColor, range: marks)
    }

    /// `## ` exactly (the core's section rule), not `#` or `###`.
    static func isEntrySection(_ marks: NSRange) -> Bool { marks.length == 2 }
}
