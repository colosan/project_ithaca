// MockLibrary's story bible: entries parsed by the core's pure `parseEntry`, mentions found with the same rules in Swift
// (NameMatcher.mentions). Good enough for previews, snapshots and the editor self-test; the app uses the core.
import Foundation
import IthacaCore

extension MockLibrary {
    private struct Parsed { var summary: SheetSummary; var text: String; var entry: IthacaCore.ParsedEntry? }

    /// Live sheets in reading order (folder order, then list order).
    private func readingOrder(_ project: String) throws -> [Parsed] {
        try outline(project: project).folders.flatMap(\.sheets).map { s in
            let text = try sheetText(project: project, sheet: s.id)
            return Parsed(summary: s, text: text, entry: IthacaCore.parseEntry(text: text))
        }
    }

    private static func entry(_ p: Parsed, _ e: IthacaCore.ParsedEntry) -> BibleEntry {
        BibleEntry(sheet: p.summary.id, folder: p.summary.folder, kind: CoreLibrary.entryKind(e.kind), name: e.name, aliases: e.aliases,
                   fields: e.fields.map { EntryField(key: $0.key, value: $0.value) }, sections: e.sections.map { EntrySection(title: $0.title, body: $0.body) },
                   matchable: e.matchable, lastSeen: nil)
    }

    private func appearances(of entry: BibleEntry, in sheets: [Parsed], all: [BibleEntry]) -> [Appearance] {
        guard entry.matchable else { return [] }
        return sheets.compactMap { p -> Appearance? in
            guard p.entry == nil else { return nil }
            let ms = NameMatcher.mentions(in: p.text, bible: all).filter { $0.entry == entry.sheet }
            guard let first = ms.first else { return nil }
            let ns = p.text as NSString
            let lines = ms.map { ns.substring(with: ns.lineRange(for: $0.range)).trimmingCharacters(in: .whitespacesAndNewlines) }
            var unique: [String] = []
            for l in lines where !unique.contains(l) { unique.append(l) }
            let quotes: Set<Character> = ["\"", "“", "「", "『", "'", "‘", "-", "―"]
            let dialogue = unique.filter { $0.first.map(quotes.contains) ?? false }
            return Appearance(sheet: p.summary.id, title: p.summary.title, folder: p.summary.folder, number: p.summary.episode?.number,
                              count: ms.count, offset: first.offset, length: first.length,
                              lines: Array((dialogue.isEmpty ? unique : dialogue).prefix(3)))
        }
    }

    func bible(project: String) throws -> [BibleEntry] {
        let sheets = try readingOrder(project)
        var entries = sheets.compactMap { p in p.entry.map { Self.entry(p, $0) } }
        let order = Dictionary(uniqueKeysWithValues: sheets.enumerated().map { ($1.summary.id, $0) })
        for i in entries.indices { entries[i].lastSeen = appearances(of: entries[i], in: sheets, all: entries).last }
        return entries.sorted {
            let a = $0.lastSeen.flatMap { order[$0.sheet] } ?? -1, b = $1.lastSeen.flatMap { order[$0.sheet] } ?? -1
            return a != b ? a > b : $0.name < $1.name
        }
    }

    func mentionsIn(project: String, text: String) throws -> [Mention] {
        let all = try bible(project: project)
        let own = IthacaCore.parseEntry(text: text)
        return NameMatcher.mentions(in: text, bible: all, skipUTF16: Int(own?.bodyStart ?? 0),
                                    skipName: own.map { (CoreLibrary.entryKind($0.kind), $0.name) })
    }

    func appearances(project: String, entry: String) throws -> [Appearance] {
        let all = try bible(project: project)
        guard let e = all.first(where: { $0.sheet == entry }) else { throw LibraryError.notFound }
        return appearances(of: e, in: try readingOrder(project), all: all)
    }
}
