//! Local backups (design/PRODUCT.md `백업`, research §5 P0 "매일 로컬 백업"; core/FORMAT.md §Backups).
//!
//! A backup is a library-shaped folder — `library.json`, `projects/<id>/changes/<hash>` and a
//! `backup.json` manifest — next to the library: `<library parent>/Backups/auto-<local yyyy-mm-dd-HHMM>/`.
//! Blocks are immutable and the store is behind one lock, so copying the block files is a consistent
//! snapshot. Caches are derived and left out. A backup is written under a `.tmp-` name, every file
//! flushed to disk, a manifest with `complete: true` written last, then renamed into place, so a
//! crash never leaves a half backup that looks whole: only folders whose manifest says complete
//! are listed.

use std::fs;
use std::path::{Path, PathBuf};

use ithaca_ledger::block::is_hash_name;
use ithaca_model::Toc;
use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::format::PRE_MIGRATION;
use crate::format::{BACKUPS_DIR, LIBRARY_FILE, LibraryFile, PROJECTS_DIR};
use crate::fsutil::{copy_durable, is_temp, list, sync_dir, utc_date, write_atomic};
use crate::project::{CHANGES_DIR, Project};
use crate::{BackupInfo, BackupKind, NewSheet, ProjectSummary, Store, invalid};

pub const MANIFEST_FILE: &str = "backup.json";
pub const DAY_MS: i64 = 86_400_000;
/// Retention of automatic backups: the newest of each of the last 7 days that have one, and the
/// newest of each of the last 4 weeks (Monday-based) that have one, in local time (UTC before qa1). Manual and pre-migration
/// backups are never removed.
pub const KEEP_DAILY: usize = 7;
pub const KEEP_WEEKLY: usize = 4;
/// A `.tmp-` backup folder untouched this long is a leftover of a crash, not a backup in progress.
const STALE_TEMP_MS: i64 = 3_600_000;

const AUTO: &str = "auto";
const MANUAL: &str = "manual";
pub(crate) const PRE_MIGRATION_KIND: &str = "pre-migration";

#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct Manifest {
    pub v: u32,
    /// `auto` | `manual` | `pre-migration`
    pub kind: String,
    pub at: i64,
    pub bytes: u64,
    pub format: u32,
    pub projects: u32,
    /// Written last, after every file was flushed (added: safety). Manifests from before this
    /// field were also only ever written after the copy finished, so a missing field means true.
    #[serde(default = "yes")]
    pub complete: bool,
    /// (added: qa1) Sheets with any text in the backup. Absent in older manifests (= unknown,
    /// taken as "has text").
    #[serde(
        default,
        rename = "textSheets",
        skip_serializing_if = "Option::is_none"
    )]
    pub text_sheets: Option<u32>,
}

fn yes() -> bool {
    true
}

impl Manifest {
    pub(crate) fn to_bytes(&self) -> Vec<u8> {
        let mut json = serde_json::to_vec_pretty(self).expect("manifest serializes");
        json.push(b'\n');
        json
    }

    /// The manifest of a finished backup folder, if it has one.
    fn read(path: &Path) -> Option<Manifest> {
        fs::read(path.join(MANIFEST_FILE))
            .ok()
            .and_then(|b| serde_json::from_slice::<Manifest>(&b).ok())
            .filter(|m| m.complete)
    }
}

/// `yyyy-mm-dd-HHMM` of a wall-clock time (`ms` already shifted to local time).
fn stamp(ms: i64) -> String {
    let minutes = ms.rem_euclid(DAY_MS) / 60_000;
    format!("{}-{:02}{:02}", utc_date(ms), minutes / 60, minutes % 60)
}

fn modified_ms(path: &Path) -> i64 {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_millis() as i64)
}

