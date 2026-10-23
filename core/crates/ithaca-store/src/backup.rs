//! Local backups (design/PRODUCT.md `백업`, research §5 P0 "매일 로컬 백업"; core/FORMAT.md §Backups).
//!
//! A backup is a library-shaped folder — `library.json`, `projects/<id>/changes/<hash>` and a
//! `backup.json` manifest — next to the library: `<library parent>/Backups/auto-<UTC yyyy-mm-dd-HHMM>/`.
//! Blocks are immutable and the store is behind one lock, so copying the block files is a consistent
//! snapshot. Caches are derived and left out. A backup is written under a `.tmp-` name and renamed
//! into place, so a crash never leaves a half backup that looks whole.

use std::fs;
use std::path::{Path, PathBuf};

use ithaca_ledger::block::is_hash_name;
use ithaca_model::Toc;
use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::format::{BACKUPS_DIR, LIBRARY_FILE, LibraryFile, PROJECTS_DIR};
use crate::fsutil::{is_temp, list, utc_date, write_atomic};
use crate::project::{CHANGES_DIR, Project};
use crate::{BackupInfo, BackupKind, NewSheet, ProjectSummary, Store, invalid};

pub const MANIFEST_FILE: &str = "backup.json";
pub const DAY_MS: i64 = 86_400_000;
/// Retention of automatic backups: the newest of each of the last 7 days that have one, and the
/// newest of each of the last 4 weeks (Monday-based, UTC) that have one. Manual and pre-migration
/// backups are never removed.
pub const KEEP_DAILY: usize = 7;
pub const KEEP_WEEKLY: usize = 4;

const AUTO: &str = "auto";
const MANUAL: &str = "manual";
const PRE_MIGRATION: &str = "pre-migration-";

#[derive(Debug, Serialize, Deserialize)]
struct Manifest {
    v: u32,
    /// `auto` | `manual`
    kind: String,
    at: i64,
    bytes: u64,
    format: u32,
    projects: u32,
}

/// `yyyy-mm-dd-HHMM` in UTC.
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

fn dir_size(path: &Path) -> u64 {
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

fn project_count(backup: &Path) -> u32 {
    list(&backup.join(PROJECTS_DIR))
        .unwrap_or_default()
        .iter()
        .filter(|n| !n.starts_with('.') && backup.join(PROJECTS_DIR).join(n).is_dir())
        .count() as u32
}

/// Which automatic backups retention keeps (`at` newest first in, flags out).
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

    /// Writes an automatic backup, then applies retention to automatic backups.
    pub fn backup_now(&mut self) -> Result<BackupInfo> {
        let info = self.write_backup(AUTO, BackupKind::Auto)?;
        self.prune_backups()?;
        Ok(info)
    }

    /// Writes a backup the writer asked for. Retention never removes it.
    pub fn backup_manual(&mut self) -> Result<BackupInfo> {
        self.write_backup(MANUAL, BackupKind::Manual)
    }

    /// No automatic backup was made in the last 24 hours (and the library is writable).
    pub fn backup_due(&self) -> bool {
        if self.prepared.read_only {
            return false;
        }
        let since = self.now() - DAY_MS;
        !self
            .backups()
            .iter()
            .any(|b| b.kind == BackupKind::Auto && b.at > since)
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
            let Some(m) = fs::read(path.join(MANIFEST_FILE))
                .ok()
                .and_then(|b| serde_json::from_slice::<Manifest>(&b).ok())
            else {
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
            out.push(BackupInfo {
                path: path.to_string_lossy().into_owned(),
                at: modified_ms(&path),
                bytes: dir_size(&path),
                kind: BackupKind::PreMigration,
                projects: project_count(&path),
            });
        }
        out.sort_by(|a, b| b.at.cmp(&a.at).then_with(|| b.path.cmp(&a.path)));
        out
    }

    fn write_backup(&mut self, prefix: &str, kind: BackupKind) -> Result<BackupInfo> {
        self.writable()?;
        let now = self.now();
        let dir = self.backups_dir();
        fs::create_dir_all(&dir)?;
        // Backups that stopped half way (crash, full disk).
        for name in list(&dir)? {
            if is_temp(&name) && (name.contains(AUTO) || name.contains(MANUAL)) {
                let _ = fs::remove_dir_all(dir.join(&name));
            }
        }
        let base = format!("{prefix}-{}", stamp(now));
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
        let result = (|| -> Result<Manifest> {
            let _ = fs::remove_dir_all(&tmp);
            let mut bytes = fs::copy(self.root.join(LIBRARY_FILE), tmp_file(&tmp, LIBRARY_FILE)?)?;
            let mut projects = 0;
            for id in list(&self.root.join(PROJECTS_DIR))? {
                let src = self.root.join(PROJECTS_DIR).join(&id).join(CHANGES_DIR);
                if id.starts_with('.') || !src.is_dir() {
                    continue;
                }
                let dst = tmp.join(PROJECTS_DIR).join(&id).join(CHANGES_DIR);
                fs::create_dir_all(&dst)?;
                projects += 1;
                for f in list(&src)? {
                    if is_hash_name(&f) {
                        bytes += fs::copy(src.join(&f), dst.join(&f))?;
                    }
                }
            }
            let m = Manifest {
                v: 1,
                kind: prefix.to_string(),
                at: now,
                bytes,
                format: self.prepared.format,
                projects,
            };
            let mut json = serde_json::to_vec_pretty(&m).expect("manifest serializes");
            json.push(b'\n');
            write_atomic(&tmp.join(MANIFEST_FILE), &json, true)?;
            fs::rename(&tmp, &path)?;
            Ok(m)
        })();
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
        let keep = keep_flags(&autos.iter().map(|b| b.at).collect::<Vec<_>>());
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
        let mut out = Vec::new();
        for p in loaded {
            let (toc, sheets) = copy_of(&p);
            out.push(self.create_project_from(toc, &sheets)?);
        }
        Ok(out)
    }
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
