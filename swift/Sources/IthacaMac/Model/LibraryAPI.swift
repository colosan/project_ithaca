// The Swift face of core/API.md. The app codes against `LibraryAPI`; `CoreLibrary` wraps the UniFFI `Library`,
// `MockLibrary` keeps everything in memory (previews, snapshots, and running before the core lands).
// Value types are our own (not the generated ones) so the UI compiles with or without the core bindings.
import Foundation
import IthacaCore
import IthacaDesign

enum ManuscriptLanguage: String, Codable, Sendable, CaseIterable { case ko, en }
/// (r3) munpia / novelpia: the platform's own count of the text as it would be pasted (Markdown stripped).
enum GoalBasis: String, Codable, Sendable, CaseIterable { case withSpaces, withoutSpaces, words, munpia, novelpia }
enum Actor: String, Sendable { case me, claude }
enum BlockKind: String, Sendable { case edit, lease, merge, meta }

enum EpisodeStatus: String, Sendable, CaseIterable { case draft, revising, scheduled, published }

struct EpisodeInfo: Equatable, Sendable {
    var number: Int?
    var status: EpisodeStatus
    var publishAt: Int64?
    var platform: String?
    /// (r3) Side story / notice: kept in the folder but skipped when numbering.
    var excluded = false
}

/// (r3) `folder_stats` (core/API.md §Serial stats). `sheets` and the totals cover every live sheet of the folder;
/// `episodes` = live sheets not excluded, and the average and status split cover only those
/// (published + scheduled + drafts == episodes; drafts = draft, revising or no metadata).
struct FolderStats: Equatable, Sendable {
    var sheets = 0
    var episodes = 0
    var counts = Counts()
    var averageChars = 0
    /// Platform counts of the paste-ready bodies.
    var munpia = 0
    var novelpia = 0
    var published = 0
    var scheduled = 0
    var drafts = 0
}

/// (r3) What the bundled `ithaca-mcp` server may show Claude (read only).
struct McpSettings: Equatable, Sendable {
    var enabled = false
    var projects: [String] = []
}

enum BackupKind: String, Sendable { case auto, preMigration, manual }

struct BackupInfo: Identifiable, Equatable, Sendable {
    var path: String
    var at: Int64
    var bytes: UInt64
    var kind: BackupKind
    var projects: Int
    var id: String { path }
}

enum CountRule: Sendable { case withSpaces, withoutSpaces, words, munpia, novelpia, bytesUtf8 }

struct Goal: Equatable, Sendable { var count: Int; var basis: GoalBasis }

struct Counts: Equatable, Sendable {
    var chars = 0, charsNoSpace = 0, words = 0, paragraphs = 0
}

struct ProjectSummary: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var language: ManuscriptLanguage
    var goal: Goal?
    var created: Int64
    var deleted: Int64?
}

struct ProjectPatch: Sendable {
    var title: String?
    var language: ManuscriptLanguage?
    /// `.some(nil)` clears the goal.
    var goal: Goal??
}

struct SheetSummary: Identifiable, Equatable, Sendable {
    var id: String
    var folder: String
    var order: Int
    var title: String
    var excerpt: String
    var counts: Counts
    var created: Int64
    var modified: Int64
    var trashed: Int64?
    var branched: Bool
    var episode: EpisodeInfo? = nil
    /// (qa1) Part of the sheet's history couldn't be read: the summary/text are the last intact version.
    /// The app shows it read-only and offers `recoverSheetFromBackup`.
    var damaged = false
    /// (bible) The sheet is a story bible entry (front matter `종류`, ADR-0010): its kind, for the list icon.
    var entry: EntryKind? = nil
}

struct FolderInfo: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var order: Int
    var sheets: [SheetSummary]
}

struct Outline: Equatable, Sendable {
    var project: ProjectSummary
    var folders: [FolderInfo]
    var trash: [SheetSummary]
}

struct HistoryEntry: Identifiable, Equatable, Sendable {
    var hash: String
    var at: Int64
    var device: String
    var actor: Actor
    var kind: BlockKind
    var added: Int
    var removed: Int
    var id: String { hash }
}

/// One writing session of a sheet (core `history_sessions`): consecutive saves from one device and actor with
/// no pause of 10 minutes or more. `entries` newest first; `entries[0]` is the text after the session, the text
/// before it is `base` (nil = the sheet's first record). `added` / `removed` are the session's net change.
struct HistorySession: Identifiable, Equatable, Sendable {
    var start: Int64
    var end: Int64
    var device: String
    var actor: Actor
    var kind: BlockKind
    var added: Int
    var removed: Int
    var base: String?
    var entries: [HistoryEntry]
    /// The oldest entry: stays put when a new save joins the session.
    var id: String { entries.last?.hash ?? "\(start)" }
}