pub(crate) fn dir_size(path: &Path) -> u64 {
    let Ok(rd) = fs::read_dir(path) else {
        return 0;
    };
    rd.flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => dir_size(&e.path()),
            _ => e.metadata().map_or(0, |m| m.len()),
        })
        .sum()
}

pub(crate) fn project_count(backup: &Path) -> u32 {
    list(&backup.join(PROJECTS_DIR))
        .unwrap_or_default()
        .iter()
        .filter(|n| !n.starts_with('.') && backup.join(PROJECTS_DIR).join(n).is_dir())
        .count() as u32
}

/// Which automatic backups retention keeps (local wall-clock `at`, newest first in, flags out).
fn keep_flags(ats_newest_first: &[i64]) -> Vec<bool> {
    let (mut days, mut weeks) = (Vec::new(), Vec::new());
    ats_newest_first
        .iter()
        .map(|at| {
            let day = at.div_euclid(DAY_MS);
            // 1970-01-01 was a Thursday; +3 makes weeks start on Monday.
            let week = (day + 3).div_euclid(7);
            let mut keep = false;
            if !days.contains(&day) && days.len() < KEEP_DAILY {
                days.push(day);
                keep = true;
            }
            if !weeks.contains(&week) && weeks.len() < KEEP_WEEKLY {
                weeks.push(week);
                keep = true;
            }
            keep
        })
        .collect()
}

impl Store {
    /// `<library parent>/Backups` (falls back to `<library>/Backups` for a library at a root).
    pub fn backups_dir(&self) -> PathBuf {
        match self.root.parent() {
            Some(p) if !p.as_os_str().is_empty() => p.join(BACKUPS_DIR),
            _ => self.root.join(BACKUPS_DIR),
        }
    }

    /// Writes an automatic backup, then applies retention to automatic backups. The backup is what
    /// matters: a failed pruning is noted in [`Store::info`]`.problems` and the backup still returned.
    pub fn backup_now(&mut self) -> Result<BackupInfo> {
        let info = self.write_backup(AUTO, BackupKind::Auto)?;
        if let Err(e) = self.prune_backups() {
            self.problems
                .push(format!("Removing old automatic backups failed: {e}"));
        }
        Ok(info)
    }

    /// Writes a backup the writer asked for. Retention never removes it.
    pub fn backup_manual(&mut self) -> Result<BackupInfo> {
        self.write_backup(MANUAL, BackupKind::Manual)
    }

    /// Sheets with any text, over every project (deleted ones and trashed sheets included).
    fn text_sheets(&self) -> u32 {
        self.projects
            .values()
            .flat_map(|p| p.chains.iter())
            .filter(|(id, c)| id.as_str() != Toc::SHEET_ID && !c.text.is_empty())
            .count() as u32
    }

    /// Time of the newest block in the library.
    fn newest_block(&self) -> Option<i64> {
        self.projects
            .values()
            .flat_map(|p| p.chains.values())
            .flat_map(|c| c.metas.values())
            .map(|m| m.at)
            .max()
    }

    /// (changed: qa1) An automatic backup is due when the library has text, changed since the
    /// newest automatic backup (a block newer than it), and that backup is older than 24 hours or
    /// held no text. False on a read-only library.
    pub fn backup_due(&self) -> bool {
        if self.read_only() || self.text_sheets() == 0 {
            return false;
        }
        let newest_auto = self
            .backups()
            .into_iter()
            .find(|b| b.kind == BackupKind::Auto);
        let Some(b) = newest_auto else {
            return true;
        };
        let changed = self.newest_block().is_some_and(|t| t > b.at);
        changed && (b.at <= self.now() - DAY_MS || !backup_has_text(Path::new(&b.path)))
    }

