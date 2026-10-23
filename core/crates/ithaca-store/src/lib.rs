//! Filesystem store for an Ithaca library (ADR-0002, ADR-0008, core/FORMAT.md).
//!
//! [`Store`] is single-threaded; ithaca-ffi wraps it in a `Mutex`.

pub mod error;
pub mod format;
pub mod fsutil;
mod import;
pub mod project;
mod search;
pub mod types;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use ithaca_ledger::{Actor, Block, Body, Kind, Meta, Op, delta};
use ithaca_model::{
    ExportOptions, FolderEntry, Language, RETENTION_MS, SheetEntry, Toc, excerpt_of, export_sheets,
    title_of,
};

pub use error::{Result, StoreError};
pub use format::{FORMAT, Migration};
pub use types::*;

use format::{PROJECTS_DIR, Prepared, prepare};
use project::{Project, write_block, write_cache};

/// A delta chain longer than this gets a full snapshot, so reading any version touches at most
/// this many blocks.
pub const SNAPSHOT_EVERY: u32 = 32;

pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

pub fn system_clock() -> Clock {
    Arc::new(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    })
}

/// How to open: which format this build supports and how to get there. Tests use other values to
/// prove the migration machinery before the first real migration exists.
#[derive(Clone)]
pub struct OpenOptions {
    pub supported_format: u32,
    pub migrations: Vec<Migration>,
    pub clock: Clock,
}

impl Default for OpenOptions {
    fn default() -> Self {
        Self {
            supported_format: FORMAT,
            migrations: format::migrations(),
            clock: system_clock(),
        }
    }
}

pub struct Store {
    root: PathBuf,
    device: String,
    prepared: Prepared,
    clock: Clock,
    /// In creation order is computed on demand; keyed by id.
    projects: BTreeMap<String, Project>,
}

fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

fn invalid(msg: impl Into<String>) -> StoreError {
    StoreError::InvalidInput(msg.into())
}

impl Store {
    pub fn open(path: impl AsRef<Path>, device: &str) -> Result<Store> {
        Self::open_with(path, device, OpenOptions::default())
    }

    pub fn open_with(path: impl AsRef<Path>, device: &str, opts: OpenOptions) -> Result<Store> {
        if device.trim().is_empty() {
            return Err(invalid("device id is empty"));
        }
        let root = path.as_ref().to_path_buf();
        let now = (opts.clock)();
        let prepared = prepare(&root, opts.supported_format, &opts.migrations, now)?;
        let writable = !prepared.read_only;
        let mut projects = BTreeMap::new();
        for name in fsutil::list(&root.join(PROJECTS_DIR))? {
            let dir = root.join(PROJECTS_DIR).join(&name);
            if name.starts_with('.') || !dir.is_dir() {
                continue;
            }
            if let Some(p) = Project::load(&name, &dir, writable)? {
                projects.insert(name, p);
            }
        }
        let mut store = Store {
            root,
            device: device.to_string(),
            prepared,
            clock: opts.clock,
            projects,
        };
        if writable {
            store.purge_expired()?;
        }
        Ok(store)
    }

