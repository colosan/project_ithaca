// In-memory LibraryAPI with the same behavior the core promises (core/API.md): soft deletes, trash that remembers
// where a sheet was, a version list per sheet, search with UTF-16 offsets. Nothing touches the disk.
import Foundation

@MainActor
final class MockLibrary: LibraryAPI {
    private struct Version { var hash: String; var at: Int64; var device: String; var actor: Actor; var kind: BlockKind; var text: String; var added: Int; var removed: Int }
    private struct Project { var summary: ProjectSummary }
    private struct Folder { var id: String; var project: String; var name: String; var order: Int; var deleted: Int64? }
    private struct Sheet {
        var id: String; var folder: String; var order: Int; var created: Int64; var modified: Int64
        var trashed: Int64?; var branched = false; var versions: [Version]
        var episode: EpisodeInfo?
        var text: String { versions.last?.text ?? "" }
    }

    private var projectList: [Project] = []
    private var folders: [Folder] = []
    private var sheets: [Sheet] = []
    private let device: String
    /// Snapshots: sheets to report as damaged (a recover clears the mark).
    var damagedSheets: Set<String> = []
    /// Snapshots: a read-only / problems library.
    var infoOverride: LibraryInfo?

    init(seeded: Bool, device: String = Host.current().localizedName ?? "Mac") {
        self.device = device
        if seeded { seed() }
    }

    func info() -> LibraryInfo {
        infoOverride ?? LibraryInfo(format: 1, coreVersion: "mock", readOnly: false, migratedFrom: nil, backupPath: nil, inMemory: true)
    }

    // MARK: Projects

    func projects() -> [ProjectSummary] { projectList.map(\.summary).filter { $0.deleted == nil } }
    func deletedProjects() -> [ProjectSummary] { projectList.map(\.summary).filter { $0.deleted != nil } }

