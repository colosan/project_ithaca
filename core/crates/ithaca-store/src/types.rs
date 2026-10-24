//! What the store hands out. ithaca-ffi mirrors these as UniFFI records (core/API.md).

use ithaca_ledger::{Actor, Kind};
use ithaca_model::{Counts, EpisodeInfo, Goal, Language};

#[derive(Debug, Clone, PartialEq)]
pub struct LibraryInfo {
    pub format: u32,
    pub read_only: bool,
    pub migrated_from: Option<u32>,
    pub backup_path: Option<String>,
    /// Another open (usually another app instance) holds the library lock; this one is read-only.
    pub locked_by_other: bool,
    /// Human-readable notes from opening and later operations: skipped projects, why the library
    /// is read-only, failed cleanups. Empty when all is well.
    pub problems: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProjectSummary {
    pub id: String,
    pub title: String,
    pub language: Language,
    pub goal: Option<Goal>,
    pub created: i64,
    /// Latest block time in the project.
    pub modified: i64,
    pub deleted: Option<i64>,
    /// Live sheets (not trashed, in live folders).
    pub sheets: u32,
    /// Sum over live sheets.
    pub counts: Counts,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ProjectPatch {
    pub title: Option<String>,
    pub language: Option<Language>,
    /// `Some` with `count == 0` clears the goal.
    pub goal: Option<Goal>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SheetSummary {
    pub id: String,
    pub folder: String,
    pub order: u32,
    pub title: String,
    pub excerpt: String,
    pub counts: Counts,
    pub created: i64,
    pub modified: i64,
    pub trashed: Option<i64>,
    pub branched: bool,
    /// Serial-episode metadata; `None` = not an episode (notes, prologue kept out of numbering).
    pub episode: Option<EpisodeInfo>,
    /// (added: qa1) Blocks of this sheet are broken or missing: the text is the last good one and
    /// writes are refused until it is recovered.
    pub damaged: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FolderInfo {
    pub id: String,
    pub name: String,
    pub order: u32,
    pub sheets: Vec<SheetSummary>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Outline {
    pub project: ProjectSummary,
    pub folders: Vec<FolderInfo>,
    /// Newest first.
    pub trash: Vec<SheetSummary>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct HistoryEntry {
    pub hash: String,
    pub at: i64,
    pub device: String,
    pub actor: Actor,
    pub kind: Kind,
    pub added: u32,
    pub removed: u32,
}

/// (added: history-sessions) Consecutive blocks that read as one sitting: same device and actor, edits
/// only, each built directly on the one before, with no gap of [`SESSION_GAP_MS`] or more. Lease and
/// merge blocks are sessions of their own. Display grouping only; nothing is stored.
#[derive(Debug, Clone, PartialEq)]
pub struct HistorySession {
    /// `at` of the oldest and the newest block.
    pub start: i64,
    pub end: i64,
    pub device: String,
    pub actor: Actor,
    pub kind: Kind,
    /// Net change, in graphemes, from the text before the session to the text after it (typing a
    /// sentence and deleting it again nets to +0 −0). Falls back to the sum of the blocks' own
    /// counts when a text can't be rebuilt.
    pub added: u32,
    pub removed: u32,
    /// First parent of the oldest block: the text before the session. `None` at the chain's start.
    pub base: Option<String>,
    /// The session's blocks, newest first; `entries[0]` is the text after the session. Within a
    /// session each entry's parent is the next one (the last one's is `base`).
    pub entries: Vec<HistoryEntry>,
}

/// (added: history-sessions) A pause this long (10 min) starts a new session.
pub const SESSION_GAP_MS: i64 = 10 * 60 * 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IssueKind {
    /// Not a block (bad JSON, unknown version) or not readable.
    Unreadable,
    /// Content does not hash to its name or `hash` field — the file was changed.
    HashMismatch,
    /// A parent block is missing (or itself bad).
    MissingParent,
    /// A delta does not apply to its parent's text.
    BadDelta,
    /// A file in `changes/` that is not named like a block.
    UnexpectedFile,
}

#[derive(Debug, Clone, PartialEq)]
pub struct IntegrityIssue {
    /// File name inside `changes/`.
    pub file: String,
    pub sheet: Option<String>,
    pub kind: IssueKind,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct IntegrityReport {
    pub ok: bool,
    pub blocks: u32,
    pub chains: u32,
    pub issues: Vec<IntegrityIssue>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    pub project: String,
    pub sheet: String,
    pub title: String,
    /// UTF-16 code units from the start of the sheet text.
    pub offset: u32,
    pub length: u32,
    pub snippet_before: String,
    pub snippet_match: String,
    pub snippet_after: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ImportReport {
    pub projects: u32,
    pub folders: u32,
    pub sheets: u32,
    /// (added: txt-import) Files left out, as "relative/path (reason)"; empty for web backups.
    pub skipped: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackupKind {
    /// `backup_now`: daily, pruned by retention.
    Auto,
    /// Made by the core before a format migration (ADR-0008 §5). Never pruned.
    PreMigration,
    /// `backup_manual`: the writer asked for it. Never pruned.
    Manual,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupInfo {
    /// Absolute folder of the backup (a library-shaped folder: `library.json` + `projects/`).
    pub path: String,
    /// Unix ms when it was made.
    pub at: i64,
    /// Total size of its files.
    pub bytes: u64,
    pub kind: BackupKind,
    /// Project folders in it (deleted ones included).
    pub projects: u32,
}

/// (added: r3) Totals for one folder, for the info tab and the Claude connector.
///
/// `sheets` and the length totals cover every live sheet of the folder (a prologue is pasted too).
/// `episodes` are the live sheets that are not excluded; `average_chars` (`Counts::chars`, rounded)
/// and the status split cover only those, so `published + scheduled + drafts == episodes` and
/// `scheduled + drafts == stock`. `drafts` = Draft, Revising or no metadata.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FolderStats {
    pub sheets: u32,
    pub episodes: u32,
    pub total: Counts,
    pub average_chars: u32,
    /// Sum over sheets of the `문피아` count of the paste-ready body (`ithaca_model::platform_body`).
    pub munpia_total: u32,
    /// Same with the `노벨피아` rule.
    pub novelpia_total: u32,
    pub published: u32,
    pub scheduled: u32,
    pub drafts: u32,
}