struct IntegrityReport: Equatable, Sendable {
    var ok: Bool
    var blocks: Int
    var message: String?
}

struct SearchHit: Identifiable, Equatable, Sendable {
    var project: String
    var sheet: String
    var title: String
    /// UTF-16 offsets, ready for NSTextView.
    var offset: Int
    var length: Int
    var before: String
    var match: String
    var after: String
    var id: String { "\(sheet):\(offset)" }
}

struct ExportOptions: Equatable, Sendable, Codable {
    var blankLine = true
    var indent = false
    var stripMarkdown = true
    var includeTitle = false
    /// Markdown file: keep the text as written.
    var markdown = false
}

/// (docx) Word export layout; defaults = core DocxOptions (A4, Hangul Office's margins).
struct DocxOptions: Equatable, Sendable, Codable {
    var font = "맑은 고딕"
    var fontSize: Double = 10
    var lineSpacing = 160
    var firstLineIndent = true
    var pageBreak = true
    var includeTitles = true
    var marginTop: Double = 20
    var marginBottom: Double = 15
    var marginLeft: Double = 30
    var marginRight: Double = 30
}

struct ImportReport: Equatable, Sendable {
    var projects: Int; var folders: Int; var sheets: Int
    /// "relative/path (reason)" for files a text-folder import left out.
    var skipped: [String] = []
}

struct LibraryInfo: Equatable, Sendable {
    var format: Int
    var coreVersion: String
    var readOnly: Bool
    var migratedFrom: Int?
    var backupPath: String?
    /// True for the in-memory MockLibrary — the UI says so, so nobody writes into it by mistake.
    var inMemory: Bool
    /// Another Ithaca process holds the library's lock: opened read-only.
    var lockedByOther = false
    /// Things the core skipped or couldn't read on open (unreadable projects…), one sentence each.
    var problems: [String] = []
}

enum LibraryError: Error, LocalizedError, Equatable {
    case notFound
    case readOnly
    case invalidInput(String)
    case io(String)
    case corrupt(String)

    /// In Korean (ADR-0011): the core's English detail never reaches the screen; it stays in `detail`.
    var errorDescription: String? {
        let key: L10nKey = switch self {
        case .notFound: .errorNotFound
        case .readOnly: .errorReadOnly
        case .invalidInput: .errorInvalidInput
        case .io: .errorIo
        case .corrupt: .errorCorrupt
        }
        return L10n.string(key, locale: .ko)
    }

    /// The core's message (English), for tooltips and logs.
    var detail: String {
        switch self {
        case .notFound, .readOnly: ""
        case .invalidInput(let m), .io(let m), .corrupt(let m): m
        }
    }
}

/// Mirrors core/API.md one to one (Rust snake_case → Swift camelCase).
@MainActor
protocol LibraryAPI: AnyObject {
    func info() -> LibraryInfo

    func projects() -> [ProjectSummary]
    func createProject(title: String, language: ManuscriptLanguage, folders: [String]) throws -> ProjectSummary
    func updateProject(id: String, patch: ProjectPatch) throws -> ProjectSummary
    func deleteProject(id: String) throws
    func restoreProject(id: String) throws
    func deletedProjects() -> [ProjectSummary]

    func outline(project: String) throws -> Outline
    func createFolder(project: String, name: String) throws -> FolderInfo
    func renameFolder(project: String, folder: String, name: String) throws
    func deleteFolder(project: String, folder: String) throws
    func restoreFolder(project: String, folder: String) throws

    func createSheet(project: String, folder: String, text: String) throws -> SheetSummary
    func sheetText(project: String, sheet: String) throws -> String
    @discardableResult func saveSheet(project: String, sheet: String, text: String) throws -> SheetSummary
    func moveSheet(project: String, sheet: String, folder: String, before: String?) throws
    func trashSheet(project: String, sheet: String) throws
    func restoreSheet(project: String, sheet: String) throws
    func deleteSheetForever(project: String, sheet: String) throws
    func emptyTrash(project: String) throws

    func history(project: String, sheet: String) throws -> [HistoryEntry]
    func historySessions(project: String, sheet: String) throws -> [HistorySession]
    func textAt(project: String, sheet: String, hash: String) throws -> String
    @discardableResult func restoreVersion(project: String, sheet: String, hash: String) throws -> SheetSummary
    func verify(project: String) throws -> IntegrityReport

