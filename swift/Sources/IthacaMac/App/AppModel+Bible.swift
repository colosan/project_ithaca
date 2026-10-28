// The story bible cache (design/screens/story-bible/spec.md §2–§5): the open project's entries for `@`, ⌥Esc and the
// card, and the open sheet's mentions for the inspector and the underline. Never computed per keystroke:
// - `bible`: right away when a project opens, 0.3 s after an entry sheet is saved or the outline reloads,
//   5 s after another sheet is saved (its mentions move "last seen").
// - `sheetMentions`: when a sheet opens, then 1 s after typing stops (and not while composing).
import Foundation

extension AppModel {
    /// Called from `reloadOutline`: a new project loads its bible now, the same one refreshes a moment later.
    func outlineDidReload() {
        if projectId != bibleProject { refreshBible() } else { scheduleBibleRefresh(after: .milliseconds(300)) }
    }

    func refreshBible() {
        bibleTask?.cancel()
        bibleTask = nil
        bibleProject = projectId
        let fresh = projectId.flatMap { try? library.bible(project: $0) } ?? []
        guard fresh != bible else { return }
        let hadNone = bible.isEmpty
        bible = fresh
        // The first entries of a project: the open sheet's mentions weren't looked for until now.
        if hadNone || fresh.isEmpty { refreshMentions() }
    }

