// Story bible (ADR-0010, core/API.md §Story bible): the app's value types for entries, what a section title means,
// and the name matching the editor does on its own (the `@` filter, the name at the caret).
// Mentions in a whole text come from the core (`mentionsIn`); only the small, interactive matches live here.
import Foundation
import IthacaCore
import IthacaDesign

// `EntryKind` is the core's (IthacaCore); app helpers for it live in StoryBible.swift.

struct EntryField: Equatable, Sendable { var key: String; var value: String }
struct EntrySection: Equatable, Sendable { var title: String; var body: String }

/// One sheet that mentions an entry (`appearances`, `BibleEntry.lastSeen`). Offsets are UTF-16.
struct Appearance: Equatable, Sendable, Identifiable {
    var sheet: String
    var title: String
    var folder: String
    /// Episode number, when the sheet has one.
    var number: Int?
    var count: Int
    /// The first mention.
    var offset: Int
    var length: Int
    /// Up to 3 dialogue lines (else plain lines) that mention the entry.
    var lines: [String]
    var id: String { sheet }
}

struct BibleEntry: Equatable, Sendable, Identifiable {
    var sheet: String
    var folder: String
    var kind: EntryKind
    var name: String
    var aliases: [String]
    var fields: [EntryField]
    var sections: [EntrySection]
    /// False when `본문에서 찾지 않음`: never found in the text, still offered by `@` and ⌥Esc.
    var matchable: Bool
    var lastSeen: Appearance?
    var id: String { sheet }
}

/// A name in a text: `length` covers the name only (a particle after it is not included).
struct Mention: Equatable, Sendable {
    var entry: String
    var offset: Int
    var length: Int
    var alias: Bool
    var range: NSRange { NSRange(location: offset, length: length) }
}

// MARK: Section meanings (ADR-0010 §1: the app reads the title, ko and en)

enum EntryPart: CaseIterable {
    case summary, voice, address, changes

    /// Titles compared trimmed and case-insensitively. The term "뜻" / "Meaning" is its summary.
    var titles: Set<String> {
        switch self {
        case .summary: ["한 줄 소개", "한줄 소개", "한줄소개", "소개", "뜻", "summary", "one-line summary", "meaning"]
        case .voice: ["말투", "voice", "speech"]
        case .address: ["호칭", "forms of address", "address", "how they address others"]
        case .changes: ["변화", "changes", "change"]
        }
    }
}

extension BibleEntry {
    /// Every name the entry answers to: the name first, then the aliases.
    var names: [(text: String, alias: Bool)] {
        [(name, false)] + aliases.filter { !$0.isEmpty && $0 != name }.map { ($0, true) }
    }

    func section(_ part: EntryPart) -> String? {
        let titles = part.titles
        return sections.first { titles.contains($0.title.trimmingCharacters(in: .whitespaces).lowercased()) && !$0.body.isEmpty }?.body
    }

    /// The one-line summary: the summary section's first line.
    var summary: String? { section(.summary).flatMap(Self.firstLine) }

    /// The `상태` / `status` field, when filled.
    var status: String? {
        fields.first { ["상태", "status"].contains($0.key.trimmingCharacters(in: .whitespaces).lowercased()) && !$0.value.isEmpty }?.value
    }

