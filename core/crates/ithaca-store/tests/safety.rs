//! Data-safety regressions: cross-process lock, cache integrity, resilient open, durable backups
//! and migrations, non-fatal cleanups. Several scenarios come from a reviewer's reproduction harness.

mod common;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use common::*;
use ithaca_ledger::{Actor, Block, Body, Kind};
use ithaca_model::Language;
use ithaca_store::format::LibraryFile;
use ithaca_store::fsutil::copy_dir;
use ithaca_store::{BackupKind, Migration, OpenOptions, Store, StoreError};

fn first_sheet(s: &Store, p: &str) -> (String, String) {
    let o = s.outline(p).unwrap();
    (o.folders[0].id.clone(), o.folders[0].sheets[0].id.clone())
}

fn set_mode(p: &Path, mode: u32) {
    fs::set_permissions(p, fs::Permissions::from_mode(mode)).unwrap();
}

// ── 1. Cross-process lock ───────────────────────────────────────────

#[test]
fn second_open_is_read_only_and_cannot_clobber_the_first() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut a) = open(dir.path());
    let p = a
        .create_project("P", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    let (fid, s0) = first_sheet(&a, &p);

    // A second open (another process in real life; flock excludes per open file too).
    let (_c2, mut b) = open(dir.path());
    let info = b.info();
    assert!(info.locked_by_other && info.read_only, "{info:?}");
    assert!(!info.problems.is_empty());
    assert!(!a.info().locked_by_other && !a.info().read_only);

    // The reviewer's scenario: A adds a chapter and edits; stale B renames and edits.
    let s = a.create_sheet(&p, &fid, "IMPORTANT CHAPTER").unwrap().id;
    assert_eq!(
        b.rename_folder(&p, &fid, "renamed"),
        Err(StoreError::ReadOnly)
    );
    a.save_sheet(&p, &s0, "A newer text").unwrap();
    assert_eq!(b.save_sheet(&p, &s0, "B text"), Err(StoreError::ReadOnly));
    assert_eq!(b.backup_now(), Err(StoreError::ReadOnly));
    assert!(!b.backup_due());
    drop(a);
    drop(b);

    let (_c3, c) = open(dir.path());
    assert!(!c.info().read_only, "the lock is released on drop");
    let o = c.outline(&p).unwrap();
    assert_eq!(o.folders[0].name, "F");
    assert!(o.folders[0].sheets.iter().any(|x| x.id == s));
    assert_eq!(c.sheet_text(&p, &s0).unwrap(), "A newer text");
    assert!(!c.sheet_summary_of(&p, &s0).unwrap().branched);
}

#[test]
fn read_only_open_leaves_in_flight_temp_files_alone() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut a) = open(dir.path());
    let p = a
        .create_project("P", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    // A write in progress in the lock holder.
    let tmp = changes(&a, &p).join(".tmp-abc-999-0");
    fs::write(&tmp, b"half").unwrap();
    let (_c2, b) = open(dir.path());
    assert!(b.info().locked_by_other);
    assert!(tmp.exists(), "a read-only open never removes temp files");
    drop(b);
    drop(a);
    // Only an open that holds the lock cleans them.
    let (_c3, _s) = open(dir.path());
    assert!(!tmp.exists());
}

// ── 2. Cache integrity ──────────────────────────────────────────────

#[test]
fn tampered_cache_text_is_rebuilt_and_saves_stay_correct() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut a) = open(dir.path());
    let p = a
        .create_project("P", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    let (_f, s0) = first_sheet(&a, &p);
    a.save_sheet(&p, &s0, "real text").unwrap();
    drop(a);

    // Change only the cached text (valid JSON, wrong content).
    let cf = dir
        .path()
        .join("projects")
        .join(&p)
        .join("cache")
        .join(format!("{s0}.json"));
    let mut v: serde_json::Value = serde_json::from_slice(&fs::read(&cf).unwrap()).unwrap();
    v["text"] = "STALE".into();
    fs::write(&cf, serde_json::to_vec(&v).unwrap()).unwrap();

    let (_c, mut a) = open(dir.path());
    assert_eq!(a.sheet_text(&p, &s0).unwrap(), "real text");
    a.save_sheet(&p, &s0, "real text plus").unwrap();
    drop(a);

    // Rebuilt purely from blocks, the saved text is what was saved.
    fs::remove_dir_all(dir.path().join("projects").join(&p).join("cache")).unwrap();
    let (_c, a) = open(dir.path());
    assert_eq!(a.sheet_text(&p, &s0).unwrap(), "real text plus");
    assert!(a.verify(&p).unwrap().ok);
}