    func scheduleBibleRefresh(after delay: Duration) {
        bibleTask?.cancel()
        bibleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            refreshBible()
        }
    }

    /// After a save: an entry changed (name, aliases, summary) → soon; any other sheet → later (last-seen order).
    func didSaveForBible(_ sheet: String) {
        let isEntry = bible.contains { $0.sheet == sheet } || text.hasPrefix("---")
        if isEntry { scheduleBibleRefresh(after: .milliseconds(300)) } else if !bible.isEmpty { scheduleBibleRefresh(after: .seconds(5)) }
    }

    /// The editor's text changed: look for mentions once typing has stopped for a second.
    func scheduleMentions() {
        guard !bible.isEmpty || !sheetMentions.isEmpty else { return }
        mentionsTask?.cancel()
        mentionsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Wait.ms(1000))
            guard let self, !Task.isCancelled else { return }
            if editor?.isComposing == true { scheduleMentions(); return }
            refreshMentions()
        }
    }

    func refreshMentions() {
        mentionsTask?.cancel()
        mentionsTask = nil
        let found: [Mention]
        if let projectId, sheetId != nil, !bible.isEmpty { found = (try? library.mentionsIn(project: projectId, text: text)) ?? [] } else { found = [] }
        mentionsGeneration += 1
        if found != sheetMentions { sheetMentions = found }
    }

    func entry(_ sheet: String) -> BibleEntry? { bible.first { $0.sheet == sheet } }

    /// The open sheet when it is a story-bible entry.
    var openEntry: BibleEntry? { sheetId.flatMap(entry) }

    /// "이 시트에 나온 항목": each entry once, in the order it first appears.
    var mentionedEntries: [BibleEntry] {
        var seen = Set<String>()
        return sheetMentions.compactMap { m in seen.insert(m.entry).inserted ? entry(m.entry) : nil }
    }

    func appearances(_ entry: String) -> [Appearance] {
        guard let projectId else { return [] }
        return (try? library.appearances(project: projectId, entry: entry)) ?? []
    }

    /// "238화", or the sheet's title when it has no episode number.
    func appearanceLabel(_ a: Appearance) -> String {
        if let n = a.number { return t(.bibleEpisode, ["number": n]) }
        return a.title.isEmpty ? t(.sheetUntitled) : a.title
    }

    /// The card's "last seen": the newest sheet mentioning the entry other than the one being written.
    func lastAppearance(of entry: BibleEntry) -> Appearance? { cardAppearances(of: entry).last }

    /// The open sheet's episode number: cards and changes are shown as of this episode (v3 §1.3).
    var currentEpisode: Int? { sheet?.episode?.number }

    /// The card's "first · last seen". In a numbered episode N both are as of N: last = the newest episode before N,
    /// first = only if it is ≤ N (revising episode 120 must not show what happens in 238). Elsewhere: the newest sheet
    /// other than the open one.
    func cardAppearances(of entry: BibleEntry) -> (first: Appearance?, last: Appearance?) {
        let all = appearances(entry.sheet)
        if let n = currentEpisode {
            let numbered = all.filter { $0.number != nil }
            return (numbered.first { $0.number! <= n }, numbered.last { $0.number! < n })
        }
        return (all.first { $0.number != nil } ?? all.first, all.last { $0.sheet != sheetId } ?? all.last)
    }

    /// "238화", the sheet's title, or nil: the tag in front of a line noted from this sheet.
    var currentSheetLabel: String? {
        if let n = currentEpisode { return t(.bibleEpisode, ["number": n]) }
        return sheet.map(\.title).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "Note in Story Bible ▸ 서윤" (v3 §1.4): the selection, on one line and tagged with this episode, as the last item
    /// of the entry's `## 메모` (or `## 변화`). Another sheet changes, so the toast offers the undo.
    @discardableResult func noteInEntry(_ entry: BibleEntry, _ selection: String, asChange: Bool) -> Bool {
        guard let projectId, !readOnly, entry.sheet != sheetId else { return false }
        let line = StoryBible.oneLine(selection, limit: 400)
        guard !line.isEmpty else { return false }
        let item = "- " + (currentSheetLabel.map { "\($0): " } ?? "") + line
        do {
            let before = try library.sheetText(project: projectId, sheet: entry.sheet)
            let after = StoryBible.appendItem(item, to: asChange ? .changes : .notes, in: before, language: language)
            try library.saveSheet(project: projectId, sheet: entry.sheet, text: after)
            reloadOutline()
            showToast(Toast(message: t(.entryNoted, ["name": entry.name]), undo: { [weak self] in
                guard let self, self.projectId == projectId, (try? self.library.sheetText(project: projectId, sheet: entry.sheet)) == after else { return }
                do {
                    try self.library.saveSheet(project: projectId, sheet: entry.sheet, text: before)
                    self.reloadOutline()
                } catch { self.fail(error) }
            }))
            return true
        } catch { fail(error); return false }
    }

    /// Entries for "Note in Story Bible ▸": the ones named in the selection, else the 8 most recently seen.
    func noteTargets(for selection: String) -> [BibleEntry] {
        guard let projectId, !bible.isEmpty else { return [] }
        var seen = Set<String>()
        let named = ((try? library.mentionsIn(project: projectId, text: selection)) ?? [])
            .compactMap { seen.insert($0.entry).inserted ? entry($0.entry) : nil }
            .filter { $0.sheet != sheetId }
        return named.isEmpty ? Array(bible.filter { $0.sheet != sheetId }.prefix(8)) : named
    }

    /// "Previous episode's end" (v3 §1.1): the sheet before the open one in its folder, when the open one is an episode.
    func previousEpisode() -> (sheet: SheetSummary, tail: String)? {
        guard let projectId, currentEpisode != nil, let f = folders.first(where: { $0.sheets.contains { $0.id == sheetId } }),
              let i = f.sheets.firstIndex(where: { $0.id == sheetId }), i > 0 else { return nil }
        let prev = f.sheets[i - 1]
        guard let text = try? library.sheetText(project: projectId, sheet: prev.id) else { return nil }
        let tail = StoryBible.tail(text, about: 600)
        return tail.isEmpty ? nil : (prev, tail)
    }

    /// "Find in lines that mention them" (v3 §1.5): lines with one of the entry's names and `query`, newest sheet first.
    func searchAppearances(_ entry: BibleEntry, _ query: String, limit: Int = 50) -> [LineHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let projectId, !q.isEmpty else { return [] }
        let names = entry.names.map(\.text)
        var hits: [LineHit] = []
        for a in appearances(entry.sheet).reversed() {
            let body = a.sheet == sheetId ? text : ((try? library.sheetText(project: projectId, sheet: a.sheet)) ?? "")
            for h in StoryBible.lines(in: body, with: names, containing: q) {
                hits.append(LineHit(sheet: a.sheet, label: appearanceLabel(a), line: h.line, range: h.range))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Inspector "나온 회차" row / card: open that sheet with the first mention selected.
    func openAppearance(_ a: Appearance) {
        openSheet(a.sheet, at: NSRange(location: a.offset, length: a.length))
    }
}
