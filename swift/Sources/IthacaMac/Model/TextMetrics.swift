// Manuscript text helpers, ported from app-web/src/text.ts so live counts in the editor match the web app.
// The core computes the stored counts (SheetSummary.counts); the editor counts the unsaved buffer itself.
import Foundation

enum TextMetrics {
    /// Markdown marks that aren't prose: heading #, list/quote markers, emphasis.
    static func stripMarks(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"(?m)^[ \t]*(#{1,6}|[-*+>]|\d+\.)[ \t]+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(\*\*|__|\*|_|~~|`)(?=\S)(.+?)(?<=\S)\1"#, with: "$2", options: .regularExpression)
        return out
    }

    /// `* * *`, `---`, `＊＊＊` …: a scene break, never a paragraph.
    static func isSceneBreak(_ line: Substring) -> Bool {
        line.range(of: #"^\s*([-*_＊])(\s*\1){2,}\s*$"#, options: .regularExpression) != nil
    }

    static func isHeading(_ line: Substring) -> Bool {
        line.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil
    }

    static func title(_ body: String) -> String {
        let line = body.split(separator: "\n", omittingEmptySubsequences: true).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(line).replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func excerpt(_ body: String) -> String {
        let lines = body.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !isSceneBreak($0) }
        guard lines.count > 1 else { return "" }
        return stripMarks(String(lines[1])).trimmingCharacters(in: .whitespaces)
    }

    /// Graphemes, line breaks excluded (with spaces); without any whitespace (no spaces); words without Markdown marks.
    static func counts(_ body: String) -> Counts {
        var c = Counts()
        for ch in body {
            if ch == "\n" || ch == "\r\n" { continue }
            c.chars += 1
            if !ch.isWhitespace { c.charsNoSpace += 1 }
        }
        let stripped = stripMarks(body)
        stripped.enumerateSubstrings(in: stripped.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in c.words += 1 }
        c.paragraphs = body.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !isHeading($0) && !isSceneBreak($0) }.count
        return c
    }

    static func goalValue(_ c: Counts, _ basis: GoalBasis) -> Int {
        switch basis {
        case .withSpaces: c.chars
        case .withoutSpaces: c.charsNoSpace
        case .words: c.words
        // Platform bases need the core's counter: AppModel.goalValue. These are the nearest plain counts.
        case .munpia: c.chars
        case .novelpia: c.charsNoSpace
        }
    }

    /// 500 Korean characters or 230 English words per minute.
    static func readingMinutes(_ c: Counts, _ language: ManuscriptLanguage) -> Int {
        max(1, Int((Double(language == .ko ? c.charsNoSpace : c.words) / (language == .ko ? 500 : 230)).rounded()))
    }

    // MARK: Export (same rules as app-web Export.tsx; the core's export_text replaces this once it lands)

    static func render(_ body: String, title sheetTitle: String, _ o: ExportOptions) -> String {
        if o.markdown { return body.trimmingCharacters(in: .whitespacesAndNewlines) }
        var lines = body.components(separatedBy: "\n")
        // A leading "# Title" equal to the sheet title is the title, not body text.
        if let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           title(lines[i]) == sheetTitle {
            lines.remove(at: i)
            if o.includeTitle { lines.insert(sheetTitle, at: i) }
        }
        let paragraphs: [String] = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { l in
            if l.range(of: #"^\s*(?:(?:[*＊]\s*){3,}|(?:[-－]\s*){3,}|(?:[_＿]\s*){3,})$"#, options: .regularExpression) != nil { return "* * *" }
            var s = l
            if o.stripMarkdown {
                s = s.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                s = s.replacingOccurrences(of: #"^[-*>]\s+"#, with: "", options: .regularExpression)
                s = s.replacingOccurrences(of: #"(\*\*|__|\*|_|~~|`)(.+?)\1"#, with: "$2", options: .regularExpression)
            }
            let heading = l.range(of: #"^#+\s"#, options: .regularExpression) != nil
            return o.indent && !heading ? "\u{3000}" + s.drop(while: { $0 == " " || $0 == "\t" }) : s
        }
        return paragraphs.joined(separator: o.blankLine ? "\n\n" : "\n")
    }
}

extension String {
    /// Line endings as the core stores them (it turns CRLF / CR into \n on save): \r\n, \r, U+2028, U+2029 → \n.
    /// The editor holds only this form, so the saved text and the buffer compare equal and the save state never sticks.
    var normalizedNewlines: String {
        guard contains(where: { $0 == "\r\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) else { return self }
        return replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
    }
}
