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
            try? await Task.sleep(for: .seconds(1))
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
    func lastAppearance(of entry: BibleEntry) -> Appearance? {
        let all = appearances(entry.sheet)
        return all.last { $0.sheet != sheetId } ?? all.last
    }

    /// Inspector "나온 회차" row / card: open that sheet with the first mention selected.
    func openAppearance(_ a: Appearance) {
        openSheet(a.sheet, at: NSRange(location: a.offset, length: a.length))
    }
}