    /// The last item of `## 변화` ("20화부터: …"), its list mark dropped.
    var latestChange: String? {
        guard let body = section(.changes) else { return nil }
        let items = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return items.last.map { $0.replacingOccurrences(of: #"^([-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression) }
    }

    static func firstLine(_ s: String) -> String? {
        s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

// MARK: Hangul (initial consonants and the syllable still being composed)

enum Hangul {
    static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    /// Final consonants by index (1…27), as compatibility jamo.
    static let finals = Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")
    /// Compound finals as (first, second) compatibility jamo.
    static let compoundFinals: [Character: (Character, Character)] = [
        "ㄳ": ("ㄱ", "ㅅ"), "ㄵ": ("ㄴ", "ㅈ"), "ㄶ": ("ㄴ", "ㅎ"), "ㄺ": ("ㄹ", "ㄱ"), "ㄻ": ("ㄹ", "ㅁ"), "ㄼ": ("ㄹ", "ㅂ"),
        "ㄽ": ("ㄹ", "ㅅ"), "ㄾ": ("ㄹ", "ㅌ"), "ㄿ": ("ㄹ", "ㅍ"), "ㅀ": ("ㄹ", "ㅎ"), "ㅄ": ("ㅂ", "ㅅ"),
    ]
    /// Compound vowels (medial index) → the medial typed first: ㅘ ㅙ ㅚ ← ㅗ, ㅝ ㅞ ㅟ ← ㅜ, ㅢ ← ㅡ.
    static let compoundMedials: [Int: Int] = [9: 8, 10: 8, 11: 8, 14: 13, 15: 13, 16: 13, 19: 18]

    struct Syllable: Equatable { var initial: Int; var medial: Int; var final: Int }

    static func syllable(_ c: Character) -> Syllable? {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(v) else { return nil }
        let i = Int(v - 0xAC00)
        return Syllable(initial: i / 588, medial: (i % 588) / 28, final: i % 28)
    }

    static func compose(_ s: Syllable) -> Character {
        Character(UnicodeScalar(UInt32(0xAC00 + s.initial * 588 + s.medial * 28 + s.final))!)
    }

    static func isConsonant(_ c: Character) -> Bool { initials.contains(c) }

    /// "서윤" → "ㅅㅇ"; other characters stay.
    static func choseong(_ s: String) -> String {
        String(s.map { c in syllable(c).map { initials[$0.initial] } ?? c })
    }

    /// One query character against one name character (not the last query character).
    static func same(_ q: Character, _ n: Character) -> Bool {
        if q == n || q.lowercased() == n.lowercased() { return true }
        if isConsonant(q), let s = syllable(n) { return initials[s.initial] == q }
        return false
    }

    /// The last query character may still be in composition: "유" for "윤", "오" for "와", "성" for "서" + "윤"
    /// (its final consonant is about to become the next syllable's initial). `next` is the name character after `n`.
    static func samePartial(_ q: Character, _ n: Character, next: Character?) -> Bool {
        if same(q, n) { return true }
        guard let qs = syllable(q), let ns = syllable(n), qs.initial == ns.initial else { return false }
        if qs.final == 0 {
            return qs.medial == ns.medial || compoundMedials[ns.medial] == qs.medial
        }
        guard qs.medial == ns.medial, let next, let nextInitial = syllable(next).map({ initials[$0.initial] }) else { return false }
        let qFinal = finals[qs.final - 1]
        if ns.final == 0 { return qFinal == nextInitial }
        // "닭" for "달" + "고": the compound final's second half moves on.
        if let (a, b) = compoundFinals[qFinal], ns.final > 0, finals[ns.final - 1] == a { return b == nextInitial }
        return false
    }

    /// Where `query` matches inside `name` (prefix, substring or initial consonants, the last character possibly mid-composition).
    static func matches(_ query: String, _ name: String) -> Bool {
        let q = Array(query), n = Array(name)
        guard !q.isEmpty else { return true }
        guard q.count <= n.count else { return false }
        for start in 0...(n.count - q.count) {
            var ok = true
            for i in 0..<q.count {
                let j = start + i
                let hit = i == q.count - 1 ? samePartial(q[i], n[j], next: j + 1 < n.count ? n[j + 1] : nil) : same(q[i], n[j])
                if !hit { ok = false; break }
            }
            if ok { return true }
        }
        return false
    }
}

// MARK: Candidates (`@` panel, ⌥Esc)

struct NameCandidate: Identifiable, Equatable {
    var entry: BibleEntry
    /// What goes into the text: the name, or the alias that matched.
    var text: String
    var alias: Bool
    var exact: Bool
    var id: String { entry.sheet }
}

enum NameMatcher {
    static let limit = 8

    /// Exact matches first, then the bible's order (most recently seen first; never seen last, by name). One row per entry.
    static func candidates(_ query: String, in bible: [BibleEntry], limit: Int = limit) -> [NameCandidate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [(rank: Int, NameCandidate)] = []
        for (i, e) in bible.enumerated() {
            let hits = e.names.filter { Hangul.matches(q, $0.text) }
            guard !hits.isEmpty else { continue }
            let exact = hits.first { !q.isEmpty && $0.text.lowercased() == q.lowercased() }
            // The name when it matches; else the first alias that does.
            let pick = exact ?? hits.first { !$0.alias } ?? hits[0]
            out.append((i, NameCandidate(entry: e, text: pick.text, alias: pick.alias, exact: exact != nil)))
        }
        return out.sorted { ($0.1.exact ? 0 : 1, $0.rank) < ($1.1.exact ? 0 : 1, $1.rank) }.prefix(limit).map(\.1)
    }

    /// ⌥Esc: names and aliases that start with `partial` (or its initial consonants) and are longer than it, most recently seen first.
    static func completions(_ partial: String, in bible: [BibleEntry]) -> [String] {
        guard !partial.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for e in bible {
            for n in e.names where n.text.count > partial.count && startsWith(partial, n.text) && seen.insert(n.text).inserted {
                out.append(n.text)
            }
        }
        return out
    }

    static func startsWith(_ query: String, _ name: String) -> Bool {
        let q = Array(query), n = Array(name)
        guard q.count <= n.count else { return false }
        for i in 0..<q.count where !(i == q.count - 1 ? Hangul.samePartial(q[i], n[i], next: i + 1 < n.count ? n[i + 1] : nil) : Hangul.same(q[i], n[i])) {
            return false
        }
        return true
    }

    /// Particles cut from the end of a word before ⌥Esc matches it (same list as the core's `bible::JOSA`, longest first).
    static let josa: [String] = [
        "이", "가", "은", "는", "을", "를", "의", "에", "에게", "에게서", "한테", "한테서", "께", "께서", "도", "만", "와", "과", "랑", "이랑",
        "하고", "아", "야", "이여", "여", "이가", "이는", "이를", "이의", "이도", "이와", "이만", "이에게", "이한테", "이다", "이야", "이에요",
        "예요", "이요", "처럼", "보다", "부터", "까지", "에서", "으로", "로", "이란", "란", "이나", "나", "이며", "며", "이고", "고", "이네", "네",
        "이지", "지", "님", "씨",
    ].sorted { $0.count > $1.count }
    static let josaOpen = ["이었", "였", "이라", "이라서", "이라고"]

    static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// What may follow a name (ADR-0010 §3): the end, a non-letter, one or two particles then a non-letter, or a copula stem.
    static func allowedAfter(_ rest: Substring) -> Bool {
        func boundary(_ r: Substring) -> Bool { r.first.map { !isWordChar($0) } ?? true }
        if boundary(rest) || josaOpen.contains(where: { rest.hasPrefix($0) }) { return true }
        return josa.contains { j in
            guard rest.hasPrefix(j) else { return false }
            let r = rest.dropFirst(j.count)
            return boundary(r) || josa.contains { r.hasPrefix($0) && boundary(r.dropFirst($0.count)) }
        }
    }

    /// The entry whose name or alias covers `index` (or ends right at it) on that line — every entry, no-match ones too.
    /// Longest name wins. Used by the card (⌥⌘R, force click, hover).
    static func name(at index: Int, in ns: NSString, bible: [BibleEntry], endInclusive: Bool = true) -> (entry: BibleEntry, range: NSRange)? {
        guard ns.length > 0 else { return nil }
        let at = min(max(0, index), ns.length)
        let line = ns.paragraphRange(for: NSRange(location: min(at, ns.length - 1), length: 0))
        let searchRange = NSUnionRange(line, NSRange(location: at, length: 0))
        var best: (BibleEntry, NSRange)?
        for e in bible {
            for n in e.names where (n.text as NSString).length > 0 {
                var from = searchRange.location
                while from < NSMaxRange(searchRange) {
                    let r = ns.range(of: n.text, options: [.caseInsensitive], range: NSRange(location: from, length: NSMaxRange(searchRange) - from))
                    guard r.location != NSNotFound else { break }
                    from = r.location + 1
                    let covers = r.location <= at && (endInclusive ? at <= NSMaxRange(r) : at < NSMaxRange(r))
                    guard covers else { continue }
                    if r.location > 0, let prev = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: r.location - 1)).first, isWordChar(prev) { continue }
                    if best == nil || r.length > best!.1.length { best = (e, r) }
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Mentions of matchable entries in `text`, the core's rules in Swift (MockLibrary only; the app asks the core).
    static func mentions(in text: String, bible: [BibleEntry], skipUTF16 start: Int = 0, skipName: (EntryKind, String)? = nil) -> [Mention] {
        var patterns: [(String, BibleEntry, Bool)] = []
        for e in bible where e.matchable && !(skipName.map { $0.0 == e.kind && $0.1 == e.name } ?? false) {
            for n in e.names where n.text.count >= 2 { patterns.append((n.text, e, n.alias)) }
        }
        patterns.sort { $0.0.count > $1.0.count }
        var out: [Mention] = []
        var i = text.startIndex
        var offset = 0
        var prev: Character?
        while i < text.endIndex {
            let c = text[i]
            if offset >= start, prev.map({ !isWordChar($0) }) ?? true,
               let hit = patterns.first(where: { text[i...].hasPrefix($0.0) && allowedAfter(text[text.index(i, offsetBy: $0.0.count)...]) }) {
                let len = (hit.0 as NSString).length
                out.append(Mention(entry: hit.1.sheet, offset: offset, length: len, alias: hit.2))
                let end = text.index(i, offsetBy: hit.0.count)
                prev = text[text.index(before: end)]
                offset += len
                i = end
                continue
            }
            prev = c
            offset += c.utf16.count
            i = text.index(after: i)
        }
        return out
    }
}