#[test]
fn unparseable_cache_is_rebuilt() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut a) = open(dir.path());
    let p = a
        .create_project("P", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    let (_f, s0) = first_sheet(&a, &p);
    a.save_sheet(&p, &s0, "글").unwrap();
    drop(a);
    let cache = dir.path().join("projects").join(&p).join("cache");
    for f in fs::read_dir(&cache).unwrap() {
        fs::write(f.unwrap().path(), b"{\"v\":2,\"sheet\":").unwrap();
    }
    let (_c, a) = open(dir.path());
    assert_eq!(a.sheet_text(&p, &s0).unwrap(), "글");
    assert_eq!(a.projects()[0].title, "P");
}

// ── 3. Resilient open ───────────────────────────────────────────────

#[test]
fn one_unreadable_project_does_not_fail_the_library() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut a) = open(dir.path());
    let good = a
        .create_project("Good", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    let bad = a
        .create_project("Other", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    drop(a);
    let ch = dir.path().join("projects").join(&bad).join("changes");
    set_mode(&ch, 0o000);
    let r = Store::open(dir.path(), "mac-test");
    set_mode(&ch, 0o755);
    let mut s = r.unwrap();
    let info = s.info();
    assert!(!info.read_only);
    assert!(
        info.problems.iter().any(|m| m.contains(&bad)),
        "{:?}",
        info.problems
    );
    assert_eq!(
        s.projects().iter().map(|p| &p.id).collect::<Vec<_>>(),
        [&good]
    );
    // The rest of the library works.
    let (_f, s0) = first_sheet(&s, &good);
    s.save_sheet(&good, &s0, "ok").unwrap();
    drop(s);
    // Untouched: it loads again once readable.
    let (_c, s) = open(dir.path());
    assert_eq!(s.projects().len(), 2);
}

#[test]
fn project_with_corrupt_toc_is_skipped_and_left_untouched() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut a) = open(dir.path());
    let good = a
        .create_project("Good", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    drop(a);
    // A project whose table of contents is a valid block holding text that is not a toc.
    let bad = "0123456789abcdef0123456789abcdef";
    let pdir = dir.path().join("projects").join(bad);
    fs::create_dir_all(pdir.join("changes")).unwrap();
    let b = Block::seal(
        vec![],
        "toc",
        1,
        "dev",
        Actor::Me,
        Kind::Meta,
        T0,
        Body::Snapshot("not json".into()),
    );
    fs::write(pdir.join("changes").join(&b.hash), b.to_bytes()).unwrap();
    // An orphan block too (a project folder with blocks but no toc chain at all).
    let orphan = dir
        .path()
        .join("projects")
        .join("fedcba9876543210fedcba9876543210");
    fs::create_dir_all(orphan.join("changes")).unwrap();
    let o = Block::seal(
        vec![],
        "s1",
        1,
        "dev",
        Actor::Me,
        Kind::Edit,
        T0,
        Body::Snapshot("살아남은 글".into()),
    );
    fs::write(orphan.join("changes").join(&o.hash), o.to_bytes()).unwrap();

    let before = snapshot_tree(&pdir);
    let (_c, s) = open(dir.path());
    let info = s.info();
    assert_eq!(s.projects().len(), 1);
    assert_eq!(s.projects()[0].id, good);
    assert!(info.problems.iter().any(|m| m.contains(bad)), "{info:?}");
    assert!(
        info.problems
            .iter()
            .any(|m| m.contains("fedcba9876543210fedcba9876543210")),
        "{info:?}"
    );
    assert_eq!(snapshot_tree(&pdir), before, "no cache, no cleanup");
    assert!(orphan.join("changes").join(&o.hash).exists());
}

