// Editor conveniences (design/screens/story-bible/spec.md §7): quote / bracket pairs, `...` → `…`, and the writer's
// own ⌘/ symbol list. First-line indent is drawing only (Styles.apply); system text replacement is a text-view flag.
//
// IME rules (same as ManuscriptView):
// - Nothing happens while there is marked text: a Korean syllable being composed is never touched. Only committed,
//   single-character input with no replacement elsewhere (the keyboard typing at the caret) is looked at.
// - Every automatic change is its own undo step after the typed character, so ⌘Z first gives back exactly what was typed.
// - Characters only change through insertText (never layoutManager, never storage behind the view's back).
import AppKit
import IthacaDesign

/// What the text view does on its own while typing (from the preferences, set in `Coordinator.configure`).
struct ConvenienceOptions: Equatable {
    var pairs = false
    /// `...` becomes this; nil leaves it alone.
    var ellipsis: String?
}

@MainActor
final class EditorConveniences {
    var options = ConvenienceOptions()

    /// Pairs closed automatically, innermost last: where the opener sits and the closer put after it.
    private struct Armed { var open: Int; var opener: String; var close: String }
    private var armed: [Armed] = []

    static let pairs: [String: String] = [
        "\"": "\"", "\u{201C}": "\u{201D}", "「": "」", "『": "』", "(": ")", "[": "]", "《": "》", "〈": "〉", "【": "】",
    ]
    private static let closers = Set(pairs.values)

    /// A new text was loaded: nothing typed before it is still open.
    func reset() { armed.removeAll() }

    /// Typed input reaching `insertText`. Returns true when it was handled here (the view must not insert it again).
    func insert(_ s: String, replacementRange: NSRange, in tv: ManuscriptTextView) -> Bool {
        guard options.pairs || options.ellipsis != nil, !tv.hasMarkedText(), tv.selectedRanges.count == 1, (s as NSString).length == 1 else { return false }
        let sel = tv.selectedRange()
        // Modeless input sources rewrite the previous character through a replacement range: never ours to change.
        guard replacementRange.location == NSNotFound || replacementRange == sel else { return false }
        let ns = tv.string as NSString
        if options.pairs {
            // The closer of a pair we closed, typed right before it: step over instead of doubling it.
            if sel.length == 0, let i = armed.lastIndex(where: { $0.close == s }), isIntact(armed[i], caret: sel.location, ns) {
                armed.removeSubrange(i...)
                tv.setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return true
            }
            if let close = Self.pairs[s] {
                if sel.length > 0 {
                    // Wrap the selection: one step, so ⌘Z gives the selected text back as it was.
                    let inner = ns.substring(with: sel)
                    tv.separateUndoStep { tv.rawInsert(s + inner + close, replacementRange: sel) }
                    tv.setSelectedRange(NSRange(location: sel.location + 1, length: sel.length))
                    return true
                }
                if shouldClose(s, at: sel.location, ns) {
                    tv.rawInsert(s, replacementRange: replacementRange)
                    let caret = sel.location + 1
                    tv.separateUndoStep { tv.rawInsert(close, replacementRange: NSRange(location: caret, length: 0)) }
                    tv.setSelectedRange(NSRange(location: caret, length: 0))
                    armed.append(Armed(open: sel.location, opener: s, close: close))
                    if armed.count > 16 { armed.removeFirst() }
                    return true
                }
            }
        }
        if s == ".", let rep = options.ellipsis, sel.length == 0, sel.location >= 2,
           ns.substring(with: NSRange(location: sel.location - 2, length: 2)) == "..",
           sel.location == 2 || ns.character(at: sel.location - 3) != 0x2E {
            tv.rawInsert(s, replacementRange: replacementRange)
            let dots = NSRange(location: sel.location - 2, length: 3)
            tv.separateUndoStep { tv.rawInsert(rep, replacementRange: dots) }
            tv.setSelectedRange(NSRange(location: dots.location + (rep as NSString).length, length: 0))
            return true
        }
        return false
    }

    /// Backspace right after an opener we closed, with nothing between: the closer goes too (its own undo step).
    func deleteBackward(in tv: ManuscriptTextView) -> Bool {
        guard options.pairs, !tv.hasMarkedText(), tv.selectedRanges.count == 1 else { return false }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        guard sel.length == 0, sel.location > 0, let last = armed.last, last.open == sel.location - 1, isIntact(last, caret: sel.location, ns) else { return false }
        armed.removeLast()
        tv.rawDeleteBackward()
        let closer = NSRange(location: sel.location - 1, length: (last.close as NSString).length)
        tv.separateUndoStep { tv.rawInsert("", replacementRange: closer) }
        tv.setSelectedRange(NSRange(location: closer.location, length: 0))
        return true
    }

    /// The opener is still where it was, the closer sits right at the caret, and no line break came between.
    private func isIntact(_ a: Armed, caret: Int, _ ns: NSString) -> Bool {
        let o = (a.opener as NSString).length, c = (a.close as NSString).length
        guard a.open + o <= caret, caret + c <= ns.length,
              ns.substring(with: NSRange(location: a.open, length: o)) == a.opener,
              ns.substring(with: NSRange(location: caret, length: c)) == a.close else { return false }
        return ns.rangeOfCharacter(from: .newlines, range: NSRange(location: a.open, length: caret - a.open)).location == NSNotFound
    }

    /// Close only before nothing, a space or another closer (typing an opener in front of a word just inserts it).
    /// A straight `"` also has to start something: after a letter it is the closing quote.
    private func shouldClose(_ opener: String, at caret: Int, _ ns: NSString) -> Bool {
        if caret < ns.length {
            let next = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: caret))
            guard next.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) || Self.closers.contains(next) else { return false }
        }
        if opener == "\"", caret > 0 {
            let prev = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: caret - 1))
            return prev.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) || Self.pairs[prev] != nil
        }
        return true
    }
}

// MARK: Symbols (⌘/)

/// One entry of the symbol menu. Built-in ones carry a localized name; the writer's own show the glyph alone.
struct Symbol: Hashable {
    let text: String
    var close: String? = nil
    var name: L10nKey? = nil

    var glyph: String { text + (close ?? "") }
    func menuTitle(_ label: String?) -> String { label.map { "\(glyph)    \($0)" } ?? glyph }
}

/// Symbols web-novel writers type often. The list is the writer's (Settings › Editor); the first ten are on 1–9 · 0.
enum Symbols {
    static let defaults: [Symbol] = [
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

    /// A symbol from what the writer typed: a built-in one keeps its name.
    static func make(_ text: String, close: String?) -> Symbol {
        let close = close.flatMap { $0.isEmpty ? nil : $0 }
        return defaults.first { $0.text == text && $0.close == close } ?? Symbol(text: text, close: close)
    }

    /// Stored as `[[text]]` / `[[text, close]]` in the defaults.
    static func encode(_ list: [Symbol]) -> [[String]] { list.map { [$0.text] + ($0.close.map { [$0] } ?? []) } }

    static func decode(_ value: Any?) -> [Symbol]? {
        guard let rows = value as? [[String]] else { return nil }
        return rows.compactMap { r in r.first.flatMap { $0.isEmpty ? nil : make($0, close: r.count > 1 ? r[1] : nil) } }
    }
}
