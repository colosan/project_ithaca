// Story bible entries in the app (ADR-0010, design/screens/story-bible §1 · §6): creating entries, the lore folder,
// suggested fields and the Notion import. What an entry is (front matter, name, sections) is the core's rule
// (`parseEntry`, `entryTemplate`, `bibleImportPreview`); the app only inserts text and never rewrites it.
import AppKit
import IthacaCore
import IthacaDesign
import UniformTypeIdentifiers

extension EntryKind {
    static let all: [EntryKind] = [.character, .place, .group, .term]

    var icon: IthacaIcon {
        switch self {
        case .character: .entryCharacter
        case .place: .entryPlace
        case .group: .entryGroup
        case .term: .entryTerm
        }
    }

    var label: L10nKey {
        switch self {
        case .character: .entryKindCharacter
        case .place: .entryKindPlace
        case .group: .entryKindGroup
        case .term: .entryKindTerm
        }
    }

    var newLabel: L10nKey {
        switch self {
        case .character: .entryNewCharacter
        case .place: .entryNewPlace
        case .group: .entryNewGroup
        case .term: .entryNewTerm
        }
    }

    /// The new-sheet picker's line under the kind.
    var hint: L10nKey {
        switch self {
        case .character: .newSheetHintCharacter
        case .place: .newSheetHintPlace
        case .group: .newSheetHintGroup
        case .term: .newSheetHintTerm
        }
    }

    /// "Add Field" suggestions (spec §1), in the manuscript's language: they are written into the text as `## ` titles,
    /// so they follow the project's language, not the app's.
    func suggestedSections(_ language: ManuscriptLanguage) -> [String] {
        switch (self, language) {
        case (.character, .ko): ["원하는 것", "두려운 것", "관계", "비밀/복선", "변화"]
        case (.place, .ko): ["있었던 일", "자주 오는 인물"]
        case (.group, .ko): ["근거지", "비밀"]
        case (.term, .ko): ["예문"]
        case (.character, .en): ["Wants", "Fears", "Relationships", "Secrets / foreshadowing", "Changes"]
        case (.place, .en): ["Events", "Regulars"]
        case (.group, .en): ["Base", "Secrets"]
        case (.term, .en): ["Examples"]
        }
    }
}

/// A line found by "Find in lines that mention them": opens `sheet` with `range` selected.
struct LineHit: Identifiable, Equatable {
    var sheet: String
    var label: String
    var line: String
    var range: NSRange
    var id: String { "\(sheet):\(range.location)" }
}

extension ManuscriptLanguage {
    var core: IthacaCore.Language { self == .ko ? .ko : .en }
}

@MainActor
enum StoryBible {
    /// Where entries made from the selection and imports go: a folder named "설정" (Lore) or "Lore", else the second folder,
    /// else the current one (spec §1).
    static func loreFolder(_ folders: [FolderInfo], current: String?) -> FolderInfo? {
        let names: Set<String> = ["설정", "lore"]
        if let f = folders.first(where: { names.contains($0.name.trimmingCharacters(in: .whitespaces).lowercased()) }) { return f }
        if folders.count >= 2 { return folders[1] }
        return folders.first { $0.id == current } ?? folders.first
    }

    /// An entry's name from selected text: one line, inner whitespace collapsed, at most 80 characters.
    static func name(fromSelection s: String) -> String {
        let one = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(one.prefix(80))
    }

    /// Selected text as one line: line breaks and runs of spaces become one space, cut at `limit` characters.
    static func oneLine(_ s: String, limit: Int) -> String {
        let one = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return one.count > limit ? String(one.prefix(limit)) + "…" : one
    }

    enum NoteSection {
        case notes, changes
        var titles: Set<String> { self == .notes ? ["메모", "notes", "note"] : EntryPart.changes.titles }
        func title(_ language: ManuscriptLanguage) -> String {
            switch (self, language) {
            case (.notes, .ko): "메모"
            case (.notes, .en): "Notes"
            case (.changes, .ko): "변화"
            case (.changes, .en): "Changes"
            }
        }
    }

