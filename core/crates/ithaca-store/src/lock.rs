//! Cross-process exclusive lock on a library (core/FORMAT.md §Lock).
//!
//! A writable open holds an advisory `flock(LOCK_EX)` on `<library>/.lock` for as long as the
//! [`crate::Store`] lives; the operating system releases it when the file is closed (drop, crash or
//! kill). A second open — another app instance, another build, a test harness — finds it held and
//! opens read-only instead of writing over the first one's work. The lock is per open file
//! description, so two opens inside one process exclude each other too.

use std::fs::{File, OpenOptions, TryLockError};
use std::io;
use std::path::Path;

pub const LOCK_FILE: &str = ".lock";

/// Takes the library lock. `Ok(None)` = another open holds it.
pub fn acquire(root: &Path) -> io::Result<Option<File>> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(root.join(LOCK_FILE))?;
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(e)) => Err(e),
    }
}
