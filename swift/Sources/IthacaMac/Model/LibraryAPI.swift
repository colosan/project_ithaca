// The Swift face of core/API.md. The app codes against `LibraryAPI`; `CoreLibrary` wraps the UniFFI `Library`,
// `MockLibrary` keeps everything in memory (previews, snapshots, and running before the core lands).
// Value types are our own (not the generated ones) so the UI compiles with or without the core bindings.
import Foundation

enum ManuscriptLanguage: String, Codable, Sendable, CaseIterable { case ko, en }
enum GoalBasis: String, Codable, Sendable, CaseIterable { case withSpaces, withoutSpaces, words }
enum Actor: String, Sendable { case me, claude }
enum BlockKind: String, Sendable { case edit, lease, merge, meta }

enum EpisodeStatus: String, Sendable, CaseIterable { case draft, revising, scheduled, published }

struct EpisodeInfo: Equatable, Sendable {
    var number: Int?
    var status: EpisodeStatus
    var publishAt: Int64?
    var platform: String?
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

struct ImportReport: Equatable, Sendable { var projects: Int; var folders: Int; var sheets: Int }

struct LibraryInfo: Equatable, Sendable {
    var format: Int
    var coreVersion: String
    var readOnly: Bool
    var migratedFrom: Int?
    var backupPath: String?
    /// True for the in-memory MockLibrary — the UI says so, so nobody writes into it by mistake.
    var inMemory: Bool
}

enum LibraryError: Error, LocalizedError, Equatable {
    case notFound
    case readOnly
    case invalidInput(String)
    case io(String)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "not found"
        case .readOnly: "read only"
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
    func textAt(project: String, sheet: String, hash: String) throws -> String
    @discardableResult func restoreVersion(project: String, sheet: String, hash: String) throws -> SheetSummary
    func verify(project: String) throws -> IntegrityReport

    // Episodes (round 2)
    @discardableResult func setEpisode(project: String, sheet: String, info: EpisodeInfo?) throws -> SheetSummary
    func stock(project: String, folder: String) throws -> Int
    func renumberEpisodes(project: String, folder: String) throws -> Int

    // Backups (round 2). The copies take seconds: these run off the main thread.
    func backupDue() -> Bool
    func backupNow() async throws -> BackupInfo
    func backupManual() async throws -> BackupInfo
    func backups() -> [BackupInfo]
    func backupsDir() -> String
    func restoreBackupAsCopies(path: String) throws -> [ProjectSummary]

    // Platform counts (round 2, free functions in the core)
    func countFor(text: String, rule: CountRule) -> Int
    func munpiaPages(text: String) -> Int

    func search(query: String, project: String?) -> [SearchHit]
    func importWebBackup(json: String) throws -> ImportReport
    func exportText(project: String, sheets: [String], options: ExportOptions) throws -> String
}

extension Int64 {
    static var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    var date: Date { Date(timeIntervalSince1970: Double(self) / 1000) }
}