    pub fn info(&self) -> LibraryInfo {
        LibraryInfo {
            format: self.prepared.format,
            read_only: self.prepared.read_only,
            migrated_from: self.prepared.migrated_from,
            backup_path: self
                .prepared
                .backup_path
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned()),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn now(&self) -> i64 {
        (self.clock)()
    }

    fn writable(&self) -> Result<()> {
        if self.prepared.read_only {
            Err(StoreError::ReadOnly)
        } else {
            Ok(())
        }
    }

    fn project(&self, id: &str) -> Result<&Project> {
        self.projects.get(id).ok_or(StoreError::NotFound)
    }

    fn project_mut(&mut self, id: &str) -> Result<&mut Project> {
        self.projects.get_mut(id).ok_or(StoreError::NotFound)
    }

    // ── Writing blocks ────────────────────────────────────────────────

    /// Appends a block to a chain when the text changed (or when the chain is new). Returns whether
    /// a block was written.
    fn append(
        &mut self,
        project: &str,
        sheet: &str,
        text: &str,
        kind: Kind,
        at: i64,
    ) -> Result<bool> {
        self.writable()?;
        let device = self.device.clone();
        let p = self.project_mut(project)?;
        let chain = p.chains.entry(sheet.to_string()).or_default();
        let parent = chain.head().cloned();
        if parent.is_some() && chain.text == text {
            return Ok(false);
        }
        let (body, depth, stats) = match &parent {
            None => (
                Body::Snapshot(text.to_string()),
                0,
                delta::apply("", &delta::diff("", text))
                    .map(|r| r.1)
                    .unwrap_or_default(),
            ),
            Some(pm) => {
                let ops: Vec<Op> = delta::diff(&chain.text, text);
                let stats = delta::apply(&chain.text, &ops)
                    .map_err(|e| StoreError::Corrupt(e.to_string()))?
                    .1;
                let delta_len = serde_json::to_string(&ops)
                    .map(|s| s.len())
                    .unwrap_or(usize::MAX);
                let snap_len = serde_json::to_string(text).map(|s| s.len()).unwrap_or(0);
                if pm.depth + 1 >= SNAPSHOT_EVERY || delta_len >= snap_len {
                    (Body::Snapshot(text.to_string()), 0, stats)
                } else {
                    (Body::Delta(ops), pm.depth + 1, stats)
                }
            }
        };
        let parents = parent
            .as_ref()
            .map(|m| vec![m.hash.clone()])
            .unwrap_or_default();
        let epoch = parent.as_ref().map_or(1, |m| m.epoch);
        let block = Block::seal(parents, sheet, epoch, device, Actor::Me, kind, at, body);
        write_block(&p.dir, &block)?;
        let chain = p.chains.get_mut(sheet).expect("chain exists");
        chain.push(Meta::of(&block, depth, stats), text.to_string());
        write_cache(&p.dir, sheet, chain);
        Ok(true)
    }

    /// Applies a change to a project's table of contents and records it as a `meta` block.
    fn edit_toc<T>(
        &mut self,
        project: &str,
        f: impl FnOnce(&mut Toc, i64) -> Result<T>,
    ) -> Result<T> {
        self.writable()?;
        let now = self.now();
        let p = self.project_mut(project)?;
        let mut toc = p.toc.clone();
        let out = f(&mut toc, now)?;
        if toc != p.toc {
            let text = toc.to_text();
            self.append(project, Toc::SHEET_ID, &text, Kind::Meta, now)?;
            self.project_mut(project)?.toc = toc;
        }
        Ok(out)
    }

    // ── Summaries ─────────────────────────────────────────────────────

    fn sheet_summary(p: &Project, sheet: &str) -> Result<SheetSummary> {
        let entry = p.toc.sheets.get(sheet).ok_or(StoreError::NotFound)?;
        let (fi, slot) = p.toc.locate(sheet).ok_or(StoreError::NotFound)?;
        let folder = &p.toc.folders[fi];
        let order = if entry.trashed.is_some() {
            slot
        } else {
            p.toc
                .live_sheets(folder)
                .position(|s| s == sheet)
                .unwrap_or(slot)
        };
        let chain = p.chains.get(sheet);
        let text = chain.map_or("", |c| c.text.as_str());
        Ok(SheetSummary {
            id: sheet.to_string(),
            folder: folder.id.clone(),
            order: order as u32,
            title: title_of(text),
            excerpt: excerpt_of(text),
            counts: chain.map(|c| c.counts).unwrap_or_default(),
            created: entry.created,
            modified: chain.and_then(|c| c.head()).map_or(entry.created, |m| m.at),
            trashed: entry.trashed,
            branched: chain.is_some_and(|c| c.branched()),
        })
    }

    /// Live sheets in reading order: live folders in order, then serial order.
    fn reading_order(p: &Project) -> Vec<String> {
        p.toc
            .folders
            .iter()
            .filter(|f| f.deleted.is_none())
            .flat_map(|f| p.toc.live_sheets(f).cloned().collect::<Vec<_>>())
            .collect()
    }

    fn project_summary(p: &Project) -> ProjectSummary {
        let live = Self::reading_order(p);
        let counts = live
            .iter()
            .filter_map(|s| p.chains.get(s))
            .map(|c| c.counts)
            .fold(Default::default(), |a, b| a + b);
        let modified = p
            .chains
            .values()
            .filter_map(|c| c.head())
            .map(|m| m.at)
            .max()
            .unwrap_or(p.toc.created);
        ProjectSummary {
            id: p.id.clone(),
            title: p.toc.title.clone(),
            language: p.toc.language,
            goal: p.toc.goal,
            created: p.toc.created,
            modified,
            deleted: p.toc.deleted,
            sheets: live.len() as u32,
            counts,
        }
    }

    fn sorted_projects(&self) -> Vec<&Project> {
        let mut v: Vec<&Project> = self.projects.values().collect();
        v.sort_by(|a, b| {
            a.toc
                .created
                .cmp(&b.toc.created)
                .then_with(|| a.id.cmp(&b.id))
        });
        v
    }

    // ── Projects ──────────────────────────────────────────────────────

    /// Live projects in creation order.
    pub fn projects(&self) -> Vec<ProjectSummary> {
        self.sorted_projects()
            .into_iter()
            .filter(|p| p.toc.deleted.is_none())
            .map(Self::project_summary)
            .collect()
    }

    /// Soft-deleted projects, most recently deleted first.
    pub fn deleted_projects(&self) -> Vec<ProjectSummary> {
        let mut v: Vec<ProjectSummary> = self
            .sorted_projects()
            .into_iter()
            .filter(|p| p.toc.deleted.is_some())
            .map(Self::project_summary)
            .collect();
        v.sort_by_key(|p| std::cmp::Reverse(p.deleted));
        v
    }

    pub fn project_summary_of(&self, id: &str) -> Result<ProjectSummary> {
        Ok(Self::project_summary(self.project(id)?))
    }

    /// A new project with the given folders and one empty sheet in the first (as the web app does).
    pub fn create_project(
        &mut self,
        title: &str,
        language: Language,
        folders: &[String],
    ) -> Result<ProjectSummary> {
        let toc = Toc {
            title: title.to_string(),
            language,
            created: self.now(),
            folders: folders
                .iter()
                .map(|name| FolderEntry {
                    id: new_id(),
                    name: name.clone(),
                    deleted: None,
                    sheets: vec![],
                })
                .collect(),
            ..Default::default()
        };
        let now = toc.created;
        self.create_project_from(toc, &[(0, String::new(), now, now)])
    }

    /// Writes a new project: its sheets first, then the table of contents that names them, so a crash
    /// in between leaves only invisible orphans. `sheets` are (folder index, text, created, modified).
    fn create_project_from(
        &mut self,
        mut toc: Toc,
        sheets: &[(usize, String, i64, i64)],
    ) -> Result<ProjectSummary> {
        self.writable()?;
        if toc.folders.is_empty() {
            return Err(invalid("a project needs at least one folder"));
        }
        let id = new_id();
        let dir = self.root.join(PROJECTS_DIR).join(&id);
        fs::create_dir_all(project::changes_dir(&dir))?;
        self.projects.insert(
            id.clone(),
            Project {
                id: id.clone(),
                dir,
                toc: Toc::default(),
                chains: Default::default(),
            },
        );
        let result = (|| {
            for (folder, text, created, modified) in sheets {
                let sid = new_id();
                self.append(&id, &sid, text, Kind::Edit, *modified)?;
                toc.folders[*folder].sheets.push(sid.clone());
                toc.sheets.insert(
                    sid,
                    SheetEntry {
                        created: *created,
                        trashed: None,
                    },
                );
            }
            let at = self.now();
            self.append(&id, Toc::SHEET_ID, &toc.to_text(), Kind::Meta, at)?;
            self.project_mut(&id)?.toc = toc;
            Ok(())
        })();
        if let Err(e) = result {
            if let Some(p) = self.projects.remove(&id) {
                let _ = fs::remove_dir_all(&p.dir);
            }
            return Err(e);
        }
        self.project_summary_of(&id)
    }

    pub fn update_project(&mut self, id: &str, patch: ProjectPatch) -> Result<ProjectSummary> {
        self.edit_toc(id, |t, _| {
            if let Some(title) = patch.title {
                t.title = title;
            }
            if let Some(lang) = patch.language {
                t.language = lang;
            }
            if let Some(goal) = patch.goal {
                t.goal = (goal.count > 0).then_some(goal);
            }
            Ok(())
        })?;
        self.project_summary_of(id)
    }

    /// Soft delete: hidden, kept 30 days, then removed when the library is opened.
    pub fn delete_project(&mut self, id: &str) -> Result<()> {
        self.edit_toc(id, |t, now| {
            t.deleted.get_or_insert(now);
            Ok(())
        })
    }

    pub fn restore_project(&mut self, id: &str) -> Result<()> {
        self.edit_toc(id, |t, _| {
            t.deleted = None;
            Ok(())
        })
    }

    /// Drops projects deleted, and trashed sheets trashed, more than 30 days ago. Runs on open.
    pub fn purge_expired(&mut self) -> Result<()> {
        self.writable()?;
        let cutoff = self.now() - RETENTION_MS;
        let expired: Vec<String> = self
            .projects
            .values()
            .filter(|p| p.toc.deleted.is_some_and(|d| d <= cutoff))
            .map(|p| p.id.clone())
            .collect();
        for id in expired {
            if let Some(p) = self.projects.remove(&id) {
                fs::remove_dir_all(&p.dir)?;
            }
        }
        let ids: Vec<String> = self.projects.keys().cloned().collect();
        for id in ids {
            let old: Vec<String> = self
                .project(&id)?
                .toc
                .sheets
                .iter()
                .filter(|(_, e)| e.trashed.is_some_and(|t| t <= cutoff))
                .map(|(s, _)| s.clone())
                .collect();
            if !old.is_empty() {
                self.delete_sheets_forever(&id, &old)?;
            }
        }
        Ok(())
    }

    // ── Outline, folders ──────────────────────────────────────────────

    pub fn outline(&self, project: &str) -> Result<Outline> {
        let p = self.project(project)?;
        let mut folders = Vec::new();
        for f in p.toc.folders.iter().filter(|f| f.deleted.is_none()) {
            let sheets = p
                .toc
                .live_sheets(f)
                .map(|s| Self::sheet_summary(p, s))
                .collect::<Result<Vec<_>>>()?;
            folders.push(FolderInfo {
                id: f.id.clone(),
                name: f.name.clone(),
                order: folders.len() as u32,
                sheets,
            });
        }
        let mut trash: Vec<SheetSummary> = p
            .toc
            .sheets
            .iter()
            .filter(|(_, e)| e.trashed.is_some())
            .map(|(s, _)| Self::sheet_summary(p, s))
            .collect::<Result<_>>()?;
        trash.sort_by(|a, b| {
            b.trashed
                .cmp(&a.trashed)
                .then_with(|| a.order.cmp(&b.order))
        });
        Ok(Outline {
            project: Self::project_summary(p),
            folders,
            trash,
        })
    }

    pub fn create_folder(&mut self, project: &str, name: &str) -> Result<FolderInfo> {
        let id = new_id();
        let fid = id.clone();
        self.edit_toc(project, |t, _| {
            t.folders.push(FolderEntry {
                id: fid,
                name: name.to_string(),
                deleted: None,
                sheets: vec![],
            });
            Ok(())
        })?;
        let order = self
            .project(project)?
            .toc
            .folders
            .iter()
            .filter(|f| f.deleted.is_none())
            .count() as u32
            - 1;
        Ok(FolderInfo {
            id,
            name: name.to_string(),
            order,
            sheets: vec![],
        })
    }

    pub fn rename_folder(&mut self, project: &str, folder: &str, name: &str) -> Result<()> {
        self.edit_toc(project, |t, _| {
            t.folder_mut(folder)
                .filter(|f| f.deleted.is_none())
                .ok_or(StoreError::NotFound)?
                .name = name.to_string();
            Ok(())
        })
    }

    /// Hides the folder and moves its live sheets to the trash, all stamped with the same moment so
    /// [`Store::restore_folder`] brings back exactly those. The last live folder can't be deleted.
    pub fn delete_folder(&mut self, project: &str, folder: &str) -> Result<()> {
        self.edit_toc(project, |t, now| {
            if t.folder(folder).is_none_or(|f| f.deleted.is_some()) {
                return Err(StoreError::NotFound);
            }
            if t.folders.iter().filter(|f| f.deleted.is_none()).count() <= 1 {
                return Err(invalid("a project keeps at least one folder"));
            }
            let sheets = t
                .folder(folder)
                .map(|f| f.sheets.clone())
                .unwrap_or_default();
            for s in sheets {
                if let Some(e) = t.sheets.get_mut(&s).filter(|e| e.trashed.is_none()) {
                    e.trashed = Some(now);
                }
            }
            t.folder_mut(folder).expect("checked").deleted = Some(now);
            t.drop_empty_deleted_folders();
            Ok(())
        })
    }

    pub fn restore_folder(&mut self, project: &str, folder: &str) -> Result<()> {
        self.edit_toc(project, |t, _| {
            let f = t.folder_mut(folder).ok_or(StoreError::NotFound)?;
            let Some(at) = f.deleted.take() else {
                return Ok(());
            };
            let sheets = f.sheets.clone();
            for s in sheets {
                if let Some(e) = t.sheets.get_mut(&s).filter(|e| e.trashed == Some(at)) {
                    e.trashed = None;
                }
            }
            Ok(())
        })
    }

    // ── Sheets ────────────────────────────────────────────────────────

    pub fn create_sheet(
        &mut self,
        project: &str,
        folder: &str,
        text: &str,
    ) -> Result<SheetSummary> {
        self.writable()?;
        let p = self.project(project)?;
        if p.toc.folder(folder).is_none_or(|f| f.deleted.is_some()) {
            return Err(StoreError::NotFound);
        }
        let sid = new_id();
        let now = self.now();
        self.append(project, &sid, text, Kind::Edit, now)?;
        let s = sid.clone();
        self.edit_toc(project, |t, now| {
            t.folder_mut(folder)
                .expect("checked")
                .sheets
                .push(s.clone());
            t.sheets.insert(
                s,
                SheetEntry {
                    created: now,
                    trashed: None,
                },
            );
            Ok(())
        })?;
        Self::sheet_summary(self.project(project)?, &sid)
    }

    fn check_sheet(&self, project: &str, sheet: &str) -> Result<&Project> {
        let p = self.project(project)?;
        if sheet == Toc::SHEET_ID || !p.toc.sheets.contains_key(sheet) {
            return Err(StoreError::NotFound);
        }
        Ok(p)
    }

    pub fn sheet_summary_of(&self, project: &str, sheet: &str) -> Result<SheetSummary> {
        Self::sheet_summary(self.check_sheet(project, sheet)?, sheet)
    }

    pub fn sheet_text(&self, project: &str, sheet: &str) -> Result<String> {
        let p = self.check_sheet(project, sheet)?;
        Ok(p.chains
            .get(sheet)
            .map(|c| c.text.clone())
            .unwrap_or_default())
    }

    /// Records a new block only when the text changed.
    pub fn save_sheet(&mut self, project: &str, sheet: &str, text: &str) -> Result<SheetSummary> {
        self.writable()?;
        self.check_sheet(project, sheet)?;
        let now = self.now();
        self.append(project, sheet, text, Kind::Edit, now)?;
        self.sheet_summary_of(project, sheet)
    }

    /// Moves a live sheet before `before` (a live sheet of `folder`) or to the end of `folder`.
    pub fn move_sheet(
        &mut self,
        project: &str,
        sheet: &str,
        folder: &str,
        before: Option<&str>,
    ) -> Result<()> {
        self.check_sheet(project, sheet)?;
        if before == Some(sheet) {
            return Ok(());
        }
        self.edit_toc(project, |t, _| {
            if t.is_trashed(sheet) {
                return Err(invalid("a trashed sheet can't be moved"));
            }
            if t.folder(folder).is_none_or(|f| f.deleted.is_some()) {
                return Err(StoreError::NotFound);
            }
            if let Some(b) = before
                && (t.is_trashed(b)
                    || !t
                        .folder(folder)
                        .is_some_and(|f| f.sheets.iter().any(|s| s == b)))
            {
                return Err(StoreError::NotFound);
            }
            for f in &mut t.folders {
                f.sheets.retain(|s| s != sheet);
            }
            let list = &mut t.folder_mut(folder).expect("checked").sheets;
            let at = before
                .and_then(|b| list.iter().position(|s| s == b))
                .unwrap_or(list.len());
            list.insert(at, sheet.to_string());
            Ok(())
        })
    }

    pub fn trash_sheet(&mut self, project: &str, sheet: &str) -> Result<()> {
        self.check_sheet(project, sheet)?;
        self.edit_toc(project, |t, now| {
            t.sheets
                .get_mut(sheet)
                .expect("checked")
                .trashed
                .get_or_insert(now);
            Ok(())
        })
    }

    /// Back to its old slot; its folder comes back too if it was deleted.
    pub fn restore_sheet(&mut self, project: &str, sheet: &str) -> Result<()> {
        self.check_sheet(project, sheet)?;
        self.edit_toc(project, |t, _| {
            t.sheets.get_mut(sheet).expect("checked").trashed = None;
            let (fi, _) = t.locate(sheet).ok_or(StoreError::NotFound)?;
            t.folders[fi].deleted = None;
            Ok(())
        })
    }

    pub fn delete_sheet_forever(&mut self, project: &str, sheet: &str) -> Result<()> {
        self.check_sheet(project, sheet)?;
        self.delete_sheets_forever(project, &[sheet.to_string()])
    }

    pub fn empty_trash(&mut self, project: &str) -> Result<()> {
        let trashed: Vec<String> = self
            .project(project)?
            .toc
            .sheets
            .iter()
            .filter(|(_, e)| e.trashed.is_some())
            .map(|(s, _)| s.clone())
            .collect();
        if trashed.is_empty() {
            return Ok(());
        }
        self.delete_sheets_forever(project, &trashed)
    }

    /// Tombstones first (one toc block), then the files.
    fn delete_sheets_forever(&mut self, project: &str, sheets: &[String]) -> Result<()> {
        self.edit_toc(project, |t, _| {
            for s in sheets {
                t.remove_sheet(s);
            }
            Ok(())
        })?;
        let p = self.project_mut(project)?;
        for s in sheets {
            p.remove_chain_files(s);
        }
        Ok(())
    }

    // ── History ───────────────────────────────────────────────────────

    /// Every block of the sheet (branch copies included), newest first.
    pub fn history(&self, project: &str, sheet: &str) -> Result<Vec<HistoryEntry>> {
        let p = self.check_sheet(project, sheet)?;
        let mut v: Vec<HistoryEntry> = p
            .chains
            .get(sheet)
            .map(|c| c.metas.values())
            .into_iter()
            .flatten()
            .map(|m| HistoryEntry {
                hash: m.hash.clone(),
                at: m.at,
                device: m.device.clone(),
                actor: m.actor,
                kind: m.kind,
                added: m.added,
                removed: m.removed,
            })
            .collect();
        v.sort_by(|a, b| b.at.cmp(&a.at).then_with(|| b.hash.cmp(&a.hash)));
        Ok(v)
    }

    pub fn text_at(&self, project: &str, sheet: &str, hash: &str) -> Result<String> {
        let p = self.check_sheet(project, sheet)?;
        if !p
            .chains
            .get(sheet)
            .is_some_and(|c| c.metas.contains_key(hash))
        {
            return Err(StoreError::NotFound);
        }
        p.text_at(hash)
            .map_err(|e| StoreError::Corrupt(e.to_string()))
    }

    /// Makes an old version the current text with a new block; nothing is erased.
    pub fn restore_version(
        &mut self,
        project: &str,
        sheet: &str,
        hash: &str,
    ) -> Result<SheetSummary> {
        let text = self.text_at(project, sheet, hash)?;
        self.save_sheet(project, sheet, &text)
    }

    /// Re-reads every block file of a project and checks hashes, parents and deltas.
    pub fn verify(&self, project: &str) -> Result<IntegrityReport> {
        let p = self.project(project)?;
        let dir = project::changes_dir(&p.dir);
        let mut issues = Vec::new();
        let mut by_sheet: BTreeMap<String, Vec<Block>> = BTreeMap::new();
        let mut blocks = 0u32;
        let mut names = fsutil::list(&dir)?;
        names.sort();
        for name in names {
            if fsutil::is_temp(&name) {
                continue;
            }
            if !ithaca_ledger::block::is_hash_name(&name) {
                issues.push(IntegrityIssue {
                    file: name,
                    sheet: None,
                    kind: IssueKind::UnexpectedFile,
                    detail: "not a block name".into(),
                });
                continue;
            }
            blocks += 1;
            match project::read_block(&p.dir, &name) {
                Ok(b) => by_sheet.entry(b.sheet.clone()).or_default().push(b),
                Err(e) => {
                    let kind = match e {
                        ithaca_ledger::LedgerError::HashMismatch { .. } => IssueKind::HashMismatch,
                        _ => IssueKind::Unreadable,
                    };
                    issues.push(IntegrityIssue {
                        file: name,
                        sheet: None,
                        kind,
                        detail: e.to_string(),
                    });
                }
            }
        }
        let chains = by_sheet.len() as u32;
        for (sheet, blocks) in by_sheet {
            for (hash, e) in ithaca_ledger::rebuild(blocks).invalid {
                let kind = match e {
                    ithaca_ledger::LedgerError::BadDelta(_) => IssueKind::BadDelta,
                    _ => IssueKind::MissingParent,
                };
                issues.push(IntegrityIssue {
                    file: hash,
                    sheet: Some(sheet.clone()),
                    kind,
                    detail: e.to_string(),
                });
            }
        }
        Ok(IntegrityReport {
            ok: issues.is_empty(),
            blocks,
            chains,
            issues,
        })
    }

    // ── Search, import, export ────────────────────────────────────────

    pub fn search(&self, query: &str, project: Option<&str>) -> Vec<SearchHit> {
        let mut hits = Vec::new();
        for p in self.sorted_projects() {
            if project.is_some_and(|id| id != p.id)
                || (project.is_none() && p.toc.deleted.is_some())
            {
                continue;
            }
            for s in Self::reading_order(p) {
                let text = p.chains.get(&s).map_or("", |c| c.text.as_str());
                for m in search::find(text, query, search::MAX_HITS - hits.len()) {
                    hits.push(SearchHit {
                        project: p.id.clone(),
                        sheet: s.clone(),
                        title: title_of(text),
                        ..m
                    });
                }
                if hits.len() >= search::MAX_HITS {
                    return hits;
                }
            }
        }
        hits
    }

    pub fn import_web_backup(&mut self, json: &str) -> Result<ImportReport> {
        self.writable()?;
        let projects = import::parse(json)?;
        let mut report = ImportReport::default();
        for wp in projects {
            report.projects += 1;
            report.folders += wp.toc.folders.len() as u32;
            report.sheets += wp.sheets.len() as u32;
            self.create_project_from(wp.toc, &wp.sheets)?;
        }
        Ok(report)
    }

    /// `sheets` in the order given; empty means every live sheet of the project in reading order.
    pub fn export_text(
        &self,
        project: &str,
        sheets: &[String],
        options: &ExportOptions,
    ) -> Result<String> {
        let p = self.project(project)?;
        let ids = if sheets.is_empty() {
            Self::reading_order(p)
        } else {
            sheets.to_vec()
        };
        let mut bodies = Vec::with_capacity(ids.len());
        for s in &ids {
            self.check_sheet(project, s)?;
            bodies.push(p.chains.get(s).map_or("", |c| c.text.as_str()));
        }
        Ok(export_sheets(bodies, options))
    }
}