    /// Every backup of this library, newest first: automatic and manual ones from
    /// [`Store::backups_dir`], pre-migration ones from `<library>/Backups`.
    pub fn backups(&self) -> Vec<BackupInfo> {
        let mut out = Vec::new();
        let dir = self.backups_dir();
        for name in list(&dir).unwrap_or_default() {
            if name.starts_with('.') {
                continue;
            }
            let path = dir.join(&name);
            let Some(m) = Manifest::read(&path) else {
                continue;
            };
            let kind = match m.kind.as_str() {
                AUTO => BackupKind::Auto,
                MANUAL => BackupKind::Manual,
                _ => continue,
            };
            out.push(BackupInfo {
                path: path.to_string_lossy().into_owned(),
                at: m.at,
                bytes: m.bytes,
                kind,
                projects: m.projects,
            });
        }
        let pre = self.root.join(BACKUPS_DIR);
        for name in list(&pre).unwrap_or_default() {
            let path = pre.join(&name);
            if !name.starts_with(PRE_MIGRATION) || !path.is_dir() {
                continue;
            }
            // A pre-migration copy is listed only once its manifest says it is complete.
            let Some(m) = Manifest::read(&path).filter(|m| m.kind == PRE_MIGRATION_KIND) else {
                continue;
            };
            out.push(BackupInfo {
                path: path.to_string_lossy().into_owned(),
                at: m.at,
                bytes: m.bytes,
                kind: BackupKind::PreMigration,
                projects: m.projects,
            });
        }
        out.sort_by(|a, b| b.at.cmp(&a.at).then_with(|| b.path.cmp(&a.path)));
        out
    }

    fn write_backup(&mut self, prefix: &str, kind: BackupKind) -> Result<BackupInfo> {
        self.writable()?;
        let text_sheets = self.text_sheets();
        if kind == BackupKind::Auto && text_sheets == 0 {
            return Err(invalid("nothing to back up: no sheet has text yet"));
        }
        let now = self.now();
        let dir = self.backups_dir();
        fs::create_dir_all(&dir)?;
        // Backups that stopped half way (crash, full disk). We hold this library's lock, but the
        // folder is shared with any sibling library, so only folders untouched for an hour go.
        for name in list(&dir)? {
            if is_temp(&name)
                && (name.contains(AUTO) || name.contains(MANUAL))
                && modified_ms(&dir.join(&name)) < (crate::system_clock())() - STALE_TEMP_MS
            {
                let _ = fs::remove_dir_all(dir.join(&name));
            }
        }
        // Local wall-clock time in the name (what the writer sees in Finder); `at` in the manifest
        // stays UTC ms and is what every listing sorts by.
        let base = format!("{prefix}-{}", stamp(now + (self.local_offset)(now)));
        let mut path = dir.join(&base);
        let mut n = 2;
        while path.exists() {
            path = dir.join(format!("{base}-{n}"));
            n += 1;
        }
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let tmp = dir.join(format!(".tmp-{name}-{}", std::process::id()));
        let mut skipped = Vec::new();
        let result = (|| -> Result<Manifest> {
            let _ = fs::remove_dir_all(&tmp);
            let mut bytes = copy_durable(
                &self.root.join(LIBRARY_FILE),
                &tmp_file(&tmp, LIBRARY_FILE)?,
            )?;
            let mut projects = 0;
            let projects_dst = tmp.join(PROJECTS_DIR);
            fs::create_dir_all(&projects_dst)?;
            for id in list(&self.root.join(PROJECTS_DIR))? {
                let src = self.root.join(PROJECTS_DIR).join(&id).join(CHANGES_DIR);
                if id.starts_with('.') || !src.is_dir() {
                    continue;
                }
                // One unreadable project must not stop every other project being backed up.
                let files = match list(&src) {
                    Ok(f) => f,
                    Err(e) => {
                        skipped.push(format!("Backup skipped project {id}: {e}"));
                        continue;
                    }
                };
                let dst = projects_dst.join(&id).join(CHANGES_DIR);
                fs::create_dir_all(&dst)?;
                projects += 1;
                for f in files {
                    if is_hash_name(&f) {
                        bytes += copy_durable(&src.join(&f), &dst.join(&f))?;
                    }
                }
                sync_dir(&dst)?;
                sync_dir(&projects_dst.join(&id))?;
            }
            sync_dir(&projects_dst)?;
            let m = Manifest {
                v: 1,
                kind: prefix.to_string(),
                at: now,
                bytes,
                format: self.prepared.format,
                projects,
                complete: true,
                text_sheets: Some(text_sheets),
            };
            // Written last (and durably): its presence is what makes the folder a backup.
            write_atomic(&tmp.join(MANIFEST_FILE), &m.to_bytes(), true)?;
            fs::rename(&tmp, &path)?;
            sync_dir(&dir)?;
            Ok(m)
        })();
        self.problems.append(&mut skipped);
        let m = match result {
            Ok(m) => m,
            Err(e) => {
                let _ = fs::remove_dir_all(&tmp);
                return Err(e);
            }
        };
        Ok(BackupInfo {
            path: path.to_string_lossy().into_owned(),
            at: m.at,
            bytes: m.bytes,
            kind,
            projects: m.projects,
        })
    }