    /// `item` as the last line of the entry's section (after its last non-blank line, before the next `#`/`##` title);
    /// when there is no such section, a new one at the end in the manuscript's language. Nothing else changes.
    static func appendItem(_ item: String, to section: NoteSection, in text: String, language: ManuscriptLanguage) -> String {
        var lines = text.components(separatedBy: "\n")
        let bodyStart = text.isEmpty ? 0 : (text as NSString).substring(to: Styles.frontMatterEnd(text as NSString)).components(separatedBy: "\n").count - 1
        func title(_ line: String) -> String? {
            guard line.hasPrefix("## ") else { return nil }
            return line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
        }
        if let h = lines.indices.first(where: { $0 >= bodyStart && title(lines[$0]).map(section.titles.contains) == true }) {
            let end = lines.indices.first { $0 > h && (lines[$0].hasPrefix("# ") || lines[$0].hasPrefix("## ")) } ?? lines.count
            let last = (h..<end).last { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty } ?? h
            lines.insert(item, at: last + 1)
            return lines.joined(separator: "\n")
        }
        return text + sectionInsertion(after: text, title: section.title(language)) + item + "\n"
    }

    /// About `chars` characters from the end, cut at a paragraph (line) start; "…" in front when cut.
    static func tail(_ text: String, about chars: Int) -> String {
        let paras = text.components(separatedBy: "\n")
        var out: [String] = [], count = 0
        for p in paras.reversed() {
            if count >= chars { break }
            out.insert(p, at: 0)
            count += p.count
        }
        let s = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return out.count < paras.count && !s.isEmpty ? "…\n" + s : s
    }

    /// Lines of `text` that contain one of `names` and `query` (case-insensitive); the range is the query's, UTF-16.
    static func lines(in text: String, with names: [String], containing query: String) -> [(line: String, range: NSRange)] {
        let ns = text as NSString
        var out: [(String, NSRange)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, r, _, _ in
            guard let line, names.contains(where: { line.contains($0) }) else { return }
            let q = (line as NSString).range(of: query, options: .caseInsensitive)
            guard q.location != NSNotFound else { return }
            out.append((line.trimmingCharacters(in: .whitespaces), NSRange(location: r.location + q.location, length: q.length)))
        }
        return out
    }

    /// UTF-16 offset of the end of the template's `# ` name line (the caret of a new entry).
    static func nameCaret(_ text: String) -> Int {
        let ns = text as NSString
        let start = Int(IthacaCore.parseEntry(text: text)?.bodyStart ?? 0)
        let r = ns.range(of: "# ", range: NSRange(location: start, length: ns.length - start))
        guard r.location != NSNotFound else { return start }
        let line = ns.lineRange(for: r)
        let end = NSMaxRange(line)
        return end > 0 && ns.character(at: end - 1) == 0x0A ? end - 1 : end
    }

    /// The entry kind of `text` — only its front matter is parsed. nil for plain sheets.
    static func kind(of text: String) -> EntryKind? {
        let ns = text as NSString
        let end = Styles.frontMatterEnd(ns)
        guard end > 0 else { return nil }
        return IthacaCore.parseEntry(text: ns.substring(to: end))?.kind
    }

    /// Suggested fields of the entry's kind that it doesn't have yet; nil when `text` isn't an entry.
    static func missingSections(_ text: String, language: ManuscriptLanguage) -> [String]? {
        guard let e = IthacaCore.parseEntry(text: text) else { return nil }
        let have = Set(e.sections.map { $0.title.lowercased() })
        return e.kind.suggestedSections(language).filter { !have.contains($0.lowercased()) }
    }

