//! Filesystem store for an Ithaca library (ADR-0002, ADR-0008, core/FORMAT.md).
//!
//! [`Store`] is single-threaded; ithaca-ffi wraps it in a `Mutex`.

pub mod backup;
pub mod error;
pub mod format;
pub mod fsutil;
mod import;
pub mod lock;
pub mod mcp;
pub mod project;
mod recover;
mod search;
mod textimport;
pub mod types;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use ithaca_ledger::block::is_hash_name;
use ithaca_ledger::{Actor, Block, Body, Kind, Meta, Op, delta};
use ithaca_model::{
    EpisodeInfo, EpisodeStatus, ExportOptions, FolderEntry, Language, RETENTION_MS, SheetEntry,
    Toc, excerpt_of, export_sheets, title_of,
};

pub use error::{Result, StoreError};
pub use format::{FORMAT, Migration};
pub use types::*;

use format::{PROJECTS_DIR, Prepared, prepare};
use project::{Project, write_block, write_cache};

/// How far the clock may run ahead of the newest block before purging stops trusting it
/// (core/FORMAT.md §Retention). A clock that jumped forward must not purge anything early.
pub const CLOCK_SLACK_MS: i64 = 2 * 86_400_000;

/// A delta chain longer than this gets a full snapshot, so reading any version touches at most
/// this many blocks.
pub const SNAPSHOT_EVERY: u32 = 32;

pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

/// Offset of local time from UTC at a moment, in ms (added: qa1). Names backup folders.
pub type LocalOffset = Arc<dyn Fn(i64) -> i64 + Send + Sync>;

/// The system time zone's offset (`localtime_r`); UTC where that isn't available.
pub fn system_local_offset() -> LocalOffset {
    Arc::new(fsutil::local_offset_ms)
}

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
    /// Local time for backup folder names and backup retention days (added: qa1).
    pub local_offset: LocalOffset,
}

impl Default for OpenOptions {
    fn default() -> Self {
        Self {
            supported_format: FORMAT,
            migrations: format::migrations(),
            clock: system_clock(),
            local_offset: system_local_offset(),
        }
    }
}

pub struct Store {
    root: PathBuf,
    device: String,
    prepared: Prepared,
    clock: Clock,
    local_offset: LocalOffset,
    /// In creation order is computed on demand; keyed by id.
    projects: BTreeMap<String, Project>,
    /// The library lock (`<library>/.lock`), held for the store's lifetime; `None` when read-only.
    _lock: Option<fs::File>,
    /// Another open (usually another process) holds the lock, so this one is read-only.
    locked_by_other: bool,
    /// Things the writer should know about, in the order they happened (`LibraryInfo.problems`).
    problems: Vec<String>,
}