    /// Removes automatic backups that retention no longer keeps. Returns how many were removed.
    pub fn prune_backups(&mut self) -> Result<u32> {
        self.writable()?;
        let autos: Vec<BackupInfo> = self
            .backups()
            .into_iter()
            .filter(|b| b.kind == BackupKind::Auto)
            .collect();
        let local: Vec<i64> = autos
            .iter()
            .map(|b| b.at + (self.local_offset)(b.at))
            .collect();
        let keep = keep_flags(&local);
        let dir = self.backups_dir();
        let mut removed = 0;
        for (b, keep) in autos.iter().zip(keep) {
            let path = Path::new(&b.path);
            // Only ever our own folders.
            let ours = path.parent() == Some(dir.as_path())
                && path
                    .file_name()
                    .is_some_and(|n| n.to_string_lossy().starts_with(AUTO));
            if !keep && ours {
                fs::remove_dir_all(path)?;
                removed += 1;
            }
        }
        Ok(removed)
    }

    /// Imports the projects of a backup (any library-shaped folder of this format) as new projects
    /// with new ids. Nothing in the library is overwritten. Projects that were deleted when the
    /// backup was made are skipped, and so are trashed sheets and deleted folders; titles,
    /// goals, folder names and order, sheet text, created/modified times and episode metadata are
    /// kept. History is not copied (it stays in the backup). Returns the new projects.
    pub fn restore_backup_as_copies(&mut self, path: &str) -> Result<Vec<ProjectSummary>> {
        self.restore_backup_as_copies_with_suffix(path, "")
    }

    /// [`Store::restore_backup_as_copies`], with `suffix` appended to every restored title (e.g.
    /// " (백업 10월 24일)", worded by the app); empty = titles as they are. (added: qa1)
    pub fn restore_backup_as_copies_with_suffix(
        &mut self,
        path: &str,
        suffix: &str,
    ) -> Result<Vec<ProjectSummary>> {
        self.writable()?;
        let src = Path::new(path);
        let file = LibraryFile::read(src)?
            .ok_or_else(|| invalid(format!("not a backup: no {LIBRARY_FILE} in {path}")))?;
        if file.format != self.prepared.format {
            return Err(invalid(format!(
                "backup is format {}, this library is format {}",
                file.format, self.prepared.format
            )));
        }
        if fs::canonicalize(src).ok() == fs::canonicalize(&self.root).ok() {
            return Err(invalid("that is the library itself"));
        }
        let mut loaded = Vec::new();
        let mut names = list(&src.join(PROJECTS_DIR))?;
        names.sort();
        for id in names {
            let dir = src.join(PROJECTS_DIR).join(&id);
            if id.starts_with('.') || !dir.is_dir() {
                continue;
            }
            if let Some(p) = Project::load(&id, &dir, false)?
                && p.toc.deleted.is_none()
            {
                loaded.push(p);
            }
        }
        loaded.sort_by(|a, b| {
            a.toc
                .created
                .cmp(&b.toc.created)
                .then_with(|| a.id.cmp(&b.id))
        });
        let mut copies: Vec<(Toc, Vec<NewSheet>)> = loaded.iter().map(copy_of).collect();
        for (toc, _) in &mut copies {
            toc.title.push_str(suffix);
        }
        self.create_projects_all_or_nothing(copies)
    }
}

