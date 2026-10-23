//! `library.json`, format versions and migrations (ADR-0008 §5, core/FORMAT.md §Versions).

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::backup::MANIFEST_FILE;
use crate::error::{Result, StoreError};
use crate::fsutil::{TEMP_PREFIX, copy_dir, list, sync_dir, utc_date, write_atomic};
use crate::lock::LOCK_FILE;

/// The on-disk format this core reads and writes.
pub const FORMAT: u32 = 1;

pub const LIBRARY_FILE: &str = "library.json";
pub const BACKUPS_DIR: &str = "Backups";
pub const PROJECTS_DIR: &str = "projects";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LibraryFile {
    pub format: u32,
    pub created: i64,
    /// Fields a newer format may add; kept as they are.
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl LibraryFile {
    pub fn read(root: &Path) -> Result<Option<LibraryFile>> {
        match fs::read(root.join(LIBRARY_FILE)) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|e| StoreError::Corrupt(format!("{LIBRARY_FILE}: {e}"))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    pub fn write(&self, root: &Path) -> Result<()> {
        let mut bytes = serde_json::to_vec_pretty(self).expect("library file serializes");
        bytes.push(b'\n');
        Ok(write_atomic(&root.join(LIBRARY_FILE), &bytes, true)?)
    }
}

/// One step from format `from` to `from + 1`. Runs on the library folder after the backup is made.
#[derive(Clone, Copy)]
pub struct Migration {
    pub from: u32,
    pub run: fn(root: &Path) -> Result<()>,
}

/// The real migrations, in order. Empty while format 1 is the only format.
pub fn migrations() -> Vec<Migration> {
    Vec::new()
}

/// What opening did to the folder before any project was read.
#[derive(Debug, Clone, PartialEq)]
pub struct Prepared {
    pub format: u32,
    pub read_only: bool,
    pub migrated_from: Option<u32>,
    pub backup_path: Option<PathBuf>,
    /// Why the library opened read-only or what went wrong on the way, for the app to show.
    pub problems: Vec<String>,
}

impl Prepared {
    fn new(format: u32, read_only: bool) -> Prepared {
        Prepared {
            format,
            read_only,
            migrated_from: None,
            backup_path: None,
            problems: Vec::new(),
        }
    }

    fn read_only_because(format: u32, problem: String) -> Prepared {
        Prepared {
            problems: vec![problem],
            ..Prepared::new(format, true)
        }
    }
}

/// Whether a writable open may even try this folder: not when it is newer than this core, and not
/// when `library.json` is missing or unreadable next to existing projects. Those open read-only
/// without writing anything, not even the lock file.
pub fn may_write(root: &Path, supported: u32) -> bool {
    match LibraryFile::read(root) {
        Ok(Some(f)) => f.format <= supported,
        Ok(None) => !root.join(PROJECTS_DIR).exists(),
        Err(_) => false,
    }
}

/// `pre-migration-<from>-<to>-<date>[-n]` under `<library>/Backups`, not yet taken.
fn backup_target(root: &Path, from: u32, to: u32, now: i64) -> PathBuf {
    let base = format!("{PRE_MIGRATION}{from}-{to}-{}", utc_date(now));
    let dir = root.join(BACKUPS_DIR);
    let mut path = dir.join(&base);
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{base}-{n}"));
        n += 1;
    }
    path
}

pub const PRE_MIGRATION: &str = "pre-migration-";
pub const FAILED_MIGRATION: &str = "failed-migration-";

/// Copies the whole library (except `Backups/` and the lock file) to
/// `Backups/pre-migration-<from>-<to>-<date>/`: into a `.tmp-` folder, flushed, a complete
/// `backup.json` manifest written last, then renamed into place. A crash part way leaves only a
/// `.tmp-` folder, which is never listed and never restored from.
pub fn backup(root: &Path, from: u32, to: u32, now: i64) -> Result<PathBuf> {
    let path = backup_target(root, from, to, now);
    let dir = root.join(BACKUPS_DIR);
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = dir.join(format!("{TEMP_PREFIX}{name}-{}", std::process::id()));
    let result = (|| -> Result<()> {
        let _ = fs::remove_dir_all(&tmp);
        copy_dir(root, &tmp, &|name| name == BACKUPS_DIR || name == LOCK_FILE)?;
        let manifest = crate::backup::Manifest {
            v: 1,
            kind: crate::backup::PRE_MIGRATION_KIND.into(),
            at: now,
            bytes: crate::backup::dir_size(&tmp),
            format: from,
            projects: crate::backup::project_count(&tmp),
            complete: true,
        };
        write_atomic(&tmp.join(MANIFEST_FILE), &manifest.to_bytes(), true)?;
        fs::rename(&tmp, &path)?;
        sync_dir(&dir)?;
        Ok(())
    })();
    if let Err(e) = result {
        let _ = fs::remove_dir_all(&tmp);
        return Err(e);
    }
    Ok(path)
}

/// Puts the library back as the pre-migration backup had it. The half-migrated files are moved
/// aside to `Backups/failed-migration-…` (never deleted), then the backup is copied back.
fn restore_from_backup(root: &Path, backup: &Path, from: u32, to: u32, now: i64) -> Result<()> {
    let base = format!("{FAILED_MIGRATION}{from}-{to}-{}", utc_date(now));
    let dir = root.join(BACKUPS_DIR);
    let mut aside = dir.join(&base);
    let mut n = 2;
    while aside.exists() {
        aside = dir.join(format!("{base}-{n}"));
        n += 1;
    }
    fs::create_dir_all(&aside)?;
    for name in list(root)? {
        if name == BACKUPS_DIR || name == LOCK_FILE {
            continue;
        }
        fs::rename(root.join(&name), aside.join(&name))?;
    }
    sync_dir(&aside)?;
    sync_dir(root)?;
    copy_dir(backup, root, &|name| name == MANIFEST_FILE)?;
    Ok(())
}

/// Creates, checks and migrates `library.json`. `supported` is the newest format this build knows.
/// `can_write` is false when another open holds the library lock (or the folder must not be
/// written, see [`may_write`]): then nothing is written and the result is read-only.
pub fn prepare(
    root: &Path,
    supported: u32,
    steps: &[Migration],
    now: i64,
    can_write: bool,
) -> Result<Prepared> {
    let has_projects = root.join(PROJECTS_DIR).exists();
    let file = match LibraryFile::read(root) {
        Ok(f) => f,
        Err(e) => {
            return Ok(Prepared::read_only_because(
                supported,
                format!("{e}. Opened read-only so nothing is overwritten."),
            ));
        }
    };
    let Some(mut file) = file else {
        if has_projects {
            return Ok(Prepared::read_only_because(
                supported,
                format!(
                    "{LIBRARY_FILE} is missing but the folder holds projects. Opened read-only \
                     so nothing is overwritten."
                ),
            ));
        }
        if !can_write {
            // Another open is creating this library right now.
            return Ok(Prepared::new(supported, true));
        }
        fs::create_dir_all(root)?;
        let file = LibraryFile {
            format: supported,
            created: now,
            extra: Map::new(),
        };
        file.write(root)?;
        fs::create_dir_all(root.join(PROJECTS_DIR))?;
        return Ok(Prepared::new(supported, false));
    };
    if file.format == 0 {
        return Err(StoreError::Corrupt("format 0".into()));
    }
    if file.format > supported {
        return Ok(Prepared::new(file.format, true));
    }
    if file.format == supported {
        if can_write {
            fs::create_dir_all(root.join(PROJECTS_DIR))?;
        }
        return Ok(Prepared::new(supported, !can_write));
    }
    // Check the whole path exists before touching anything.
    let from = file.format;
    let path: Vec<Migration> = (from..supported)
        .map(|f| {
            steps
                .iter()
                .find(|m| m.from == f)
                .copied()
                .ok_or_else(|| StoreError::Corrupt(format!("no migration from format {f}")))
        })
        .collect::<Result<_>>()?;
    if !can_write {
        return Ok(Prepared::read_only_because(
            from,
            format!(
                "The library needs an update from format {from} to {supported}, but another \
                 Ithaca has it open. Opened read-only."
            ),
        ));
    }
    let backup_path = match backup(root, from, supported, now) {
        Ok(p) => p,
        Err(e) => {
            return Ok(Prepared::read_only_because(
                from,
                format!(
                    "Could not back up before updating the library ({e}); nothing was changed. \
                     Opened read-only."
                ),
            ));
        }
    };
    let mut run = || -> Result<()> {
        for step in &path {
            (step.run)(root)?;
            // Re-read: a step may rewrite library.json itself.
            file = LibraryFile::read(root)?
                .ok_or_else(|| StoreError::Corrupt(format!("{LIBRARY_FILE} vanished")))?;
            file.format = step.from + 1;
            file.write(root)?;
        }
        Ok(())
    };
    if let Err(e) = run() {
        let restored = restore_from_backup(root, &backup_path, from, supported, now);
        let what = match restored {
            Ok(()) => format!(
                "The library was put back as it was from {}",
                backup_path.display()
            ),
            Err(r) => format!(
                "Putting it back also failed ({r}); a full copy is in {}",
                backup_path.display()
            ),
        };
        return Ok(Prepared {
            backup_path: Some(backup_path),
            ..Prepared::read_only_because(
                from,
                format!(
                    "Updating the library from format {from} to {supported} failed: {e}. \
                     {what}. Opened read-only."
                ),
            )
        });
    }
    Ok(Prepared {
        migrated_from: Some(from),
        backup_path: Some(backup_path),
        ..Prepared::new(supported, false)
    })
}