    func createProject(title: String, language: ManuscriptLanguage, folders names: [String]) throws -> ProjectSummary {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw LibraryError.invalidInput("empty title") }
        let p = ProjectSummary(id: Self.uid(), title: t, language: language, goal: nil, created: .nowMillis, deleted: nil)
        projectList.append(Project(summary: p))
        guard !names.isEmpty else { throw LibraryError.invalidInput("no folders") }
        for (i, n) in names.enumerated() { folders.append(Folder(id: Self.uid(), project: p.id, name: n, order: i)) }
        _ = try createSheet(project: p.id, folder: folders[folders.count - names.count].id, text: "")
        return p
    }

    func updateProject(id: String, patch: ProjectPatch) throws -> ProjectSummary {
        guard let i = projectList.firstIndex(where: { $0.summary.id == id }) else { throw LibraryError.notFound }
        if let t = patch.title { projectList[i].summary.title = t }
        if let l = patch.language { projectList[i].summary.language = l }
        if let g = patch.goal { projectList[i].summary.goal = g }
        return projectList[i].summary
    }

    func deleteProject(id: String) throws {
        guard let i = projectList.firstIndex(where: { $0.summary.id == id }) else { throw LibraryError.notFound }
        projectList[i].summary.deleted = .nowMillis
    }

    func restoreProject(id: String) throws {
        guard let i = projectList.firstIndex(where: { $0.summary.id == id }) else { throw LibraryError.notFound }
        projectList[i].summary.deleted = nil
    }

    // MARK: Outline

    func outline(project: String) throws -> Outline {
        guard let p = projectList.first(where: { $0.summary.id == project }) else { throw LibraryError.notFound }
        let fs = folders.filter { $0.project == project }
        let live = fs.filter { $0.deleted == nil }.sorted { $0.order < $1.order }.map { f in
            FolderInfo(id: f.id, name: f.name, order: f.order,
                       sheets: sheets.filter { $0.folder == f.id && $0.trashed == nil }.sorted { ($0.order, $0.created) < ($1.order, $1.created) }.map(summary))
        }
        let ids = Set(fs.map(\.id))
        let trash = sheets.filter { ids.contains($0.folder) && $0.trashed != nil }.sorted { $0.trashed! > $1.trashed! }.map(summary)
        return Outline(project: p.summary, folders: live, trash: trash)
    }

    func createFolder(project: String, name: String) throws -> FolderInfo {
        let order = (folders.filter { $0.project == project }.map(\.order).max() ?? -1) + 1
        let f = Folder(id: Self.uid(), project: project, name: name, order: order)
        folders.append(f)
        return FolderInfo(id: f.id, name: name, order: order, sheets: [])
    }

    func renameFolder(project: String, folder: String, name: String) throws {
        guard let i = folders.firstIndex(where: { $0.id == folder }) else { throw LibraryError.notFound }
        folders[i].name = name
    }

    func deleteFolder(project: String, folder: String) throws {
        guard let i = folders.firstIndex(where: { $0.id == folder }) else { throw LibraryError.notFound }
        let now = Int64.nowMillis
        folders[i].deleted = now
        for j in sheets.indices where sheets[j].folder == folder && sheets[j].trashed == nil { sheets[j].trashed = now }
    }

    func restoreFolder(project: String, folder: String) throws {
        guard let i = folders.firstIndex(where: { $0.id == folder }), let when = folders[i].deleted else { throw LibraryError.notFound }
        folders[i].deleted = nil
        for j in sheets.indices where sheets[j].folder == folder && sheets[j].trashed == when { sheets[j].trashed = nil }
    }

    // MARK: Sheets

    func createSheet(project: String, folder: String, text: String) throws -> SheetSummary {
        let order = (sheets.filter { $0.folder == folder }.map(\.order).max() ?? -1) + 1
        let now = Int64.nowMillis
        let s = Sheet(id: Self.uid(), folder: folder, order: order, created: now, modified: now, trashed: nil,
                      versions: text.isEmpty ? [] : [version(text, previous: "")])
        sheets.append(s)
        return summary(s)
    }

    func sheetText(project: String, sheet: String) throws -> String { try find(sheet).text }

    func saveSheet(project: String, sheet: String, text: String) throws -> SheetSummary {
        let i = try index(sheet)
        if sheets[i].text != text {
            sheets[i].versions.append(version(text, previous: sheets[i].text))
            sheets[i].modified = .nowMillis
        }
        return summary(sheets[i])
    }

    func moveSheet(project: String, sheet: String, folder: String, before: String?) throws {
        let i = try index(sheet)
        sheets[i].folder = folder
        var list = sheets.filter { $0.folder == folder && $0.trashed == nil && $0.id != sheet }.sorted { ($0.order, $0.created) < ($1.order, $1.created) }.map(\.id)
        let at = before.flatMap { b in list.firstIndex(of: b) } ?? list.count
        list.insert(sheet, at: at)
        for (n, id) in list.enumerated() { if let j = sheets.firstIndex(where: { $0.id == id }) { sheets[j].order = n } }
    }

    func trashSheet(project: String, sheet: String) throws { sheets[try index(sheet)].trashed = .nowMillis }

    func restoreSheet(project: String, sheet: String) throws {
        let i = try index(sheet)
        sheets[i].trashed = nil
        // Its folder was deleted: bring the folder back too (trash spec).
        if let f = folders.firstIndex(where: { $0.id == sheets[i].folder }), folders[f].deleted != nil { folders[f].deleted = nil }
    }

    func deleteSheetForever(project: String, sheet: String) throws { sheets.remove(at: try index(sheet)) }

    func emptyTrash(project: String) throws {
        let ids = Set(folders.filter { $0.project == project }.map(\.id))
        sheets.removeAll { ids.contains($0.folder) && $0.trashed != nil }
    }

    // MARK: History

    func history(project: String, sheet: String) throws -> [HistoryEntry] {
        try find(sheet).versions.reversed().map { HistoryEntry(hash: $0.hash, at: $0.at, device: $0.device, actor: $0.actor, kind: $0.kind, added: $0.added, removed: $0.removed) }
    }

    func textAt(project: String, sheet: String, hash: String) throws -> String {
        guard let v = try find(sheet).versions.first(where: { $0.hash == hash }) else { throw LibraryError.notFound }
        return v.text
    }

    func restoreVersion(project: String, sheet: String, hash: String) throws -> SheetSummary {
        try saveSheet(project: project, sheet: sheet, text: try textAt(project: project, sheet: sheet, hash: hash))
    }

    func verify(project: String) throws -> IntegrityReport {
        let ids = Set(folders.filter { $0.project == project }.map(\.id))
        return IntegrityReport(ok: true, blocks: sheets.filter { ids.contains($0.folder) }.reduce(0) { $0 + $1.versions.count }, message: nil)
    }

    // MARK: Search · import · export

    func search(query: String, project: String?) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let liveFolders = Dictionary(uniqueKeysWithValues: folders.filter { $0.deleted == nil && (project == nil || $0.project == project) }.map { ($0.id, $0.project) })
        var hits: [SearchHit] = []
        for s in sheets where s.trashed == nil {
            guard let p = liveFolders[s.folder] else { continue }
            let text = s.text as NSString
            var range = NSRange(location: 0, length: text.length)
            var n = 0
            while n < 5 {
                let r = text.range(of: q, options: [.caseInsensitive], range: range)
                if r.location == NSNotFound { break }
                let from = max(0, r.location - 24)
                let to = min(text.length, r.location + r.length + 48)
                hits.append(SearchHit(project: p, sheet: s.id, title: TextMetrics.title(s.text), offset: r.location, length: r.length,
                                      before: text.substring(with: NSRange(location: from, length: r.location - from)),
                                      match: text.substring(with: r),
                                      after: text.substring(with: NSRange(location: r.location + r.length, length: to - r.location - r.length))))
                n += 1
                range = NSRange(location: r.location + r.length, length: text.length - r.location - r.length)
            }
        }
        return hits
    }

    /// app-web backup (store.ts State v1): { version: 1, projects, folders, sheets } → new projects, nothing overwritten.
    func importWebBackup(json: String, suffix: String) async throws -> ImportReport {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["version"] as? Int) == 1,
              let ps = root["projects"] as? [[String: Any]], let fs = root["folders"] as? [[String: Any]], let ss = root["sheets"] as? [[String: Any]]
        else { throw LibraryError.invalidInput("not an Ithaca web backup") }
        var report = ImportReport(projects: 0, folders: 0, sheets: 0)
        for p in ps where p["deleted"] == nil {
            guard let pid = p["id"] as? String else { continue }
            let lang = ManuscriptLanguage(rawValue: p["language"] as? String ?? "ko") ?? .ko
            let title = (p["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            let created = ProjectSummary(id: Self.uid(), title: title, language: lang, goal: nil, created: .nowMillis, deleted: nil)
            projectList.append(Project(summary: created))
            if let g = p["goal"] as? [String: Any], let c = g["count"] as? Int, let b = GoalBasis(rawValue: g["basis"] as? String ?? "") {
                _ = try updateProject(id: created.id, patch: ProjectPatch(goal: .some(Goal(count: c, basis: b))))
            }
            report.projects += 1
            for f in fs.filter({ $0["projectId"] as? String == pid && $0["deleted"] == nil }).sorted(by: { ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0) }) {
                guard let fid = f["id"] as? String else { continue }
                let nf = try createFolder(project: created.id, name: f["name"] as? String ?? "")
                report.folders += 1
                for s in ss.filter({ $0["folderId"] as? String == fid }).sorted(by: { ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0) }) {
                    let ns = try createSheet(project: created.id, folder: nf.id, text: s["body"] as? String ?? "")
                    if s["trashed"] != nil { try trashSheet(project: created.id, sheet: ns.id) }
                    report.sheets += 1
                }
            }
        }
        return report
    }

    func exportText(project: String, sheets ids: [String], options: ExportOptions) throws -> String {
        let parts = try ids.map { id -> String in
            let text = try find(id).text
            return TextMetrics.render(text, title: TextMetrics.title(text), options)
        }
        return parts.joined(separator: options.markdown ? "\n\n---\n\n" : "\n\n\n")
    }

    /// The mock has no core to build a Word package: the plain text stands in (snapshots never save).
    func exportDocx(project: String, sheets ids: [String], options: DocxOptions) throws -> Data {
        Data(try exportText(project: project, sheets: ids, options: ExportOptions(indent: options.firstLineIndent, includeTitle: options.includeTitles)).utf8)
    }

    // MARK: Episodes · backups · platform counts

    func setEpisode(project: String, sheet: String, info: EpisodeInfo?) throws -> SheetSummary {
        let i = try index(sheet)
        sheets[i].episode = info
        return summary(sheets[i])
    }

    func stock(project: String, folder: String) throws -> Int {
        sheets.filter { $0.folder == folder && $0.trashed == nil && $0.episode?.status != .published }.count
    }

    func renumberEpisodes(project: String, folder: String) throws -> Int {
        var n = 0
        for i in sheets.indices.sorted(by: { (sheets[$0].order, sheets[$0].created) < (sheets[$1].order, sheets[$1].created) })
        where sheets[i].folder == folder && sheets[i].trashed == nil {
            if sheets[i].episode?.excluded == true { sheets[i].episode?.number = nil; continue }
            n += 1
            if sheets[i].episode == nil { sheets[i].episode = EpisodeInfo(status: .draft) }
            sheets[i].episode?.number = n
        }
        return n
    }

    func backupDue() -> Bool { false }
    func backupNow() async throws -> BackupInfo { throw LibraryError.io("in-memory library") }
    func backupManual() async throws -> BackupInfo { throw LibraryError.io("in-memory library") }
    func backups() -> [BackupInfo] { [] }
    func backupsDir() -> String { NSTemporaryDirectory() }
    func restoreBackupAsCopies(path: String, suffix: String) async throws -> [ProjectSummary] { throw LibraryError.invalidInput("in-memory library") }

    func setStatusThrough(project: String, folder: String, sheet: String, status: EpisodeStatus) throws -> Int {
        var n = 0
        for i in sheets.indices.sorted(by: { (sheets[$0].order, sheets[$0].created) < (sheets[$1].order, sheets[$1].created) })
        where sheets[i].folder == folder && sheets[i].trashed == nil {
            if sheets[i].episode == nil { sheets[i].episode = EpisodeInfo(status: status) } else { sheets[i].episode?.status = status }
            n += 1
            if sheets[i].id == sheet { return n }
        }
        throw LibraryError.notFound
    }

    func importTextFolder(path: String, title: String?, language: ManuscriptLanguage?) async throws -> ImportReport {
        throw LibraryError.invalidInput("in-memory library")
    }

    func keepLastGoodText(project: String, sheet: String) throws -> SheetSummary {
        guard damagedSheets.remove(sheet) != nil else { throw LibraryError.invalidInput("not damaged") }
        return summary(try find(sheet))
    }

    func searchAll(query: String, current: String?) -> [SearchHit] {
        let order = [current].compactMap { $0 } + projects().map(\.id).filter { $0 != current }
        return order.flatMap { search(query: query, project: $0) }
    }

    func recoverSheetFromBackup(project: String, sheet: String) throws -> SheetSummary {
        guard damagedSheets.remove(sheet) != nil else { throw LibraryError.notFound }
        return summary(try find(sheet))
    }

    func nextRelease(project: String, folder: String) throws -> Int64? {
        sheets.filter { $0.folder == folder && $0.trashed == nil && $0.episode?.status == .scheduled }
            .compactMap { $0.episode?.publishAt }.filter { $0 > .nowMillis }.min()
    }

    func folderStats(project: String, folder: String) throws -> FolderStats {
        guard folders.contains(where: { $0.id == folder && $0.deleted == nil }) else { throw LibraryError.notFound }
        var st = FolderStats()
        var episodeChars = 0
        for s in sheets where s.folder == folder && s.trashed == nil {
            st.sheets += 1
            let c = TextMetrics.counts(s.text)
            st.counts.chars += c.chars; st.counts.charsNoSpace += c.charsNoSpace; st.counts.words += c.words; st.counts.paragraphs += c.paragraphs
            let pasted = TextMetrics.render(s.text, title: TextMetrics.title(s.text), ExportOptions(includeTitle: false))
            st.munpia += countFor(text: pasted, rule: .munpia)
            st.novelpia += countFor(text: pasted, rule: .novelpia)
            guard s.episode?.excluded != true else { continue }
            st.episodes += 1
            episodeChars += c.chars
            switch s.episode?.status {
            case .published: st.published += 1
            case .scheduled: st.scheduled += 1
            default: st.drafts += 1
            }
        }
        st.averageChars = st.episodes == 0 ? 0 : Int((Double(episodeChars) / Double(st.episodes)).rounded())
        return st
    }

    private var mcp = McpSettings()
    func mcpSettings() -> McpSettings { mcp }
    func setMcpSettings(_ settings: McpSettings) throws -> McpSettings { mcp = settings; return mcp }

    func countFor(text: String, rule: CountRule) -> Int {
        let c = TextMetrics.counts(text)
        switch rule {
        case .withSpaces, .munpia: return c.chars
        case .withoutSpaces: return c.charsNoSpace
        case .words: return c.words
        case .novelpia: return text.filter { !$0.isWhitespace && !".,'\"!?…;".contains($0) }.count
        case .bytesUtf8: return text.utf8.count
        }
    }

    func munpiaPages(text: String) -> Int { (countFor(text: text, rule: .munpia) + 469) / 470 }

    func goalCount(text: String, basis: GoalBasis) -> Int {
        switch basis {
        case .munpia, .novelpia:
            let pasted = TextMetrics.render(text, title: TextMetrics.title(text), ExportOptions(includeTitle: false))
            return countFor(text: pasted, rule: basis == .munpia ? .munpia : .novelpia)
        default: return TextMetrics.goalValue(TextMetrics.counts(text), basis)
        }
    }

    // MARK: Helpers

    private func find(_ id: String) throws -> Sheet { sheets[try index(id)] }
    private func index(_ id: String) throws -> Int {
        guard let i = sheets.firstIndex(where: { $0.id == id }) else { throw LibraryError.notFound }
        return i
    }

    private func summary(_ s: Sheet) -> SheetSummary {
        SheetSummary(id: s.id, folder: s.folder, order: s.order, title: TextMetrics.title(s.text), excerpt: TextMetrics.excerpt(s.text),
                     counts: TextMetrics.counts(s.text), created: s.created, modified: s.modified, trashed: s.trashed, branched: s.branched, episode: s.episode,
                     damaged: damagedSheets.contains(s.id))
    }

    private func version(_ text: String, previous: String, at: Int64 = .nowMillis, device: String? = nil, actor: Actor = .me) -> Version {
        let a = Array(previous), b = Array(text)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return Version(hash: Self.uid() + Self.uid(), at: at, device: device ?? self.device, actor: actor, kind: .edit, text: text,
                       added: b.count - p - s, removed: a.count - p - s)
    }

    private static func uid() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased() }

    // MARK: Seed (fixtures/sample-project.json)

    /// The day after tomorrow, 18:00 local: always in the future so "next release" shows.
    static let sampleRelease: Int64 = {
        let day = Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
        let d = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
        return Int64(d.timeIntervalSince1970 * 1000)
    }()

    private func seed() {
        guard let root = try? JSONSerialization.jsonObject(with: Data(MockSeed.json.utf8)) as? [String: Any],
              let ps = root["projects"] as? [[String: Any]] else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        let ms: (Any?) -> Int64 = { v in (v as? String).flatMap { iso.date(from: $0) }.map { Int64($0.timeIntervalSince1970 * 1000) } ?? .nowMillis }
        let openSheet = root["openSheet"] as? [String: Any]
        let historyRoot = root["history"] as? [String: Any]
        let start = Int64.nowMillis - 20 * 86_400_000
        var n: Int64 = 0
        for p in ps {
            let pid = p["id"] as! String
            var goal: Goal?
            if let g = p["goal"] as? [String: Any], let c = g["count"] as? Int { goal = Goal(count: c, basis: GoalBasis(rawValue: g["basis"] as? String ?? "") ?? .withSpaces) }
            projectList.append(Project(summary: ProjectSummary(id: pid, title: p["title"] as? String ?? "", language: ManuscriptLanguage(rawValue: p["language"] as? String ?? "ko") ?? .ko, goal: goal, created: start, deleted: nil)))
            for (fi, f) in ((p["folders"] as? [[String: Any]]) ?? []).enumerated() {
                let fid = f["id"] as! String
                folders.append(Folder(id: fid, project: pid, name: f["name"] as? String ?? "", order: fi))
                for (si, s) in ((f["sheets"] as? [[String: Any]]) ?? []).enumerated() {
                    let sid = s["id"] as! String
                    let title = s["title"] as? String ?? ""
                    var text: String
                    if sid == (historyRoot?["sheet"] as? String), let paras = openSheet?["paragraphs"] as? [String] {
                        text = paras.joined(separator: "\n\n")
                    } else if let body = s["body"] as? [String] {
                        text = body.joined(separator: "\n\n")
                    } else {
                        text = "# \(title)\n\n\(s["excerpt"] as? String ?? "")"
                    }
                    n += 1
                    let at = start + n * 3_600_000
                    var sheet = Sheet(id: sid, folder: fid, order: si, created: at, modified: at, trashed: nil, branched: s["branched"] as? Bool ?? false, versions: [])
                    // 1–2 published, 3 revising, 4 scheduled.
                    if fi == 0 {
                        sheet.episode = EpisodeInfo(number: si + 1, status: si < 2 ? .published : si == 2 ? .revising : si == 3 ? .scheduled : .draft)
                        if si == 3 { sheet.episode?.publishAt = Self.sampleRelease }
                    }
                    if sid == (historyRoot?["sheet"] as? String), let records = historyRoot?["records"] as? [[String: Any]] {
                        // Rebuild versions newest → oldest by undoing each record's before/after.
                        var texts: [(String, [String: Any])] = []
                        var current = text
                        for r in records {
                            texts.append((current, r))
                            if let a = r["after"] as? String, let b = r["before"] as? String, !a.isEmpty { current = current.replacingOccurrences(of: a, with: b) }
                        }
                        var previous = ""
                        sheet.created = ms(openSheet?["createdAt"])
                        for (t, r) in texts.reversed() {
                            var v = version(t, previous: previous, at: ms(r["at"]), device: r["device"] as? String, actor: Actor(rawValue: r["actor"] as? String ?? "me") ?? .me)
                            v.kind = BlockKind(rawValue: r["kind"] as? String ?? "edit") ?? .edit
                            if let a = r["added"] as? Int { v.added = a }
                            if let rm = r["removed"] as? Int { v.removed = rm }
                            sheet.versions.append(v)
                            previous = t
                        }
                        sheet.modified = ms(openSheet?["modifiedAt"])
                    } else {
                        sheet.versions = [version(text, previous: "", at: at)]
                    }
                    sheets.append(sheet)
                }
            }
        }
    }
}