/// Whether a backup holds any sheet with text. Manifests say so since qa1; for older ones the
/// backup's projects are read (only asked about the newest automatic backup).
fn backup_has_text(path: &Path) -> bool {
    if let Some(n) = Manifest::read(path).and_then(|m| m.text_sheets) {
        return n > 0;
    }
    let projects = path.join(PROJECTS_DIR);
    list(&projects).unwrap_or_default().iter().any(|id| {
        Project::load(id, &projects.join(id), false)
            .ok()
            .flatten()
            .is_some_and(|p| {
                p.chains
                    .iter()
                    .any(|(c, ch)| c != Toc::SHEET_ID && !ch.text.is_empty())
            })
    })
}

fn tmp_file(tmp: &Path, name: &str) -> Result<PathBuf> {
    fs::create_dir_all(tmp)?;
    Ok(tmp.join(name))
}

/// A fresh table of contents (new folder ids, filled by `create_project_from`) and the live sheets.
fn copy_of(p: &Project) -> (Toc, Vec<NewSheet>) {
    let mut toc = Toc {
        title: p.toc.title.clone(),
        language: p.toc.language,
        goal: p.toc.goal,
        created: p.toc.created,
        ..Default::default()
    };
    let mut sheets = Vec::new();
    for f in p.toc.folders.iter().filter(|f| f.deleted.is_none()) {
        let fi = toc.folders.len();
        toc.folders.push(ithaca_model::FolderEntry::new(
            uuid::Uuid::new_v4().simple().to_string(),
            f.name.clone(),
        ));
        for s in p.toc.live_sheets(f) {
            let entry = &p.toc.sheets[s];
            let chain = p.chains.get(s);
            sheets.push(NewSheet {
                folder: fi,
                text: chain.map(|c| c.text.clone()).unwrap_or_default(),
                created: entry.created,
                modified: chain.and_then(|c| c.head()).map_or(entry.created, |m| m.at),
                episode: entry.episode.clone(),
            });
        }
    }
    (toc, sheets)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stamps_are_utc_minutes() {
        assert_eq!(stamp(1_792_800_000_000), "2026-10-24-0000");
        assert_eq!(
            stamp(1_792_800_000_000 + 13 * 3_600_000 + 7 * 60_000 + 59_999),
            "2026-10-24-1307"
        );
    }

    #[test]
    fn retention_keeps_7_days_and_4_weeks() {
        let t0 = 1_792_800_000_000; // Saturday 2026-10-24 00:00 UTC
        // Two backups a day for 40 days, newest first.
        let ats: Vec<i64> = (0..80)
            .map(|i| t0 + 13 * 3_600_000 - i * DAY_MS / 2)
            .collect();
        let keep = keep_flags(&ats);
        let kept: Vec<i64> = ats
            .iter()
            .zip(&keep)
            .filter(|(_, k)| **k)
            .map(|(a, _)| *a)
            .collect();
        // Newest of each of the last 7 days …
        for d in 0..7 {
            assert!(kept.contains(&ats[2 * d]), "day {d}");
            assert!(!kept.contains(&ats[2 * d + 1]));
        }
        // … which span this week and last (Sat … Mon, Sun), plus the newest of the 2 weeks before.
        assert_eq!(kept.len(), 7 + 2);
        assert!(kept.iter().all(|a| *a > t0 - 28 * DAY_MS));
    }
}