    // Episodes (round 2)
    @discardableResult func setEpisode(project: String, sheet: String, info: EpisodeInfo?) throws -> SheetSummary
    func stock(project: String, folder: String) throws -> Int
    func renumberEpisodes(project: String, folder: String) throws -> Int
    /// (qa1) Every live sheet of `folder` up to and including `sheet` gets `status`; returns how many sheets.
    func setStatusThrough(project: String, folder: String, sheet: String, status: EpisodeStatus) throws -> Int
    /// (qa1) A damaged sheet's text comes back from the newest backup that has it intact. No backup has it → notFound.
    @discardableResult func recoverSheetFromBackup(project: String, sheet: String) throws -> SheetSummary
    /// (qa1) No usable backup: go on from the last good text; the sheet is editable again.
    @discardableResult func keepLastGoodText(project: String, sheet: String) throws -> SheetSummary
    /// (r3) Earliest future `publish_at` among the folder's live Scheduled sheets; nil when none.
    func nextRelease(project: String, folder: String) throws -> Int64?
    /// (r3) Totals of one folder for the inspector.
    func folderStats(project: String, folder: String) throws -> FolderStats

    // Claude (MCP, r3): persisted in the library so the ithaca-mcp process reads the same settings.
    func mcpSettings() -> McpSettings
    @discardableResult func setMcpSettings(_ settings: McpSettings) throws -> McpSettings

    // Backups (round 2). The copies take seconds: these run off the main thread.
    func backupDue() -> Bool
    func backupNow() async throws -> BackupInfo
    func backupManual() async throws -> BackupInfo
    func backups() -> [BackupInfo]
    func backupsDir() -> String
    /// `suffix` is appended to every restored title (qa1), e.g. " (백업 10월 24일)".
    func restoreBackupAsCopies(path: String, suffix: String) async throws -> [ProjectSummary]

    // Platform counts (round 2, free functions in the core)
    /// Pure (no library state): callable off the main thread (live counting).
    nonisolated func countFor(text: String, rule: CountRule) -> Int
    func munpiaPages(text: String) -> Int
    /// (r3) A sheet's length on a goal basis; munpia / novelpia count the paste-ready body.
    func goalCount(text: String, basis: GoalBasis) -> Int
    /// (r3) What is pasted into a platform's body field: title line removed, Markdown stripped, scene breaks normalized.
    /// The app's counts (footer, list rows, inspector, goal) count this text (PRODUCT "글자수 정의", 2026-10-24).
    nonisolated func platformBody(text: String) -> String
    /// (note) The sheet's `작가의 말` as pasted into the platform's own field; nil without a `## 작가의 말` heading.
    nonisolated func authorNote(text: String) -> String?

    func search(query: String, project: String?) -> [SearchHit]
    /// (qa1) Every live project, `current` first, so one long project can't crowd out the rest.
    func searchAll(query: String, current: String?) -> [SearchHit]
    /// Seconds for a large backup: off the main thread.
    func importWebBackup(json: String, suffix: String) async throws -> ImportReport
    /// A folder of .txt/.md files → one new project (`title`/`language` nil = folder name / detected).
    func importTextFolder(path: String, title: String?, language: ManuscriptLanguage?) async throws -> ImportReport
    func exportText(project: String, sheets: [String], options: ExportOptions) throws -> String
    /// (docx) The sheets as a .docx file's bytes (`sheets` as in exportText).
    func exportDocx(project: String, sheets: [String], options: DocxOptions) throws -> Data

    // Story bible (ADR-0010). The preview is the core's free function `bibleImportPreview` (StoryBible.swift).
    /// The previewed entry texts appended to `folder`, in order. All or nothing. Returns the new sheet ids.
    func importBible(project: String, folder: String, entries: [String]) throws -> [String]
    // Story bible (core/API.md §Story bible, ADR-0010): computed from live sheet text on request, nothing stored.
    /// Every live entry, most recently seen first (never seen last, by name).
    func bible(project: String) throws -> [BibleEntry]
    /// Mentions of matchable entries in `text` (the editor's text, may be unsaved), in order. UTF-16 offsets.
    func mentionsIn(project: String, text: String) throws -> [Mention]
    /// Every live non-entry sheet that mentions the entry, in reading order.
    func appearances(project: String, entry: String) throws -> [Appearance]
}

extension Int64 {
    static var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    var date: Date { Date(timeIntervalSince1970: Double(self) / 1000) }
}