#[test]
fn failed_purge_is_a_problem_not_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let (clock, mut s) = open(dir.path());
    let keep = s
        .create_project("Keep", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    let gone = s
        .create_project("Gone", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    s.delete_project(&gone).unwrap();
    drop(s);
    clock.advance(31 * 86_400_000);
    // Write today so the clock guard trusts the clock, then make the project unremovable.
    let reopen = || {
        let t = clock.0.clone();
        Store::open_with(
            dir.path(),
            "mac-test",
            OpenOptions {
                clock: std::sync::Arc::new(move || {
                    t.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
                }),
                ..Default::default()
            },
        )
    };
    let mut s = reopen().unwrap();
    let (_f, ks) = first_sheet(&s, &keep);
    s.save_sheet(&keep, &ks, "today").unwrap();
    drop(s);
    let ch = dir.path().join("projects").join(&gone).join("changes");
    set_mode(&ch, 0o555);
    let r = reopen();
    set_mode(&ch, 0o755);
    let s = r.unwrap();
    assert!(
        s.info()
            .problems
            .iter()
            .any(|m| m.contains("Could not remove deleted project")),
        "{:?}",
        s.info().problems
    );
    assert_eq!(s.projects().len(), 1);
    drop(s);
    let s = reopen().unwrap();
    assert!(s.deleted_projects().is_empty(), "purged once it can be");
}

// ── 4. Migrations ───────────────────────────────────────────────────

fn failing_step(root: &Path) -> Result<(), StoreError> {
    // Mutates first, then fails half way.
    let mut f = LibraryFile::read(root)?.unwrap();
    f.extra.insert("half".into(), serde_json::json!(true));
    f.write(root)?;
    fs::write(root.join("HALF-MIGRATED"), "x")?;
    for p in fs::read_dir(root.join("projects"))? {
        let cache = p?.path().join("cache");
        let _ = fs::remove_dir_all(cache);
    }
    Err(StoreError::Corrupt("step exploded".into()))
}

#[test]
fn failed_migration_restores_the_library_and_opens_read_only() {
    let dir = tempfile::tempdir().unwrap();
    copy_dir(&fixtures().join("library-v1"), dir.path(), &|_| false).unwrap();
    let before = snapshot_tree(dir.path());
    let (_tc, clock) = TestClock::new(1_790_100_000_000);
    let o = OpenOptions {
        supported_format: 2,
        migrations: vec![Migration {
            from: 1,
            run: failing_step,
        }],
        clock,
        ..Default::default()
    };
    let mut s = Store::open_with(dir.path(), "mac-test", o).unwrap();
    let info = s.info();
    assert!(info.read_only && !info.locked_by_other);
    assert_eq!((info.format, info.migrated_from), (1, None));
    assert!(
        info.problems[0].contains("step exploded"),
        "{:?}",
        info.problems
    );
    assert_eq!(s.projects().len(), 2, "still readable");
    assert_eq!(
        s.save_sheet("x", "y", "z"),
        Err(StoreError::ReadOnly),
        "read-only"
    );
    drop(s);
    // The library is back exactly as it was; the half-migrated files were moved aside, not lost.
    let now: Vec<_> = snapshot_tree(dir.path())
        .into_iter()
        .filter(|(p, _)| !p.starts_with("Backups") && p != Path::new(".lock"))
        .collect();
    assert_eq!(now, before);
    let backups: Vec<String> = fs::read_dir(dir.path().join("Backups"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert!(backups.iter().any(|n| n.starts_with("pre-migration-1-2-")));
    let aside = backups
        .iter()
        .find(|n| n.starts_with("failed-migration-1-2-"))
        .unwrap();
    assert!(
        dir.path()
            .join("Backups")
            .join(aside)
            .join("HALF-MIGRATED")
            .exists()
    );
    // And this (format 1) core opens it normally afterwards.
    let (_c, s) = open(dir.path());
    assert!(!s.info().read_only);
    assert_eq!(s.projects().len(), 2);
}

#[test]
fn migration_is_not_run_while_another_open_holds_the_lock() {
    let dir = tempfile::tempdir().unwrap();
    copy_dir(&fixtures().join("library-v1"), dir.path(), &|_| false).unwrap();
    let (_c, a) = open(dir.path());
    let (_tc, clock) = TestClock::new(1_790_100_000_000);
    let o = OpenOptions {
        supported_format: 2,
        migrations: vec![Migration {
            from: 1,
            run: failing_step,
        }],
        clock,
        ..Default::default()
    };
    let s = Store::open_with(dir.path(), "mac-test", o).unwrap();
    assert!(s.info().read_only && s.info().locked_by_other);
    assert!(!dir.path().join("Backups").exists(), "nothing written");
    assert!(!dir.path().join("HALF-MIGRATED").exists());
    drop(a);
}

// ── 5. Backups ──────────────────────────────────────────────────────

#[test]
fn failed_pruning_still_returns_the_backup() {
    let dir = tempfile::tempdir().unwrap();
    let lib = dir.path().join("Library");
    let (_c, mut s) = open(&lib);
    let p = s
        .create_project("P", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    let sheet = s.outline(&p).unwrap().folders[0].sheets[0].id.clone();
    s.save_sheet(&p, &sheet, "글").unwrap();
    // Two older automatic backups on the same day: retention drops the older one, which we make
    // impossible to remove.
    let backups = dir.path().join("Backups");
    for (name, at) in [
        ("auto-2026-10-20-0000", T0 - 4 * 86_400_000),
        ("auto-2026-10-20-0100", T0 - 4 * 86_400_000 + 3_600_000),
    ] {
        let b = backups.join(name);
        fs::create_dir_all(b.join("projects/x")).unwrap();
        fs::write(b.join("projects/x/f"), b"1").unwrap();
        fs::write(
            b.join("backup.json"),
            format!(
                r#"{{"v":1,"kind":"auto","at":{at},"bytes":1,"format":1,"projects":1,"complete":true}}"#
            ),
        )
        .unwrap();
    }
    let stuck = backups.join("auto-2026-10-20-0000/projects/x");
    set_mode(&stuck, 0o555);
    let r = s.backup_now();
    set_mode(&stuck, 0o755);
    let info = r.unwrap();
    assert_eq!(info.kind, BackupKind::Auto);
    assert!(Path::new(&info.path).join("backup.json").exists());
    assert!(
        s.info()
            .problems
            .iter()
            .any(|m| m.contains("old automatic backups")),
        "{:?}",
        s.info().problems
    );
}
