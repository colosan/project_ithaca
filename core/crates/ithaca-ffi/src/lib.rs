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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ImportReport {
    pub projects: u32,
    pub folders: u32,
    pub sheets: u32,
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
        };
        Goal {
            count: g.count,
            basis,
        }
    }
}

impl From<Goal> for ithaca_model::Goal {
    fn from(g: Goal) -> Self {
        use ithaca_model::GoalBasis as B;
        let basis = match g.basis {
            GoalBasis::WithSpaces => B::WithSpaces,
            GoalBasis::WithoutSpaces => B::WithoutSpaces,
            GoalBasis::Words => B::Words,
        };
        ithaca_model::Goal {
            count: g.count,
            basis,
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

    pub fn info(&self) -> LibraryInfo {
        let i = self.lock().info();
        LibraryInfo {
            format: i.format,
            core_version: core_version(),
            read_only: i.read_only,
            migrated_from: i.migrated_from,
            backup_path: i.backup_path,
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
        let r = self.lock().import_web_backup(&json)?;
        Ok(ImportReport {
            projects: r.projects,
            folders: r.folders,
            sheets: r.sheets,
        })
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
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
