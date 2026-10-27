//! The only functions Swift and Kotlin call (ADR-0001). Everything else stays inside the core.
//! The contract is core/API.md; change both together.

use std::sync::{Arc, Mutex, MutexGuard};

use ithaca_store as store;
use ithaca_store::Store;

uniffi::setup_scaffolding!();

/// Core version, shown in Settings → About next to the app version.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Platform length rules (added round 2). See core/API.md §Platform counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CountRule {
    WithSpaces,
    WithoutSpaces,
    Words,
    Munpia,
    Novelpia,
    BytesUtf8,
}

/// Length of `text` under a platform rule (added round 2). Counts the text as given.
#[uniffi::export]
pub fn count_for(text: String, rule: CountRule) -> u32 {
    use ithaca_model::CountRule as M;
    let rule = match rule {
        CountRule::WithSpaces => M::WithSpaces,
        CountRule::WithoutSpaces => M::WithoutSpaces,
        CountRule::Words => M::Words,
        CountRule::Munpia => M::Munpia,
        CountRule::Novelpia => M::Novelpia,
        CountRule::BytesUtf8 => M::BytesUtf8,
    };
    ithaca_model::count_for(&text, rule)
}

/// `문피아 쪽수`: ⌈Munpia count / 470⌉ (added round 2).
#[uniffi::export]
pub fn munpia_pages(text: String) -> u32 {
    ithaca_model::munpia_pages(&text)
}

/// (added: r3) A sheet's length under a goal basis: `WithSpaces` / `WithoutSpaces` / `Words` count
/// the sheet as written (= its `Counts`); `Munpia` / `Novelpia` count `platform_body(text)`.
#[uniffi::export]
pub fn goal_count(text: String, basis: GoalBasis) -> u32 {
    ithaca_model::goal_count(&text, basis.into())
}

/// (added: r3) What is pasted into a platform's body field: the default export rules without the
/// title line.
#[uniffi::export]
pub fn platform_body(text: String) -> String {
    ithaca_model::platform_body(&text)
}

// ── Story bible (added: bible) ────────────────────────────────────────

/// (added: bible) Parses a sheet's text. `None` when it is not an entry (no or unknown `종류`).
#[uniffi::export]
pub fn parse_entry(text: String) -> Option<ParsedEntry> {
    ithaca_model::parse_entry(&text).map(Into::into)
}

/// (added: bible) The text of a new entry: Korean or English keys and section titles, empty values
/// and sections, `name` under `# `.
#[uniffi::export]
pub fn entry_template(kind: EntryKind, name: String, language: Language) -> String {
    ithaca_model::entry_template(kind.into(), &name, language.into())
}