    /// What "Add Field" appends: one blank line before the title (whatever the sheet ends with), a line for the body.
    static func sectionInsertion(after text: String, title: String) -> String {
        let lead = text.isEmpty || text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
        return lead + "## " + title.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Notion export → entry texts (nothing written). Errors come back as LibraryError (said in the app's language).
    static func importPreview(path: String, kind: EntryKind, language: ManuscriptLanguage) throws -> [ImportedEntry] {
        do { return try IthacaCore.bibleImportPreview(path: path, kind: kind, language: language.core) } catch { throw CoreLibrary.map(error) }
    }

    /// "Custom Name…": a small prompt for the new field's title. nil when cancelled or empty.
    static func promptFieldName(_ model: AppModel) -> String? {
        let alert = NSAlert()
        alert.messageText = model.t(.entryAddFieldPrompt)
        alert.addButton(withTitle: model.t(.entryAddFieldAdd))
        alert.addButton(withTitle: model.t(.actionCancel))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = model.t(.entryAddFieldPlaceholder)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// A menu item that runs a closure (the editor's context menu and the "Add Field" menu).
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler() }
}

extension AppModel {
    var loreFolder: FolderInfo? { StoryBible.loreFolder(folders, current: folderId) }

    /// The open sheet's entry kind (nil for plain sheets). Reads only the front matter.
    var openEntryKind: EntryKind? { sheetId == nil ? nil : StoryBible.kind(of: text) }

    /// "New Character / Place / Group / Term": the template in `folder` (default: the current one), opened with the
    /// caret on the name line.
    func newEntry(_ kind: EntryKind, in folder: String? = nil) {
        guard let projectId, !readOnly, let fid = folder ?? folderId ?? folders.first?.id, folders.contains(where: { $0.id == fid }) else { return }
        guard ensureSaved() else { return }
        showingTrash = false
        libraryOverlay = false
        let text = IthacaCore.entryTemplate(kind: kind, name: "", language: language.core)
        do {
            let s = try library.createSheet(project: projectId, folder: fid, text: text)
            reloadOutline()
            openSheet(s.id, at: NSRange(location: StoryBible.nameCaret(text), length: 0))
            editor?.focus()
        } catch { fail(error) }
    }

    /// "Make Story Bible Entry ▸ kind": the selected text names a new entry in the lore folder. The editor stays on
    /// the sheet being written; the toast offers to open the new one. Returns the new sheet's id.
    @discardableResult func makeEntryFromSelection(_ kind: EntryKind) -> String? {
        guard let projectId, !readOnly, let editor else { return nil }
        let name = StoryBible.name(fromSelection: editor.selectedText)
        guard !name.isEmpty, let lore = loreFolder else { return nil }
        do {
            let s = try library.createSheet(project: projectId, folder: lore.id, text: IthacaCore.entryTemplate(kind: kind, name: name, language: language.core))
            reloadOutline()
            showToast(Toast(message: t(.entryCreated, ["folder": lore.name, "name": name]), undo: { [weak self] in
                guard let self, self.projectId == projectId else { return }
                self.showingTrash = false
                self.openSheet(s.id)
                self.editor?.focus()
            }, action: t(.actionOpen)))
            return s.id
        } catch { fail(error); return nil }
    }

    /// File → Import Story Bible…: pick a Notion .md file or folder, then the preview sheet.
    func importBible() {
        guard projectId != nil, !readOnly, busy == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"), .folder].compactMap { $0 }
        panel.message = t(.importBibleHint)
        panel.prompt = t(.importBibleImport)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        show(.importBible(path: url.path(percentEncoded: false)))
    }

    /// The preview's [Import]: all entries into the lore folder, or none. True when it went in.
    @discardableResult func importBible(_ entries: [ImportedEntry]) -> Bool {
        guard let projectId, !readOnly, !entries.isEmpty, let lore = loreFolder else { return false }
        do {
            let ids = try library.importBible(project: projectId, folder: lore.id, entries: entries.map(\.text))
            reloadOutline()
            showToast(Toast(message: t(.importBibleDone, ["folder": lore.name, "count": ids.count], count: ids.count), undo: { [weak self] in
                guard let self, self.projectId == projectId, let first = ids.first else { return }
                self.showingTrash = false
                self.openSheet(first)
            }, action: t(.actionOpen)))
            return true
        } catch {
            showToast(Toast(message: t(.importWebFailed, ["message": error.localizedDescription]), sticky: true))
            return false
        }
    }
}