/// A sheet to write into a new project (import, restore).
pub(crate) struct NewSheet {
    /// Index into the new table of contents' folders.
    pub folder: usize,
    pub text: String,
    pub created: i64,
    /// Time of its block.
    pub modified: i64,
    pub episode: Option<EpisodeInfo>,
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
        Self::open_inner(path.as_ref(), device, opts, false)
    }

    /// (added: r3) Opens an existing library for reading only, for a second process such as the
    /// `ithaca-mcp` server while the app holds the lock. Nothing is written — not the lock file, no
    /// cache, no cleanup, no purge, no migration — and every write returns `ReadOnly`. It is a
    /// snapshot of the moment it opened (blocks are written atomically, so it sees whole blocks
    /// only): open again to see later writes. A folder without `library.json` → NotFound.
    pub fn open_read_only(path: impl AsRef<Path>) -> Result<Store> {
        Self::open_read_only_with(path, OpenOptions::default())
    }

    pub fn open_read_only_with(path: impl AsRef<Path>, opts: OpenOptions) -> Result<Store> {
        let root = path.as_ref();
        if !root.join(format::LIBRARY_FILE).is_file() {
            return Err(StoreError::NotFound);
        }
        Self::open_inner(root, "read-only", opts, true)
    }

    fn open_inner(root: &Path, device: &str, opts: OpenOptions, read_only: bool) -> Result<Store> {
        if device.trim().is_empty() {
            return Err(invalid("device id is empty"));
        }
        let root = root.to_path_buf();
        let now = (opts.clock)();
        let mut problems = Vec::new();
        // Lock first, then look: everything below may write only while holding the lock.
        let (mut lock, mut locked_by_other) = (None, false);
        let mut can_write = !read_only && format::may_write(&root, opts.supported_format);
        if can_write {
            fs::create_dir_all(&root)?;
            match lock::acquire(&root) {
                Ok(Some(f)) => lock = Some(f),
                Ok(None) => {
                    locked_by_other = true;
                    can_write = false;
                    problems.push(
                        "Another Ithaca has this library open. Opened read-only; close the other \
                         one and open again to edit."
                            .to_string(),
                    );
                }
                // A folder that cannot be locked (some network volumes): still usable, unguarded.
                Err(e) if e.kind() == std::io::ErrorKind::Unsupported => problems.push(format!(
                    "This folder does not support locking ({e}); do not open it from two apps at once."
                )),
                Err(e) => return Err(e.into()),
            }
        }
        let mut prepared = prepare(
            &root,
            opts.supported_format,
            &opts.migrations,
            now,
            can_write,
        )?;
        problems.append(&mut prepared.problems);
        let writable = !prepared.read_only;
        if !writable {
            lock = None;
        }
        let mut projects = BTreeMap::new();
        let names = match fsutil::list(&root.join(PROJECTS_DIR)) {
            Ok(n) => n,
            Err(e) => {
                problems.push(format!("The projects folder could not be read: {e}"));
                Vec::new()
            }
        };
        for name in names {
            let dir = root.join(PROJECTS_DIR).join(&name);
            if name.starts_with('.') || !dir.is_dir() {
                continue;
            }
            // One unreadable project must not take the library down: skip it, leave it untouched.
            match Project::load(&name, &dir, writable) {
                Ok(Some(p)) => {
                    problems.extend(damage_problems(&p));
                    projects.insert(name, p);
                }
                Ok(None) => {
                    let blocks = fsutil::list(&project::changes_dir(&dir))
                        .map(|v| v.iter().filter(|n| is_hash_name(n)).count())
                        .unwrap_or(0);
                    if blocks > 0 {
                        problems.push(format!(
                            "Project {name} was skipped: its {blocks} change files have no \
                             readable table of contents. Its folder was left as it is."
                        ));
                    }
                }
                Err(e) => problems.push(format!(
                    "Project {name} was skipped and left as it is on disk: {e}"
                )),
            }
        }
        let mut store = Store {
            root,
            device: device.to_string(),
            prepared,
            clock: opts.clock,
            local_offset: opts.local_offset,
            projects,
            _lock: lock,
            locked_by_other,
            problems,
        };
        if writable && let Err(e) = store.purge_expired() {
            store
                .problems
                .push(format!("Emptying old trash failed: {e}"));
        }
        Ok(store)
    }

    pub fn info(&self) -> LibraryInfo {
        LibraryInfo {
            format: self.prepared.format,
            read_only: self.read_only(),
            locked_by_other: self.locked_by_other,
            problems: self.problems.clone(),
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

    /// Nothing is written: a newer format, another open holds the lock, or opening found a problem
    /// that makes writing unsafe (see `info().problems`).
    pub fn read_only(&self) -> bool {
        self.prepared.read_only
    }

    fn writable(&self) -> Result<()> {
        if self.read_only() {
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
        // (changed: qa4) Sheet text is stored with `\n` line breaks only.
        let text: &str = &if sheet == Toc::SHEET_ID {
            std::borrow::Cow::Borrowed(text)
        } else {
            ithaca_model::text::normalize_newlines(text)
        };
        let device = self.device.clone();
        let p = self.project_mut(project)?;
        if p.damage.contains_key(sheet) {
            return Err(damaged_error(sheet));
        }
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
            episode: entry.episode.clone(),
            damaged: p.damage.contains_key(sheet),
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

    /// When a project came into this library: the time of its first table-of-contents block
    /// (written when it was created, imported or restored here), not its original `created`.
    fn added_at(p: &Project) -> i64 {
        p.chains
            .get(Toc::SHEET_ID)
            .and_then(|c| c.metas.values().map(|m| m.at).min())
            .unwrap_or(p.toc.created)
    }

    /// In the order the projects were added to this library (added: qa1).
    fn sorted_projects(&self) -> Vec<&Project> {
        let mut v: Vec<&Project> = self.projects.values().collect();
        v.sort_by(|a, b| {
            Self::added_at(a)
                .cmp(&Self::added_at(b))
                .then_with(|| a.toc.created.cmp(&b.toc.created))
                .then_with(|| a.id.cmp(&b.id))
        });
        v
    }

    // ── Projects ──────────────────────────────────────────────────────

    /// Live projects in the order they were added to this library.
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
                .map(|name| FolderEntry::new(new_id(), name.clone()))
                .collect(),
            ..Default::default()
        };
        let now = toc.created;
        self.create_project_from(
            toc,
            &[NewSheet {
                folder: 0,
                text: String::new(),
                created: now,
                modified: now,
                episode: None,
            }],
        )
    }

    /// Writes a new project: its sheets first, then the table of contents that names them, so a crash
    /// in between leaves only invisible orphans.
    fn create_project_from(&mut self, mut toc: Toc, sheets: &[NewSheet]) -> Result<ProjectSummary> {
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
                damage: Default::default(),
                damage_direct: Default::default(),
                unattributed: Default::default(),
            },
        );
        let result = (|| {
            for s in sheets {
                let sid = new_id();
                self.append(&id, &sid, &s.text, Kind::Edit, s.modified)?;
                toc.folders[s.folder].sheets.push(sid.clone());
                let mut entry = SheetEntry::new(s.created);
                entry.episode = s.episode.clone();
                toc.sheets.insert(sid, entry);
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
    /// Permanently removes projects deleted and sheets trashed more than 30 days ago.
    ///
    /// Clock guard: "now" for retention is `min(clock, newest block in the library + 2 days)`. A
    /// clock that jumped forward (bad RTC, manual change) therefore purges nothing early: purging
    /// waits until the writer has written something recently by that clock. A clock that went back
    /// only delays purging. Failures are noted in `info().problems` and do not stop the rest.
    pub fn purge_expired(&mut self) -> Result<()> {
        self.writable()?;
        let newest = self
            .projects
            .values()
            .flat_map(|p| p.chains.values())
            .flat_map(|c| c.metas.values())
            .map(|m| m.at)
            .max();
        let Some(newest) = newest else {
            return Ok(());
        };
        let now = self.now().min(newest.saturating_add(CLOCK_SLACK_MS));
        let cutoff = now - RETENTION_MS;
        let expired: Vec<String> = self
            .projects
            .values()
            .filter(|p| p.toc.deleted.is_some_and(|d| d <= cutoff))
            .map(|p| p.id.clone())
            .collect();
        for id in expired {
            let dir = self.projects[&id].dir.clone();
            match fs::remove_dir_all(&dir) {
                Ok(()) => {
                    self.projects.remove(&id);
                }
                Err(e) => self
                    .problems
                    .push(format!("Could not remove deleted project {id}: {e}")),
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
            if !old.is_empty()
                && let Err(e) = self.delete_sheets_forever(&id, &old)
            {
                self.problems
                    .push(format!("Could not empty old trash of project {id}: {e}"));
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
            t.folders.push(FolderEntry::new(fid, name));
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
            t.sheets.insert(s, SheetEntry::new(now));
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

    /// Records a new block only when the text changed. A damaged sheet is refused (`Corrupt`).
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

    // ── Episodes ──────────────────────────────────────────────────────

    /// Sets (`Some`) or clears (`None`) a sheet's episode metadata. Works on trashed sheets too.
    pub fn set_episode(
        &mut self,
        project: &str,
        sheet: &str,
        info: Option<EpisodeInfo>,
    ) -> Result<SheetSummary> {
        self.check_sheet(project, sheet)?;
        self.edit_toc(project, |t, _| {
            t.sheets.get_mut(sheet).expect("checked").episode = info;
            Ok(())
        })?;
        self.sheet_summary_of(project, sheet)
    }

    fn live_folder<'a>(p: &'a Project, folder: &str) -> Result<&'a FolderEntry> {
        p.toc
            .folder(folder)
            .filter(|f| f.deleted.is_none())
            .ok_or(StoreError::NotFound)
    }

    /// `비축분`: live sheets of the folder that are not `Published`. A sheet without episode metadata
    /// counts as not published (a serial folder's new sheet is stock until marked otherwise).
    /// (changed: r3) Excluded sheets (prologue, `외전`, `공지`) are never stock.
    pub fn stock(&self, project: &str, folder: &str) -> Result<u32> {
        let p = self.project(project)?;
        let f = Self::live_folder(p, folder)?;
        Ok(p.toc
            .live_sheets(f)
            .filter(|s| {
                p.toc.sheets[*s]
                    .episode
                    .as_ref()
                    .is_none_or(|e| !e.excluded && e.status != EpisodeStatus::Published)
            })
            .count() as u32)
    }

    /// Numbers every live sheet of the folder 1..n in serial order (one toc block); a sheet without
    /// episode metadata gets `Draft` metadata. Status, date and platform are untouched. Returns n.
    /// (changed: qa1 — sheets without metadata used to be skipped.)
    /// (changed: r3) Excluded sheets are skipped and lose their number; n counts the others.
    pub fn renumber_episodes(&mut self, project: &str, folder: &str) -> Result<u32> {
        Self::live_folder(self.project(project)?, folder)?;
        self.edit_toc(project, |t, _| {
            let f = t.folder(folder).expect("checked");
            let ids: Vec<String> = t.live_sheets(f).cloned().collect();
            let mut n = 0;
            for id in ids {
                if let Some(entry) = t.sheets.get_mut(&id) {
                    if let Some(e) = entry.episode.as_mut().filter(|e| e.excluded) {
                        e.number = None;
                        continue;
                    }
                    n += 1;
                    entry
                        .episode
                        .get_or_insert_with(EpisodeInfo::default)
                        .number = Some(n);
                }
            }
            Ok(n)
        })
    }

    /// Sets `status` on every live sheet of the folder up to and including `sheet`, in serial
    /// order ("mark everything up to here as published"); sheets without metadata get it with no
    /// number. One toc block. `sheet` must be a live sheet of that folder (else NotFound). Returns
    /// how many sheets it covers. (added: qa1)
    pub fn set_status_through(
        &mut self,
        project: &str,
        folder: &str,
        sheet: &str,
        status: EpisodeStatus,
    ) -> Result<u32> {
        let p = self.project(project)?;
        let f = Self::live_folder(p, folder)?;
        let ids: Vec<String> = p.toc.live_sheets(f).cloned().collect();
        let upto = ids
            .iter()
            .position(|s| s == sheet)
            .ok_or(StoreError::NotFound)?;
        self.edit_toc(project, |t, _| {
            for id in &ids[..=upto] {
                if let Some(entry) = t.sheets.get_mut(id) {
                    entry
                        .episode
                        .get_or_insert_with(EpisodeInfo::default)
                        .status = status;
                }
            }
            Ok(upto as u32 + 1)
        })
    }

    /// (added: r3) `다음 연재일`: the earliest `publish_at` after now among the folder's live
    /// `Scheduled` sheets (excluded ones too — a scheduled `외전` is still a release). `None` when
    /// nothing is scheduled ahead. Unknown/deleted folder → NotFound.
    pub fn next_release(&self, project: &str, folder: &str) -> Result<Option<i64>> {
        let p = self.project(project)?;
        let f = Self::live_folder(p, folder)?;
        let now = self.now();
        Ok(p.toc
            .live_sheets(f)
            .filter_map(|s| p.toc.sheets[s].episode.as_ref())
            .filter(|e| e.status == EpisodeStatus::Scheduled)
            .filter_map(|e| e.publish_at)
            .filter(|at| *at > now)
            .min())
    }

    /// (added: r3) Totals for one live folder (`폴더 통계`): see [`FolderStats`].
    pub fn folder_stats(&self, project: &str, folder: &str) -> Result<FolderStats> {
        let p = self.project(project)?;
        let f = Self::live_folder(p, folder)?;
        let mut st = FolderStats::default();
        let mut episode_chars: u64 = 0;
        for s in p.toc.live_sheets(f) {
            let chain = p.chains.get(s);
            let text = chain.map_or("", |c| c.text.as_str());
            let counts = chain.map(|c| c.counts).unwrap_or_default();
            st.sheets += 1;
            st.total = st.total + counts;
            let body = ithaca_model::platform_body(text);
            st.munpia_total += ithaca_model::count_for(&body, ithaca_model::CountRule::Munpia);
            st.novelpia_total += ithaca_model::count_for(&body, ithaca_model::CountRule::Novelpia);
            let ep = p.toc.sheets[s].episode.as_ref();
            if ep.is_some_and(|e| e.excluded) {
                continue;
            }
            st.episodes += 1;
            episode_chars += u64::from(counts.chars);
            match ep.map(|e| e.status) {
                Some(EpisodeStatus::Published) => st.published += 1,
                Some(EpisodeStatus::Scheduled) => st.scheduled += 1,
                _ => st.drafts += 1,
            }
        }
        if st.episodes > 0 {
            let n = u64::from(st.episodes);
            st.average_chars = ((episode_chars + n / 2) / n) as u32;
        }
        Ok(st)
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

    /// (added: history-sessions) [`Store::history`] grouped into writing sessions, newest first. Every
    /// block is in exactly one session, so nothing the plain list shows is hidden.
    pub fn history_sessions(&self, project: &str, sheet: &str) -> Result<Vec<HistorySession>> {
        let p = self.check_sheet(project, sheet)?;
        let Some(chain) = p.chains.get(sheet) else {
            return Ok(Vec::new());
        };
        let mut metas: Vec<&Meta> = chain.metas.values().collect();
        metas.sort_by(|a, b| a.at.cmp(&b.at).then_with(|| a.hash.cmp(&b.hash)));
        // Oldest first while grouping.
        let mut groups: Vec<Vec<&Meta>> = Vec::new();
        for m in metas {
            let joins = groups.last().and_then(|g| g.last()).is_some_and(|last| {
                m.kind == Kind::Edit
                    && last.kind == Kind::Edit
                    && m.device == last.device
                    && m.actor == last.actor
                    && m.parents.first() == Some(&last.hash)
                    && m.at - last.at < SESSION_GAP_MS
            });
            if joins {
                groups.last_mut().expect("checked").push(m);
            } else {
                groups.push(vec![m]);
            }
        }
        let entry = |m: &Meta| HistoryEntry {
            hash: m.hash.clone(),
            at: m.at,
            device: m.device.clone(),
            actor: m.actor,
            kind: m.kind,
            added: m.added,
            removed: m.removed,
        };
        // The previous session's end text: the next session usually starts from it, so each block
        // file is read about once.
        let mut known: std::collections::HashMap<String, String> = Default::default();
        let mut out = Vec::with_capacity(groups.len());
        for g in groups {
            let (first, last) = (g[0], g[g.len() - 1]);
            let base = first.parents.first().cloned();
            let sum = || {
                g.iter().fold((0u32, 0u32), |(a, r), m| {
                    (a.saturating_add(m.added), r.saturating_add(m.removed))
                })
            };
            let (added, removed) = if g.len() == 1 {
                (last.added, last.removed)
            } else {
                let before = match &base {
                    Some(b) => p.text_at_known(b, &known),
                    None => Ok(String::new()),
                };
                let after = p.text_at_known(&last.hash, &known);
                match (before, after) {
                    (Ok(b), Ok(a)) => {
                        let stats = delta::apply(&b, &delta::diff(&b, &a))
                            .map(|(_, st)| (st.added, st.removed))
                            .unwrap_or_else(|_| sum());
                        known.clear();
                        known.insert(last.hash.clone(), a);
                        stats
                    }
                    _ => sum(),
                }
            };
            out.push(HistorySession {
                start: first.at,
                end: last.at,
                device: last.device.clone(),
                actor: last.actor,
                kind: last.kind,
                added,
                removed,
                base,
                entries: g.iter().rev().map(|m| entry(m)).collect(),
            });
        }
        out.reverse();
        Ok(out)
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

    /// `Some(project)`: that project only (deleted ones too), at most 500 hits. `None`: same as
    /// [`Store::search_all`] with no current project.
    pub fn search(&self, query: &str, project: Option<&str>) -> Vec<SearchHit> {
        match project {
            Some(id) => self
                .projects
                .get(id)
                .map(|p| Self::search_project(p, query, search::MAX_HITS))
                .unwrap_or_default(),
            None => self.search_all(query, None),
        }
    }

    /// Every live project, `current` first, then the library order; at most 200 hits per project
    /// and 500 in all, so one long project can't hide the others. (added: qa1)
    pub fn search_all(&self, query: &str, current: Option<&str>) -> Vec<SearchHit> {
        let mut ps: Vec<&Project> = self
            .sorted_projects()
            .into_iter()
            .filter(|p| p.toc.deleted.is_none())
            .collect();
        ps.sort_by_key(|p| Some(p.id.as_str()) != current); // stable: the rest keep their order
        let mut hits = Vec::new();
        for p in ps {
            let room = search::MAX_HITS - hits.len();
            if room == 0 {
                break;
            }
            hits.extend(Self::search_project(
                p,
                query,
                room.min(search::MAX_PER_PROJECT),
            ));
        }
        hits
    }

    /// Hits in one project's live sheets in reading order, at most `limit`.
    fn search_project(p: &Project, query: &str, limit: usize) -> Vec<SearchHit> {
        let mut hits = Vec::new();
        for s in Self::reading_order(p) {
            if hits.len() >= limit {
                break;
            }
            let text = p.chains.get(&s).map_or("", |c| c.text.as_str());
            for m in search::find(text, query, limit - hits.len()) {
                hits.push(SearchHit {
                    project: p.id.clone(),
                    sheet: s.clone(),
                    title: title_of(text),
                    ..m
                });
            }
        }
        hits
    }

    pub fn import_web_backup(&mut self, json: &str) -> Result<ImportReport> {
        self.import_web_backup_with_suffix(json, "")
    }

    /// [`Store::import_web_backup`], with `suffix` appended to every imported title (e.g.
    /// " (웹)"); empty = titles as they are. (added: qa1)
    pub fn import_web_backup_with_suffix(
        &mut self,
        json: &str,
        suffix: &str,
    ) -> Result<ImportReport> {
        self.writable()?;
        let mut projects = import::parse(json)?;
        for wp in &mut projects {
            wp.toc.title.push_str(suffix);
        }
        let mut report = ImportReport::default();
        let mut news = Vec::with_capacity(projects.len());
        for wp in projects {
            report.projects += 1;
            report.folders += wp.toc.folders.len() as u32;
            report.sheets += wp.sheets.len() as u32;
            news.push((wp.toc, wp.sheets));
        }
        self.create_projects_all_or_nothing(news)?;
        Ok(report)
    }

    /// A folder of `.txt` / `.md` manuscripts → one new project (rules in `textimport.rs` and
    /// core/API.md). `title` empty or `None` = the folder's name; `language` `None` = detected.
    /// All or nothing. (added: txt-import)
    pub fn import_text_folder(
        &mut self,
        path: impl AsRef<Path>,
        title: Option<&str>,
        language: Option<Language>,
    ) -> Result<ImportReport> {
        self.writable()?;
        let now = self.now();
        let tp = textimport::read(path.as_ref(), title, language, now)?;
        let report = ImportReport {
            projects: 1,
            folders: tp.toc.folders.len() as u32,
            sheets: tp.sheets.len() as u32,
            skipped: tp.skipped,
        };
        self.create_projects_all_or_nothing(vec![(tp.toc, tp.sheets)])?;
        Ok(report)
    }

    /// Creates several projects; if any fails, the ones already created by this call are removed
    /// again (they are new folders nobody else has seen), so the library is as before.
    pub(crate) fn create_projects_all_or_nothing(
        &mut self,
        news: Vec<(Toc, Vec<NewSheet>)>,
    ) -> Result<Vec<ProjectSummary>> {
        let mut out: Vec<ProjectSummary> = Vec::with_capacity(news.len());
        for (toc, sheets) in news {
            match self.create_project_from(toc, &sheets) {
                Ok(p) => out.push(p),
                Err(e) => {
                    for p in &out {
                        if let Some(p) = self.projects.remove(&p.id) {
                            let _ = fs::remove_dir_all(&p.dir);
                        }
                    }
                    return Err(e);
                }
            }
        }
        Ok(out)
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

    /// (added: docx) The same sheets as a Word file (ithaca_model::docx). The project title goes into
    /// the document properties; its language into the text language (Hangul is always ko-KR).
    pub fn export_docx(
        &self,
        project: &str,
        sheets: &[String],
        options: &ithaca_model::DocxOptions,
    ) -> Result<Vec<u8>> {
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
        Ok(ithaca_model::export_docx(
            bodies,
            &p.toc.title,
            p.toc.language,
            options,
        )?)
    }
}

/// The error a write to a damaged chain gets.
fn damaged_error(chain: &str) -> StoreError {
    if chain == Toc::SHEET_ID {
        StoreError::Corrupt(
            "this project's table of contents is damaged; restore the project from a backup".into(),
        )
    } else {
        StoreError::Corrupt(
            "this sheet is damaged; recover it from a backup or keep its last good text first"
                .into(),
        )
    }
}

/// "1 change file damaged; 2 later changes depend on it" (changed: qa4): only the files that are
/// broken themselves count as damaged. No files at all: the sheet's files are missing.
fn damage_count(direct: usize, all: usize) -> String {
    let dependents = all.saturating_sub(direct);
    let mut s = match direct {
        0 if all == 0 => return "its change files are missing".into(),
        0 if all == 1 => return "1 change can't be verified".into(),
        0 => return format!("{all} changes can't be verified"),
        1 => "1 change file damaged".into(),
        n => format!("{n} change files damaged"),
    };
    let them = if direct == 1 { "it" } else { "them" };
    match dependents {
        0 => {}
        1 => s.push_str(&format!("; 1 later change depends on {them}")),
        n => s.push_str(&format!("; {n} later changes depend on {them}")),
    }
    s
}

/// What opening tells the writer about a damaged project.
fn damage_problems(p: &Project) -> Vec<String> {
    let title = &p.toc.title;
    let mut out = Vec::new();
    for (chain, files) in &p.damage {
        let what = damage_count(
            p.damage_direct.get(chain).copied().unwrap_or(files.len()),
            files.len(),
        );
        if chain == Toc::SHEET_ID {
            out.push(format!(
                "The table of contents of \"{title}\" is damaged ({what}). It shows its last good \
                 state and can't be changed; restore the project from a backup."
            ));
        } else {
            let name = p
                .chains
                .get(chain)
                .map(|c| title_of(&c.text))
                .unwrap_or_default();
            out.push(format!(
                "Sheet \"{name}\" in \"{title}\" is damaged ({what}). It shows its last good text \
                 and can't be edited until it is recovered from a backup."
            ));
        }
    }
    if !p.unattributed.is_empty() {
        out.push(format!(
            "\"{title}\" has {} change files that can't be read and belong to no known sheet.",
            p.unattributed.len()
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toc(title: &str, folders: usize) -> Toc {
        Toc {
            title: title.into(),
            folders: (0..folders)
                .map(|_| FolderEntry::new(new_id(), "F"))
                .collect(),
            ..Default::default()
        }
    }

    /// Import and restore create several projects; a failure part way removes the ones already
    /// created, so a retry never duplicates them.
    #[test]
    fn multi_project_create_is_all_or_nothing() {
        let dir = std::env::temp_dir().join(format!("ithaca-aon-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let mut s = Store::open(&dir, "dev").unwrap();
        let sheet = || NewSheet {
            folder: 0,
            text: "글".into(),
            created: 1,
            modified: 1,
            episode: None,
        };
        // The second has no folder, which fails after the first was written.
        let r = s.create_projects_all_or_nothing(vec![
            (toc("one", 1), vec![sheet()]),
            (toc("two", 0), vec![]),
        ]);
        assert!(matches!(r, Err(StoreError::InvalidInput(_))));
        assert!(s.projects().is_empty());
        assert!(fsutil::list(&dir.join(PROJECTS_DIR)).unwrap().is_empty());
        let ok = s
            .create_projects_all_or_nothing(vec![
                (toc("one", 1), vec![sheet()]),
                (toc("two", 1), vec![]),
            ])
            .unwrap();
        assert_eq!(ok.len(), 2);
        drop(s);
        let _ = fs::remove_dir_all(&dir);
    }
}
