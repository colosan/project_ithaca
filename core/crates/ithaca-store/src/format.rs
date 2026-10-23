//! `library.json`, format versions and migrations (ADR-0008 §5, core/FORMAT.md §Versions).

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::{Result, StoreError};
use crate::fsutil::{copy_dir, utc_date, write_atomic};

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
}

/// Copies the whole library (except earlier backups) to `Backups/pre-migration-<from>-<to>-<date>/`.
pub fn backup(root: &Path, from: u32, to: u32, now: i64) -> Result<PathBuf> {
    let base = format!("pre-migration-{from}-{to}-{}", utc_date(now));
    let dir = root.join(BACKUPS_DIR);
    let mut path = dir.join(&base);
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{base}-{n}"));
        n += 1;
    }
    copy_dir(root, &path, &|name| name == BACKUPS_DIR)?;
    Ok(path)
}

/// Creates, checks and migrates `library.json`. `supported` is the newest format this build knows.
pub fn prepare(root: &Path, supported: u32, steps: &[Migration], now: i64) -> Result<Prepared> {
    fs::create_dir_all(root)?;
    let Some(mut file) = LibraryFile::read(root)? else {
        if root.join(PROJECTS_DIR).exists() {
            return Err(StoreError::Corrupt(format!("{LIBRARY_FILE} is missing")));
        }
        let file = LibraryFile {
            format: supported,
            created: now,
            extra: Map::new(),
        };
        file.write(root)?;
        fs::create_dir_all(root.join(PROJECTS_DIR))?;
        return Ok(Prepared {
            format: supported,
            read_only: false,
            migrated_from: None,
            backup_path: None,
        });
    };
    if file.format == 0 {
        return Err(StoreError::Corrupt("format 0".into()));
    }
    if file.format > supported {
        return Ok(Prepared {
            format: file.format,
            read_only: true,
            migrated_from: None,
            backup_path: None,
        });
    }
    if file.format == supported {
        fs::create_dir_all(root.join(PROJECTS_DIR))?;
        return Ok(Prepared {
            format: supported,
            read_only: false,
            migrated_from: None,
            backup_path: None,
        });
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
    let backup_path = backup(root, from, supported, now)?;
    for step in path {
        (step.run)(root)?;
        // Re-read: a step may rewrite library.json itself.
        file = LibraryFile::read(root)?
            .ok_or_else(|| StoreError::Corrupt(format!("{LIBRARY_FILE} vanished")))?;
        file.format = step.from + 1;
        file.write(root)?;
    }
    Ok(Prepared {
        format: supported,
        read_only: false,
        migrated_from: Some(from),
        backup_path: Some(backup_path),
    })
}