/// (added: bible) A Notion export (a `.md` file or a folder of them, recursively) as entry texts of
/// `kind`. Reads only. A missing path → NotFound.
#[uniffi::export]
pub fn bible_import_preview(
    path: String,
    kind: EntryKind,
    language: Language,
) -> Result<Vec<ImportedEntry>, CoreError> {
    Ok(vec(store::bible_import_preview(
        std::path::Path::new(&path),
        kind.into(),
        language.into(),
    )?))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum EntryKind {
    Character,
    Place,
    Group,
    Term,
}

impl From<ithaca_model::EntryKind> for EntryKind {
    fn from(k: ithaca_model::EntryKind) -> Self {
        use ithaca_model::EntryKind as K;
        match k {
            K::Character => EntryKind::Character,
            K::Place => EntryKind::Place,
            K::Group => EntryKind::Group,
            K::Term => EntryKind::Term,
        }
    }
}

impl From<EntryKind> for ithaca_model::EntryKind {
    fn from(k: EntryKind) -> Self {
        use ithaca_model::EntryKind as K;
        match k {
            EntryKind::Character => K::Character,
            EntryKind::Place => K::Place,
            EntryKind::Group => K::Group,
            EntryKind::Term => K::Term,
        }
    }
}

/// A front matter `key: value` line. (Not `Field`: that name would clash in Swift.)
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EntryField {
    pub key: String,
    pub value: String,
}

/// A `## title` section. (Not `Section`: SwiftUI has one.)
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EntrySection {
    pub title: String,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ParsedEntry {
    pub kind: EntryKind,
    pub name: String,
    pub aliases: Vec<String>,
    pub fields: Vec<EntryField>,
    pub sections: Vec<EntrySection>,
    pub matchable: bool,
    /// UTF-16 offset of the first character after the front matter.
    pub body_start: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Appearance {
    pub sheet: String,
    pub title: String,
    pub folder: String,
    pub number: Option<u32>,
    pub count: u32,
    pub offset: u32,
    pub length: u32,
    pub lines: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BibleEntry {
    pub sheet: String,
    pub folder: String,
    pub kind: EntryKind,
    pub name: String,
    pub aliases: Vec<String>,
    pub fields: Vec<EntryField>,
    pub sections: Vec<EntrySection>,
    pub matchable: bool,
    pub last_seen: Option<Appearance>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Mention {
    pub entry: String,
    pub offset: u32,
    pub length: u32,
    pub alias: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportedEntry {
    pub source: String,
    pub name: String,
    pub fields: u32,
    pub sections: u32,
    pub text: String,
}

impl From<ithaca_model::EntryField> for EntryField {
    fn from(f: ithaca_model::EntryField) -> Self {
        EntryField {
            key: f.key,
            value: f.value,
        }
    }
}

impl From<ithaca_model::EntrySection> for EntrySection {
    fn from(s: ithaca_model::EntrySection) -> Self {
        EntrySection {
            title: s.title,
            body: s.body,
        }
    }
}

impl From<ithaca_model::ParsedEntry> for ParsedEntry {
    fn from(e: ithaca_model::ParsedEntry) -> Self {
        ParsedEntry {
            kind: e.kind.into(),
            name: e.name,
            aliases: e.aliases,
            fields: vec(e.fields),
            sections: vec(e.sections),
            matchable: e.matchable,
            body_start: e.body_start,
        }
    }
}

impl From<store::Appearance> for Appearance {
    fn from(a: store::Appearance) -> Self {
        Appearance {
            sheet: a.sheet,
            title: a.title,
            folder: a.folder,
            number: a.number,
            count: a.count,
            offset: a.offset,
            length: a.length,
            lines: a.lines,
        }
    }
}

impl From<store::BibleEntry> for BibleEntry {
    fn from(e: store::BibleEntry) -> Self {
        BibleEntry {
            sheet: e.sheet,
            folder: e.folder,
            kind: e.kind.into(),
            name: e.name,
            aliases: e.aliases,
            fields: vec(e.fields),
            sections: vec(e.sections),
            matchable: e.matchable,
            last_seen: e.last_seen.map(Into::into),
        }
    }
}

impl From<store::Mention> for Mention {
    fn from(m: store::Mention) -> Self {
        Mention {
            entry: m.entry,
            offset: m.offset,
            length: m.length,
            alias: m.alias,
        }
    }
}

impl From<store::ImportedEntry> for ImportedEntry {
    fn from(e: store::ImportedEntry) -> Self {
        ImportedEntry {
            source: e.source,
            name: e.name,
            fields: e.fields,
            sections: e.sections,
            text: e.text,
        }
    }
}

// ── Types ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("not found")]
    NotFound,
    #[error("library is read-only")]
    ReadOnly,
    #[error("invalid input: {message}")]
    InvalidInput { message: String },
    #[error("io: {message}")]
    Io { message: String },
    #[error("corrupt: {message}")]
    Corrupt { message: String },
}

impl From<store::StoreError> for CoreError {
    fn from(e: store::StoreError) -> Self {
        use store::StoreError as E;
        match e {
            E::NotFound => CoreError::NotFound,
            E::ReadOnly => CoreError::ReadOnly,
            E::InvalidInput(message) => CoreError::InvalidInput { message },
            E::Io(message) => CoreError::Io { message },
            E::Corrupt(message) => CoreError::Corrupt { message },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Language {
    Ko,
    En,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum GoalBasis {
    WithSpaces,
    WithoutSpaces,
    Words,
    /// (added: r3)
    Munpia,
    /// (added: r3)
    Novelpia,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Actor {
    Me,
    Claude,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BlockKind {
    Edit,
    Lease,
    Merge,
    Meta,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum IssueKind {
    Unreadable,
    HashMismatch,
    MissingParent,
    BadDelta,
    UnexpectedFile,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Goal {
    pub count: u32,
    pub basis: GoalBasis,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
pub struct Counts {
    pub chars: u32,
    pub chars_no_space: u32,
    pub words: u32,
    pub paragraphs: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LibraryInfo {
    pub format: u32,
    pub core_version: String,
    pub read_only: bool,
    pub migrated_from: Option<u32>,
    pub backup_path: Option<String>,
    /// (added: safety) Another app instance holds the library lock; this open is read-only.
    pub locked_by_other: bool,
    /// (added: safety) Notes to show the writer: skipped projects, why read-only, failed cleanups.
    pub problems: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProjectSummary {
    pub id: String,
    pub title: String,
    pub language: Language,
    pub goal: Option<Goal>,
    pub created: i64,
    pub modified: i64,
    pub deleted: Option<i64>,
    pub sheets: u32,
    pub counts: Counts,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, uniffi::Record)]
pub struct ProjectPatch {
    #[uniffi(default = None)]
    pub title: Option<String>,
    #[uniffi(default = None)]
    pub language: Option<Language>,
    /// `count == 0` clears the goal.
    #[uniffi(default = None)]
    pub goal: Option<Goal>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
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
    /// Added round 2. `None` = not an episode.
    #[uniffi(default = None)]
    pub episode: Option<EpisodeInfo>,
    /// (added: qa1) Blocks are broken or missing: `sheet_text` is the last good text, writes return
    /// `Corrupt` until `recover_sheet_from_backup` or `keep_last_good_text`.
    #[uniffi(default = false)]
    pub damaged: bool,
    /// (added: bible) The kind when the sheet is a story-bible entry; derived from the text.
    #[uniffi(default = None)]
    pub entry: Option<EntryKind>,
}

/// Added round 2.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Enum)]
pub enum EpisodeStatus {
    #[default]
    Draft,
    Revising,
    Scheduled,
    Published,
}

/// Added round 2.
#[derive(Debug, Clone, PartialEq, Eq, Default, uniffi::Record)]
pub struct EpisodeInfo {
    #[uniffi(default = None)]
    pub number: Option<u32>,
    /// No default in Swift: UniFFI 0.32 proc-macros can't express enum defaults.
    pub status: EpisodeStatus,
    #[uniffi(default = None)]
    pub publish_at: Option<i64>,
    #[uniffi(default = None)]
    pub platform: Option<String>,
    /// (added: r3) Prologue / side story / notice: no number, skipped by renumbering, never stock.
    #[uniffi(default = false)]
    pub excluded: bool,
}

/// (added: r3) See core/API.md §Serial stats.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
pub struct FolderStats {
    pub sheets: u32,
    pub episodes: u32,
    pub total: Counts,
    pub average_chars: u32,
    pub munpia_total: u32,
    pub novelpia_total: u32,
    pub published: u32,
    pub scheduled: u32,
    pub drafts: u32,
}

impl From<store::FolderStats> for FolderStats {
    fn from(f: store::FolderStats) -> Self {
        FolderStats {
            sheets: f.sheets,
            episodes: f.episodes,
            total: f.total.into(),
            average_chars: f.average_chars,
            munpia_total: f.munpia_total,
            novelpia_total: f.novelpia_total,
            published: f.published,
            scheduled: f.scheduled,
            drafts: f.drafts,
        }
    }
}

/// (added: r3) What the Claude connector may do. Only `Read` today.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum McpPermission {
    Read,
}

/// (added: r3) `<library>/mcp.json`, read by `ithaca-mcp` on every request.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct McpSettings {
    pub enabled: bool,
    pub projects: Vec<String>,
    pub permission: McpPermission,
}

impl From<store::mcp::McpSettings> for McpSettings {
    fn from(s: store::mcp::McpSettings) -> Self {
        McpSettings {
            enabled: s.enabled,
            projects: s.projects,
            permission: match s.permission {
                store::mcp::McpPermission::Read => McpPermission::Read,
            },
        }
    }
}

/// Added round 2.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BackupKind {
    Auto,
    PreMigration,
    Manual,
}

/// Added round 2.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BackupInfo {
    pub path: String,
    pub at: i64,
    pub bytes: u64,
    pub kind: BackupKind,
    pub projects: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FolderInfo {
    pub id: String,
    pub name: String,
    pub order: u32,
    pub sheets: Vec<SheetSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Outline {
    pub project: ProjectSummary,
    pub folders: Vec<FolderInfo>,
    pub trash: Vec<SheetSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryEntry {
    pub hash: String,
    pub at: i64,
    pub device: String,
    pub actor: Actor,
    pub kind: BlockKind,
    pub added: u32,
    pub removed: u32,
}

/// (added: history-sessions) core/API.md §History.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistorySession {
    pub start: i64,
    pub end: i64,
    pub device: String,
    pub actor: Actor,
    pub kind: BlockKind,
    pub added: u32,
    pub removed: u32,
    pub base: Option<String>,
    pub entries: Vec<HistoryEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct IntegrityIssue {
    pub file: String,
    pub sheet: Option<String>,
    pub kind: IssueKind,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct IntegrityReport {
    pub ok: bool,
    pub blocks: u32,
    pub chains: u32,
    pub issues: Vec<IntegrityIssue>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchHit {
    pub project: String,
    pub sheet: String,
    pub title: String,
    /// UTF-16 code units.
    pub offset: u32,
    pub length: u32,
    pub snippet_before: String,
    pub snippet_match: String,
    pub snippet_after: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportReport {
    pub projects: u32,
    pub folders: u32,
    pub sheets: u32,
    /// (added: txt-import) Files `import_text_folder` left out, "relative/path (reason)".
    #[uniffi(default)]
    pub skipped: Vec<String>,
}

impl From<ithaca_store::ImportReport> for ImportReport {
    fn from(r: ithaca_store::ImportReport) -> Self {
        ImportReport {
            projects: r.projects,
            folders: r.folders,
            sheets: r.sheets,
            skipped: r.skipped,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ExportOptions {
    #[uniffi(default = true)]
    pub blank_line: bool,
    #[uniffi(default = false)]
    pub indent: bool,
    #[uniffi(default = true)]
    pub strip_markdown: bool,
    #[uniffi(default = true)]
    pub include_title: bool,
    #[uniffi(default = false)]
    pub markdown: bool,
}

// ── Conversions ───────────────────────────────────────────────────────

impl From<ithaca_model::Language> for Language {
    fn from(l: ithaca_model::Language) -> Self {
        match l {
            ithaca_model::Language::Ko => Language::Ko,
            ithaca_model::Language::En => Language::En,
        }
    }
}

impl From<Language> for ithaca_model::Language {
    fn from(l: Language) -> Self {
        match l {
            Language::Ko => ithaca_model::Language::Ko,
            Language::En => ithaca_model::Language::En,
        }
    }
}

impl From<ithaca_model::Goal> for Goal {
    fn from(g: ithaca_model::Goal) -> Self {
        use ithaca_model::GoalBasis as B;
        let basis = match g.basis {
            B::WithSpaces => GoalBasis::WithSpaces,
            B::WithoutSpaces => GoalBasis::WithoutSpaces,
            B::Words => GoalBasis::Words,
            B::Munpia => GoalBasis::Munpia,
            B::Novelpia => GoalBasis::Novelpia,
        };
        Goal {
            count: g.count,
            basis,
        }
    }
}

impl From<GoalBasis> for ithaca_model::GoalBasis {
    fn from(b: GoalBasis) -> Self {
        use ithaca_model::GoalBasis as B;
        match b {
            GoalBasis::WithSpaces => B::WithSpaces,
            GoalBasis::WithoutSpaces => B::WithoutSpaces,
            GoalBasis::Words => B::Words,
            GoalBasis::Munpia => B::Munpia,
            GoalBasis::Novelpia => B::Novelpia,
        }
    }
}

impl From<Goal> for ithaca_model::Goal {
    fn from(g: Goal) -> Self {
        ithaca_model::Goal {
            count: g.count,
            basis: g.basis.into(),
        }
    }
}

impl From<ithaca_model::Counts> for Counts {
    fn from(c: ithaca_model::Counts) -> Self {
        Counts {
            chars: c.chars,
            chars_no_space: c.chars_no_space,
            words: c.words,
            paragraphs: c.paragraphs,
        }
    }
}

impl From<store::ProjectSummary> for ProjectSummary {
    fn from(p: store::ProjectSummary) -> Self {
        ProjectSummary {
            id: p.id,
            title: p.title,
            language: p.language.into(),
            goal: p.goal.map(Into::into),
            created: p.created,
            modified: p.modified,
            deleted: p.deleted,
            sheets: p.sheets,
            counts: p.counts.into(),
        }
    }
}

impl From<store::SheetSummary> for SheetSummary {
    fn from(s: store::SheetSummary) -> Self {
        SheetSummary {
            id: s.id,
            folder: s.folder,
            order: s.order,
            title: s.title,
            excerpt: s.excerpt,
            counts: s.counts.into(),
            created: s.created,
            modified: s.modified,
            trashed: s.trashed,
            branched: s.branched,
            episode: s.episode.map(Into::into),
            damaged: s.damaged,
            entry: s.entry.map(Into::into),
        }
    }
}

impl From<ithaca_model::EpisodeInfo> for EpisodeInfo {
    fn from(e: ithaca_model::EpisodeInfo) -> Self {
        use ithaca_model::EpisodeStatus as S;
        EpisodeInfo {
            number: e.number,
            status: match e.status {
                S::Draft => EpisodeStatus::Draft,
                S::Revising => EpisodeStatus::Revising,
                S::Scheduled => EpisodeStatus::Scheduled,
                S::Published => EpisodeStatus::Published,
            },
            publish_at: e.publish_at,
            platform: e.platform,
            excluded: e.excluded,
        }
    }
}

impl From<EpisodeStatus> for ithaca_model::EpisodeStatus {
    fn from(s: EpisodeStatus) -> Self {
        use ithaca_model::EpisodeStatus as S;
        match s {
            EpisodeStatus::Draft => S::Draft,
            EpisodeStatus::Revising => S::Revising,
            EpisodeStatus::Scheduled => S::Scheduled,
            EpisodeStatus::Published => S::Published,
        }
    }
}

impl From<EpisodeInfo> for ithaca_model::EpisodeInfo {
    fn from(e: EpisodeInfo) -> Self {
        ithaca_model::EpisodeInfo {
            number: e.number,
            status: e.status.into(),
            publish_at: e.publish_at,
            platform: e.platform,
            excluded: e.excluded,
        }
    }
}

impl From<store::BackupInfo> for BackupInfo {
    fn from(b: store::BackupInfo) -> Self {
        use store::BackupKind as K;
        BackupInfo {
            path: b.path,
            at: b.at,
            bytes: b.bytes,
            kind: match b.kind {
                K::Auto => BackupKind::Auto,
                K::PreMigration => BackupKind::PreMigration,
                K::Manual => BackupKind::Manual,
            },
            projects: b.projects,
        }
    }
}

impl From<store::FolderInfo> for FolderInfo {
    fn from(f: store::FolderInfo) -> Self {
        FolderInfo {
            id: f.id,
            name: f.name,
            order: f.order,
            sheets: f.sheets.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<store::HistorySession> for HistorySession {
    fn from(g: store::HistorySession) -> Self {
        // Actor and kind come from the newest entry (the session shares them).
        let head: HistoryEntry = g
            .entries
            .first()
            .cloned()
            .map(Into::into)
            .expect("a session has at least one entry");
        HistorySession {
            start: g.start,
            end: g.end,
            device: g.device,
            actor: head.actor,
            kind: head.kind,
            added: g.added,
            removed: g.removed,
            base: g.base,
            entries: vec(g.entries),
        }
    }
}

impl From<store::HistoryEntry> for HistoryEntry {
    fn from(h: store::HistoryEntry) -> Self {
        use ithaca_ledger::{Actor as A, Kind as K};
        HistoryEntry {
            hash: h.hash,
            at: h.at,
            device: h.device,
            actor: match h.actor {
                A::Me => Actor::Me,
                A::Claude => Actor::Claude,
            },
            kind: match h.kind {
                K::Edit => BlockKind::Edit,
                K::Lease => BlockKind::Lease,
                K::Merge => BlockKind::Merge,
                K::Meta => BlockKind::Meta,
            },
            added: h.added,
            removed: h.removed,
        }
    }
}

impl From<store::IntegrityReport> for IntegrityReport {
    fn from(r: store::IntegrityReport) -> Self {
        use store::IssueKind as K;
        let issues = r
            .issues
            .into_iter()
            .map(|i| IntegrityIssue {
                file: i.file,
                sheet: i.sheet,
                kind: match i.kind {
                    K::Unreadable => IssueKind::Unreadable,
                    K::HashMismatch => IssueKind::HashMismatch,
                    K::MissingParent => IssueKind::MissingParent,
                    K::BadDelta => IssueKind::BadDelta,
                    K::UnexpectedFile => IssueKind::UnexpectedFile,
                },
                detail: i.detail,
            })
            .collect();
        IntegrityReport {
            ok: r.ok,
            blocks: r.blocks,
            chains: r.chains,
            issues,
        }
    }
}

impl From<store::SearchHit> for SearchHit {
    fn from(h: store::SearchHit) -> Self {
        SearchHit {
            project: h.project,
            sheet: h.sheet,
            title: h.title,
            offset: h.offset,
            length: h.length,
            snippet_before: h.snippet_before,
            snippet_match: h.snippet_match,
            snippet_after: h.snippet_after,
        }
    }
}

/// (added: docx) Word export layout. A4 portrait; sizes in points, margins in millimetres.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DocxOptions {
    #[uniffi(default = "맑은 고딕")]
    pub font: String,
    #[uniffi(default = 10.0)]
    pub font_size: f32,
    #[uniffi(default = 160)]
    pub line_spacing: u32,
    #[uniffi(default = true)]
    pub first_line_indent: bool,
    #[uniffi(default = true)]
    pub page_break: bool,
    #[uniffi(default = true)]
    pub include_titles: bool,
    #[uniffi(default = 20.0)]
    pub margin_top_mm: f32,
    #[uniffi(default = 15.0)]
    pub margin_bottom_mm: f32,
    #[uniffi(default = 30.0)]
    pub margin_left_mm: f32,
    #[uniffi(default = 30.0)]
    pub margin_right_mm: f32,
}

impl From<DocxOptions> for ithaca_model::DocxOptions {
    fn from(o: DocxOptions) -> Self {
        ithaca_model::DocxOptions {
            font: o.font,
            font_size: o.font_size,
            line_spacing: o.line_spacing,
            first_line_indent: o.first_line_indent,
            page_break: o.page_break,
            include_titles: o.include_titles,
            margin_top_mm: o.margin_top_mm,
            margin_bottom_mm: o.margin_bottom_mm,
            margin_left_mm: o.margin_left_mm,
            margin_right_mm: o.margin_right_mm,
        }
    }
}

impl From<ExportOptions> for ithaca_model::ExportOptions {
    fn from(o: ExportOptions) -> Self {
        ithaca_model::ExportOptions {
            blank_line: o.blank_line,
            indent: o.indent,
            strip_markdown: o.strip_markdown,
            include_title: o.include_title,
            markdown: o.markdown,
        }
    }
}

fn vec<T, U: From<T>>(v: Vec<T>) -> Vec<U> {
    v.into_iter().map(Into::into).collect()
}

// ── Library ───────────────────────────────────────────────────────────

/// An open library folder. All methods are safe to call from any thread; calls are serialized.
#[derive(uniffi::Object)]
pub struct Library {
    store: Mutex<Store>,
}

impl Library {
    fn lock(&self) -> MutexGuard<'_, Store> {
        // A panic mid-call leaves the files consistent (blocks are atomic), so keep going.
        self.store.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// For Rust callers and tests.
    pub fn from_store(store: Store) -> Arc<Library> {
        Arc::new(Library {
            store: Mutex::new(store),
        })
    }
}

type R<T> = Result<T, CoreError>;

#[uniffi::export]
impl Library {
    /// Opens (creating if missing) the library folder. Runs format migrations, backing up first
    /// (ADR-0008). A library newer than this core opens read-only.
    #[uniffi::constructor]
    pub fn open(path: String, device_id: String) -> R<Arc<Library>> {
        Ok(Library::from_store(Store::open(path, &device_id)?))
    }

    /// (added: r3) Opens an existing library for reading only: no lock, nothing written, every
    /// write → ReadOnly. A snapshot of the moment it opened. No `library.json` → NotFound.
    #[uniffi::constructor]
    pub fn open_read_only(path: String) -> R<Arc<Library>> {
        Ok(Library::from_store(Store::open_read_only(path)?))
    }

    pub fn info(&self) -> LibraryInfo {
        let i = self.lock().info();
        LibraryInfo {
            format: i.format,
            core_version: core_version(),
            read_only: i.read_only,
            migrated_from: i.migrated_from,
            backup_path: i.backup_path,
            locked_by_other: i.locked_by_other,
            problems: i.problems,
        }
    }

    // Projects

    pub fn projects(&self) -> Vec<ProjectSummary> {
        vec(self.lock().projects())
    }

    pub fn create_project(
        &self,
        title: String,
        language: Language,
        folders: Vec<String>,
    ) -> R<ProjectSummary> {
        Ok(self
            .lock()
            .create_project(&title, language.into(), &folders)?
            .into())
    }

    pub fn update_project(&self, id: String, patch: ProjectPatch) -> R<ProjectSummary> {
        let patch = store::ProjectPatch {
            title: patch.title,
            language: patch.language.map(Into::into),
            goal: patch.goal.map(Into::into),
        };
        Ok(self.lock().update_project(&id, patch)?.into())
    }

    pub fn delete_project(&self, id: String) -> R<()> {
        Ok(self.lock().delete_project(&id)?)
    }

    pub fn restore_project(&self, id: String) -> R<()> {
        Ok(self.lock().restore_project(&id)?)
    }

    pub fn deleted_projects(&self) -> Vec<ProjectSummary> {
        vec(self.lock().deleted_projects())
    }

    // Outline, folders, sheets

    pub fn outline(&self, project: String) -> R<Outline> {
        let o = self.lock().outline(&project)?;
        Ok(Outline {
            project: o.project.into(),
            folders: vec(o.folders),
            trash: vec(o.trash),
        })
    }

    pub fn create_folder(&self, project: String, name: String) -> R<FolderInfo> {
        Ok(self.lock().create_folder(&project, &name)?.into())
    }

    pub fn rename_folder(&self, project: String, folder: String, name: String) -> R<()> {
        Ok(self.lock().rename_folder(&project, &folder, &name)?)
    }

    pub fn delete_folder(&self, project: String, folder: String) -> R<()> {
        Ok(self.lock().delete_folder(&project, &folder)?)
    }

    pub fn restore_folder(&self, project: String, folder: String) -> R<()> {
        Ok(self.lock().restore_folder(&project, &folder)?)
    }

    pub fn create_sheet(&self, project: String, folder: String, text: String) -> R<SheetSummary> {
        Ok(self.lock().create_sheet(&project, &folder, &text)?.into())
    }

    pub fn sheet_text(&self, project: String, sheet: String) -> R<String> {
        Ok(self.lock().sheet_text(&project, &sheet)?)
    }

    pub fn save_sheet(&self, project: String, sheet: String, text: String) -> R<SheetSummary> {
        Ok(self.lock().save_sheet(&project, &sheet, &text)?.into())
    }

    pub fn move_sheet(
        &self,
        project: String,
        sheet: String,
        folder: String,
        before: Option<String>,
    ) -> R<()> {
        Ok(self
            .lock()
            .move_sheet(&project, &sheet, &folder, before.as_deref())?)
    }

    pub fn trash_sheet(&self, project: String, sheet: String) -> R<()> {
        Ok(self.lock().trash_sheet(&project, &sheet)?)
    }

    pub fn restore_sheet(&self, project: String, sheet: String) -> R<()> {
        Ok(self.lock().restore_sheet(&project, &sheet)?)
    }

    pub fn delete_sheet_forever(&self, project: String, sheet: String) -> R<()> {
        Ok(self.lock().delete_sheet_forever(&project, &sheet)?)
    }

    pub fn empty_trash(&self, project: String) -> R<()> {
        Ok(self.lock().empty_trash(&project)?)
    }

    // History

    pub fn history(&self, project: String, sheet: String) -> R<Vec<HistoryEntry>> {
        Ok(vec(self.lock().history(&project, &sheet)?))
    }

    pub fn history_sessions(&self, project: String, sheet: String) -> R<Vec<HistorySession>> {
        Ok(vec(self.lock().history_sessions(&project, &sheet)?))
    }

    pub fn text_at(&self, project: String, sheet: String, hash: String) -> R<String> {
        Ok(self.lock().text_at(&project, &sheet, &hash)?)
    }

    pub fn restore_version(&self, project: String, sheet: String, hash: String) -> R<SheetSummary> {
        Ok(self.lock().restore_version(&project, &sheet, &hash)?.into())
    }

    pub fn verify(&self, project: String) -> R<IntegrityReport> {
        Ok(self.lock().verify(&project)?.into())
    }

    // Search, import, export

    pub fn search(&self, query: String, project: Option<String>) -> Vec<SearchHit> {
        vec(self.lock().search(&query, project.as_deref()))
    }

    pub fn import_web_backup(&self, json: String) -> R<ImportReport> {
        Ok(self.lock().import_web_backup(&json)?.into())
    }

    pub fn export_text(
        &self,
        project: String,
        sheets: Vec<String>,
        options: ExportOptions,
    ) -> R<String> {
        Ok(self
            .lock()
            .export_text(&project, &sheets, &options.into())?)
    }

    /// (added: docx) The sheets as a .docx file's bytes; write them where the user chose.
    pub fn export_docx(
        &self,
        project: String,
        sheets: Vec<String>,
        options: DocxOptions,
    ) -> R<Vec<u8>> {
        Ok(self
            .lock()
            .export_docx(&project, &sheets, &options.into())?)
    }

    // Episodes (added round 2)

    pub fn set_episode(
        &self,
        project: String,
        sheet: String,
        info: Option<EpisodeInfo>,
    ) -> R<SheetSummary> {
        Ok(self
            .lock()
            .set_episode(&project, &sheet, info.map(Into::into))?
            .into())
    }

    pub fn stock(&self, project: String, folder: String) -> R<u32> {
        Ok(self.lock().stock(&project, &folder)?)
    }

    pub fn renumber_episodes(&self, project: String, folder: String) -> R<u32> {
        Ok(self.lock().renumber_episodes(&project, &folder)?)
    }

    // Backups (added round 2)

    pub fn backup_now(&self) -> R<BackupInfo> {
        Ok(self.lock().backup_now()?.into())
    }

    pub fn backup_manual(&self) -> R<BackupInfo> {
        Ok(self.lock().backup_manual()?.into())
    }

    pub fn backups(&self) -> Vec<BackupInfo> {
        vec(self.lock().backups())
    }

    pub fn backup_due(&self) -> bool {
        self.lock().backup_due()
    }

    pub fn backups_dir(&self) -> String {
        self.lock().backups_dir().to_string_lossy().into_owned()
    }

    pub fn restore_backup_as_copies(&self, path: String) -> R<Vec<ProjectSummary>> {
        Ok(vec(self.lock().restore_backup_as_copies(&path)?))
    }

    // Added: qa1

    /// Like `restore_backup_as_copies`, with `suffix` appended to every title ("" = as is).
    pub fn restore_backup_as_copies_with_suffix(
        &self,
        path: String,
        suffix: String,
    ) -> R<Vec<ProjectSummary>> {
        Ok(vec(self
            .lock()
            .restore_backup_as_copies_with_suffix(&path, &suffix)?))
    }

    /// Like `import_web_backup`, with `suffix` appended to every title ("" = as is).
    pub fn import_web_backup_with_suffix(&self, json: String, suffix: String) -> R<ImportReport> {
        Ok(self
            .lock()
            .import_web_backup_with_suffix(&json, &suffix)?
            .into())
    }

    /// (added: txt-import) A folder of `.txt` / `.md` manuscripts → one new project. All or nothing.
    pub fn import_text_folder(
        &self,
        path: String,
        title: Option<String>,
        language: Option<Language>,
    ) -> R<ImportReport> {
        Ok(self
            .lock()
            .import_text_folder(&path, title.as_deref(), language.map(Into::into))?
            .into())
    }

    /// Every live project, `current` first; ≤ 200 hits per project, ≤ 500 in all.
    pub fn search_all(&self, query: String, current: Option<String>) -> Vec<SearchHit> {
        vec(self.lock().search_all(&query, current.as_deref()))
    }

    /// Sets `status` on every live sheet of `folder` up to and including `sheet` (serial order).
    pub fn set_status_through(
        &self,
        project: String,
        folder: String,
        sheet: String,
        status: EpisodeStatus,
    ) -> R<u32> {
        Ok(self
            .lock()
            .set_status_through(&project, &folder, &sheet, status.into())?)
    }

    pub fn damaged_sheets(&self, project: String) -> R<Vec<SheetSummary>> {
        Ok(vec(self.lock().damaged_sheets(&project)?))
    }

    pub fn recover_sheet_from_backup(&self, project: String, sheet: String) -> R<SheetSummary> {
        Ok(self
            .lock()
            .recover_sheet_from_backup(&project, &sheet)?
            .into())
    }

    pub fn keep_last_good_text(&self, project: String, sheet: String) -> R<SheetSummary> {
        Ok(self.lock().keep_last_good_text(&project, &sheet)?.into())
    }

    // Added: r3

    /// Earliest future `publish_at` among the folder's live Scheduled sheets.
    pub fn next_release(&self, project: String, folder: String) -> R<Option<i64>> {
        Ok(self.lock().next_release(&project, &folder)?)
    }

    pub fn folder_stats(&self, project: String, folder: String) -> R<FolderStats> {
        Ok(self.lock().folder_stats(&project, &folder)?.into())
    }

    /// (added: bible) Every live entry of the project, most recently seen first (never seen last,
    /// then by name).
    pub fn bible(&self, project: String) -> R<Vec<BibleEntry>> {
        Ok(vec(self.lock().bible(&project)?))
    }

    /// (added: bible) Mentions of matchable entries in `text` (may be unsaved): in order,
    /// non-overlapping, longest first; the text's own front matter (and own name) skipped.
    pub fn mentions_in(&self, project: String, text: String) -> R<Vec<Mention>> {
        Ok(vec(self.lock().mentions_in(&project, &text)?))
    }

    /// (added: bible) Every live non-entry sheet mentioning the entry, in reading order.
    pub fn appearances(&self, project: String, entry: String) -> R<Vec<Appearance>> {
        Ok(vec(self.lock().appearances(&project, &entry)?))
    }

    /// (added: bible) Creates the previewed entry texts at the end of `folder`, in order. All or
    /// nothing. Returns the new sheet ids.
    pub fn import_bible(
        &self,
        project: String,
        folder: String,
        entries: Vec<String>,
    ) -> R<Vec<String>> {
        Ok(self.lock().import_bible(&project, &folder, &entries)?)
    }

    /// `<library>/mcp.json`; off with no projects when missing or unreadable.
    pub fn mcp_settings(&self) -> McpSettings {
        self.lock().mcp_settings().into()
    }

    /// Rewrites `<library>/mcp.json` atomically (permission stays Read). Read-only → ReadOnly.
    pub fn set_mcp_settings(&self, enabled: bool, projects: Vec<String>) -> R<McpSettings> {
        Ok(self.lock().set_mcp_settings(enabled, &projects)?.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// (added: docx) A real file through the FFI; on macOS also read back by `textutil`, which
    /// parses .docx the way Pages / TextEdit do.
    #[test]
    fn export_docx_through_ffi() {
        let dir = tempfile::tempdir().unwrap();
        let lib =
            Library::open(dir.path().join("lib").to_string_lossy().into(), "d".into()).unwrap();
        let p = lib
            .create_project("작품 & 시험".into(), Language::Ko, vec!["연재".into()])
            .unwrap();
        let o = lib.outline(p.id.clone()).unwrap();
        let s1 = o.folders[0].sheets[0].id.clone();
        lib.save_sheet(
            p.id.clone(),
            s1,
            "# 1화\n그날 밤, **비가** 왔다.\n***\n끝 <꼭> & 끝.".into(),
        )
        .unwrap();
        lib.create_sheet(
            p.id.clone(),
            o.folders[0].id.clone(),
            "# 2화\n둘째 날.".into(),
        )
        .unwrap();
        let opts = DocxOptions {
            font: "맑은 고딕".into(),
            font_size: 10.0,
            line_spacing: 160,
            first_line_indent: true,
            page_break: true,
            include_titles: true,
            margin_top_mm: 20.0,
            margin_bottom_mm: 15.0,
            margin_left_mm: 30.0,
            margin_right_mm: 30.0,
        };
        let bytes = lib.export_docx(p.id.clone(), vec![], opts.clone()).unwrap();
        assert_eq!(&bytes[..2], b"PK");
        assert!(matches!(
            lib.export_docx(p.id.clone(), vec!["nope".into()], opts),
            Err(CoreError::NotFound)
        ));

        if cfg!(target_os = "macos") {
            let path = dir.path().join("out.docx");
            std::fs::write(&path, &bytes).unwrap();
            let out = std::process::Command::new("textutil")
                .args(["-convert", "txt", "-stdout"])
                .arg(&path)
                .output()
                .expect("textutil ships with macOS");
            assert!(out.status.success(), "textutil could not read the file");
            {
                let text = String::from_utf8(out.stdout).unwrap();
                let lines: Vec<&str> = text
                    .lines()
                    .map(|l| l.trim_matches(|c: char| c.is_whitespace() || c == '\u{c}'))
                    .filter(|l| !l.is_empty())
                    .collect();
                assert_eq!(
                    lines,
                    [
                        "1화",
                        "그날 밤, 비가 왔다.",
                        "* * *",
                        "끝 <꼭> & 끝.",
                        "2화",
                        "둘째 날."
                    ]
                );
            }
        }
    }

    #[test]
    fn library_is_send_and_sync() {
        fn check<T: Send + Sync>() {}
        check::<Library>();
    }

    #[test]
    fn roundtrip_through_the_ffi_surface() {
        let dir = tempfile::tempdir().unwrap();
        let lib = Library::open(dir.path().to_string_lossy().into(), "mac-1".into()).unwrap();
        let info = lib.info();
        assert_eq!((info.format, info.read_only), (1, false));
        let p = lib
            .create_project(
                "작품".into(),
                Language::Ko,
                vec!["연재".into(), "설정".into()],
            )
            .unwrap();
        let o = lib.outline(p.id.clone()).unwrap();
        let sheet = o.folders[0].sheets[0].id.clone();
        let s = lib
            .save_sheet(p.id.clone(), sheet.clone(), "# 1화\n안녕 😀".into())
            .unwrap();
        assert_eq!(s.title, "1화");
        let hits = lib.search("😀".into(), None);
        assert_eq!(hits[0].offset, "# 1화\n안녕 ".encode_utf16().count() as u32);
        assert_eq!(hits[0].length, 2);
        let out = lib
            .export_text(
                p.id.clone(),
                vec![sheet],
                ExportOptions {
                    blank_line: true,
                    indent: true,
                    strip_markdown: true,
                    include_title: true,
                    markdown: false,
                },
            )
            .unwrap();
        assert_eq!(out, "1화\n\n\u{3000}안녕 😀");
        assert!(matches!(
            lib.outline("nope".into()),
            Err(CoreError::NotFound)
        ));
        let p2 = lib
            .update_project(
                p.id,
                ProjectPatch {
                    goal: Some(Goal {
                        count: 5000,
                        basis: GoalBasis::WithSpaces,
                    }),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(p2.goal.map(|g| g.count), Some(5000));
    }

    #[test]
    fn round_2_additions() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("Library");
        let lib = Library::open(path.to_string_lossy().into(), "mac-1".into()).unwrap();
        let p = lib
            .create_project("작품".into(), Language::Ko, vec!["연재".into()])
            .unwrap();
        let o = lib.outline(p.id.clone()).unwrap();
        let (folder, sheet) = (o.folders[0].id.clone(), o.folders[0].sheets[0].id.clone());
        assert_eq!(o.folders[0].sheets[0].episode, None);
        let s = lib
            .set_episode(
                p.id.clone(),
                sheet,
                Some(EpisodeInfo {
                    status: EpisodeStatus::Published,
                    ..Default::default()
                }),
            )
            .unwrap();
        assert_eq!(
            s.episode.as_ref().map(|e| e.status),
            Some(EpisodeStatus::Published)
        );
        assert_eq!(
            lib.renumber_episodes(p.id.clone(), folder.clone()).unwrap(),
            1
        );
        assert_eq!(lib.stock(p.id.clone(), folder).unwrap(), 0);

        assert!(!lib.backup_due(), "nothing to back up yet");
        let first = lib.outline(p.id.clone()).unwrap().folders[0].sheets[0]
            .id
            .clone();
        lib.save_sheet(p.id.clone(), first, "글".into()).unwrap();
        assert!(lib.backup_due());
        let b = lib.backup_now().unwrap();
        assert_eq!(b.kind, BackupKind::Auto);
        assert!(!lib.backup_due());
        assert_eq!(lib.backups(), vec![b.clone()]);
        assert!(b.path.starts_with(&lib.backups_dir()));
        let copies = lib.restore_backup_as_copies(b.path).unwrap();
        assert_eq!(copies[0].title, "작품");

        assert_eq!(count_for("\"가!\" 나.".into(), CountRule::Novelpia), 2);
        assert_eq!(count_for("가 나\n".into(), CountRule::Munpia), 3);
        assert_eq!(count_for("가".into(), CountRule::BytesUtf8), 3);
        assert_eq!(munpia_pages("가".repeat(471)), 2);
    }

    #[test]
    fn r3_additions() {
        let dir = tempfile::tempdir().unwrap();
        let path: String = dir.path().join("Library").to_string_lossy().into();
        assert!(matches!(
            Library::open_read_only(path.clone()),
            Err(CoreError::NotFound)
        ));
        let lib = Library::open(path.clone(), "mac-1".into()).unwrap();
        let p = lib
            .create_project("작품".into(), Language::Ko, vec!["연재".into()])
            .unwrap();
        let o = lib.outline(p.id.clone()).unwrap();
        let (folder, sheet) = (o.folders[0].id.clone(), o.folders[0].sheets[0].id.clone());
        lib.save_sheet(p.id.clone(), sheet.clone(), "# 프롤로그\n\n밤".into())
            .unwrap();
        lib.set_episode(
            p.id.clone(),
            sheet,
            Some(EpisodeInfo {
                excluded: true,
                ..Default::default()
            }),
        )
        .unwrap();
        assert_eq!(
            lib.renumber_episodes(p.id.clone(), folder.clone()).unwrap(),
            0
        );
        assert_eq!(lib.stock(p.id.clone(), folder.clone()).unwrap(), 0);
        let st = lib.folder_stats(p.id.clone(), folder.clone()).unwrap();
        assert_eq!((st.sheets, st.episodes, st.munpia_total), (1, 0, 1));
        assert_eq!(lib.next_release(p.id.clone(), folder).unwrap(), None);
        assert_eq!(goal_count("# 제목\n\n가 나".into(), GoalBasis::Munpia), 3);
        assert_eq!(platform_body("# 제목\n\n가 나".into()), "가 나");

        assert!(!lib.mcp_settings().enabled);
        let m = lib.set_mcp_settings(true, vec![p.id.clone()]).unwrap();
        assert_eq!(m.permission, McpPermission::Read);
        let ro = Library::open_read_only(path).unwrap();
        assert!(ro.info().read_only);
        assert_eq!(ro.mcp_settings(), m);
        assert!(matches!(
            ro.set_mcp_settings(false, vec![]),
            Err(CoreError::ReadOnly)
        ));
    }

    /// (added: bible) The story bible through the FFI.
    #[test]
    fn bible_through_ffi() {
        let dir = tempfile::tempdir().unwrap();
        let lib =
            Library::open(dir.path().join("lib").to_string_lossy().into(), "d".into()).unwrap();
        let p = lib
            .create_project(
                "작품".into(),
                Language::Ko,
                vec!["연재".into(), "설정".into()],
            )
            .unwrap();
        let o = lib.outline(p.id.clone()).unwrap();
        let ep = o.folders[0].sheets[0].id.clone();
        lib.save_sheet(p.id.clone(), ep.clone(), "# 1화\n\n“서윤아!”".into())
            .unwrap();
        let t = entry_template(EntryKind::Character, "서윤".into(), Language::Ko);
        let e = parse_entry(t.clone()).unwrap();
        assert_eq!(e.kind, EntryKind::Character);
        assert_eq!(e.sections[0].title, "한 줄 소개");
        assert!(parse_entry("---\n장면\n---".into()).is_none());
        let s = lib
            .create_sheet(p.id.clone(), o.folders[1].id.clone(), t)
            .unwrap();
        assert_eq!(s.entry, Some(EntryKind::Character));
        assert_eq!(s.title, "서윤");
        let b = lib.bible(p.id.clone()).unwrap();
        assert_eq!(b.len(), 1);
        assert_eq!(b[0].last_seen.as_ref().unwrap().sheet, ep);
        let m = lib.mentions_in(p.id.clone(), "서윤이가".into()).unwrap();
        assert_eq!((m[0].offset, m[0].length, m[0].alias), (0, 2, false));
        let a = lib.appearances(p.id.clone(), s.id.clone()).unwrap();
        assert_eq!(a[0].lines, ["“서윤아!”"]);
        let src = dir.path().join("해원.md");
        std::fs::write(&src, "# 해원\n\n나이: 18\n").unwrap();
        let pv = bible_import_preview(
            src.to_string_lossy().into(),
            EntryKind::Character,
            Language::Ko,
        )
        .unwrap();
        assert_eq!((pv[0].name.as_str(), pv[0].fields), ("해원", 1));
        let ids = lib
            .import_bible(
                p.id.clone(),
                o.folders[1].id.clone(),
                vec![pv[0].text.clone()],
            )
            .unwrap();
        assert_eq!(ids.len(), 1);
        assert_eq!(lib.bible(p.id).unwrap().len(), 2);
    }
}
