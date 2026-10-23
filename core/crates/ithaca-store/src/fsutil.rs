//! Small filesystem helpers: atomic writes and directory copies.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

/// Prefix of in-progress files. Anything with it is ignored on open (and removed when writable).
pub const TEMP_PREFIX: &str = ".tmp-";

static COUNTER: AtomicU64 = AtomicU64::new(0);

pub fn is_temp(name: &str) -> bool {
    name.starts_with(TEMP_PREFIX)
}

/// Flushes a folder's entries (names created, renamed or removed in it) to disk. Without this a
/// rename can be lost on power failure even though the file's data was flushed.
pub fn sync_dir(dir: &Path) -> io::Result<()> {
    match File::open(dir).and_then(|d| d.sync_all()) {
        Ok(()) => Ok(()),
        // Some filesystems (network, FUSE) refuse to sync a folder; nothing more can be done there.
        Err(e)
            if matches!(
                e.kind(),
                io::ErrorKind::InvalidInput | io::ErrorKind::Unsupported
            ) =>
        {
            Ok(())
        }
        Err(e) => Err(e),
    }
}

/// Copies one file and flushes the copy to disk. Returns the bytes copied.
pub fn copy_durable(from: &Path, to: &Path) -> io::Result<u64> {
    let n = fs::copy(from, to)?;
    File::open(to)?.sync_all()?;
    Ok(n)
}

/// Writes to a temp file in the same folder, then renames it into place, so readers see either
/// nothing or the whole file. `durable` also flushes the data to disk before the rename and the
/// folder entry after it.
pub fn write_atomic(path: &Path, bytes: &[u8], durable: bool) -> io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::other("no parent folder"))?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp = dir.join(format!("{TEMP_PREFIX}{name}-{}-{n}", std::process::id()));
    let result = (|| {
        let mut f = File::create(&tmp)?;
        f.write_all(bytes)?;
        if durable {
            f.sync_all()?;
        }
        drop(f);
        fs::rename(&tmp, path)?;
        if durable {
            sync_dir(dir)?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// Copies a folder tree, skipping top-level entries for which `skip` is true. Every copied file and
/// folder is flushed to disk, so the copy survives a power failure once this returns.
pub fn copy_dir(from: &Path, to: &Path, skip: &dyn Fn(&str) -> bool) -> io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if skip(&name) {
            continue;
        }
        let (src, dst) = (entry.path(), to.join(&name));
        if entry.file_type()?.is_dir() {
            copy_dir(&src, &dst, &|_| false)?;
        } else {
            copy_durable(&src, &dst)?;
        }
    }
    sync_dir(to)
}

/// File names in a folder; an absent folder is empty.
pub fn list(dir: &Path) -> io::Result<Vec<String>> {
    match fs::read_dir(dir) {
        Ok(rd) => rd
            .map(|e| e.map(|e| e.file_name().to_string_lossy().into_owned()))
            .collect(),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(e),
    }
}

/// `YYYY-MM-DD` (UTC) for a Unix time in milliseconds.
/// Offset of the system's local time from UTC at `ms`, in ms; 0 if unknown.
#[cfg(unix)]
pub fn local_offset_ms(ms: i64) -> i64 {
    let t = ms.div_euclid(1000) as libc::time_t;
    // SAFETY: `localtime_r` only writes the `tm` we pass and reads `t`; a zeroed `tm` is valid.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let ok = unsafe { !libc::localtime_r(&t, &mut tm).is_null() };
    if ok { tm.tm_gmtoff as i64 * 1000 } else { 0 }
}

#[cfg(not(unix))]
pub fn local_offset_ms(_ms: i64) -> i64 {
    0
}

pub fn utc_date(ms: i64) -> String {
    // Howard Hinnant's civil_from_days.
    let z = ms.div_euclid(86_400_000) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

#[cfg(test)]
mod tests {
    #[test]
    fn dates() {
        assert_eq!(super::utc_date(0), "1970-01-01");
        assert_eq!(super::utc_date(1_792_800_000_000), "2026-10-24");
        assert_eq!(super::utc_date(951_782_400_000), "2000-02-29");
    }
}
