//! What the store hands out. ithaca-ffi mirrors these as UniFFI records (core/API.md).

use ithaca_ledger::{Actor, Kind};
use ithaca_model::{Counts, EpisodeInfo, Goal, Language};

#[derive(Debug, Clone, PartialEq)]
pub struct LibraryInfo {
    pub format: u32,
    pub read_only: bool,
    pub migrated_from: Option<u32>,
    pub backup_path: Option<String>,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ImportReport {
    pub projects: u32,
    pub folders: u32,
    pub sheets: u32,
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
