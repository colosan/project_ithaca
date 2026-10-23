//! Automatic local backups, retention and restore as copies (core/FORMAT.md §Backups).

mod common;

use std::fs;
use std::path::Path;

use common::*;
use ithaca_model::{EpisodeInfo, EpisodeStatus, Language};
use ithaca_store::fsutil::copy_dir;
use ithaca_store::{BackupKind, Store, StoreError};

const HOUR: i64 = 3_600_000;
const DAY: i64 = 24 * HOUR;

/// The library lives at `<tmp>/Library`, so its backups go to `<tmp>/Backups`.
fn lib(dir: &Path) -> std::path::PathBuf {
    dir.join("Library")
}

/// A project whose first sheet has text (an empty library is never backed up automatically).
fn seed(s: &mut Store) -> String {
    let p = s
        .create_project("등대", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let sheet = s.outline(&p).unwrap().folders[0].sheets[0].id.clone();
    s.save_sheet(&p, &sheet, "첫 문장.").unwrap();
    p
}

#[test]
fn backup_now_then_restore_as_copies() {
    let dir = tempfile::tempdir().unwrap();
    let (clock, mut s) = open(&lib(dir.path()));
    assert!(!s.backup_due(), "an empty library is not backed up");
    let p = s
        .create_project("등대", Language::Ko, &["연재".into(), "설정".into()])
        .unwrap()
        .id;
    let o = s.outline(&p).unwrap();
    let (serial, ep1) = (o.folders[0].id.clone(), o.folders[0].sheets[0].id.clone());
    assert!(!s.backup_due(), "still no text");
    assert!(matches!(s.backup_now(), Err(StoreError::InvalidInput(_))));
    s.save_sheet(&p, &ep1, "# 1화\n\n바다.").unwrap();
    assert!(s.backup_due(), "text and no backup yet");
    let ep2 = s.create_sheet(&p, &serial, "# 2화\n\n안개.").unwrap().id;
    let gone = s.create_sheet(&p, &serial, "버린 글").unwrap().id;
    s.trash_sheet(&p, &gone).unwrap();
    let info = EpisodeInfo {
        number: Some(1),
        status: EpisodeStatus::Published,
        publish_at: Some(T0),
        platform: Some("문피아".into()),
        excluded: false,
    };
    s.set_episode(&p, &ep1, Some(info.clone())).unwrap();
    let deleted = s
        .create_project("지운 작품", Language::Ko, &["a".into()])
        .unwrap()
        .id;
    s.delete_project(&deleted).unwrap();

    let b = s.backup_now().unwrap();
    assert_eq!(b.kind, BackupKind::Auto);
    assert_eq!(b.projects, 2);
    let path = Path::new(&b.path);
    assert_eq!(path.parent().unwrap(), dir.path().join("Backups"));
    assert!(
        path.file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("auto-2026-10-24-00"),
        "{}",
        b.path
    );
    // Blocks and library.json only: no caches, no temp files.
    assert!(path.join("library.json").is_file());
    assert!(path.join("backup.json").is_file());
    assert!(!path.join("projects").join(&p).join("cache").exists());
    let listed = snapshot_tree(path);
    let total: u64 = listed
        .iter()
        .filter(|(f, _)| f != Path::new("backup.json"))
        .map(|(_, n)| n)
        .sum();
    assert_eq!(b.bytes, total);
    assert_eq!(s.backups(), vec![b.clone()]);
    assert!(!s.backup_due());
    clock.advance(25 * HOUR);
    assert!(!s.backup_due(), "nothing changed since the backup");
    // Change the library after the backup; the restore brings back the backup's state as new projects.
    s.save_sheet(&p, &ep1, "# 1화\n\n다 고쳤다.").unwrap();
    assert!(s.backup_due(), "changed, and the backup is over a day old");
    let before = s.projects().len();
    let copies = s.restore_backup_as_copies(&b.path).unwrap();
    assert_eq!(copies.len(), 1, "the deleted project is not restored");
    let c = &copies[0];
    assert_ne!(c.id, p);
    assert_eq!(c.title, "등대");
    assert_eq!(s.projects().len(), before + 1);
    assert_eq!(s.sheet_text(&p, &ep1).unwrap(), "# 1화\n\n다 고쳤다.");
    let co = s.outline(&c.id).unwrap();
    assert_eq!(
        co.folders
            .iter()
            .map(|f| f.name.as_str())
            .collect::<Vec<_>>(),
        ["연재", "설정"]
    );
    assert!(co.trash.is_empty());
    let sheets = &co.folders[0].sheets;
    assert_eq!(sheets.len(), 2);
    assert_ne!(sheets[0].id, ep1);
    assert_eq!(
        s.sheet_text(&c.id, &sheets[0].id).unwrap(),
        "# 1화\n\n바다."
    );
    assert_eq!(
        s.sheet_text(&c.id, &sheets[1].id).unwrap(),
        "# 2화\n\n안개."
    );
    assert_eq!(sheets[0].episode, Some(info));
    assert_eq!(sheets[1].episode, None);
    let orig = s.sheet_summary_of(&p, &ep2).unwrap();
    assert_eq!(sheets[1].created, orig.created);
    assert_eq!(sheets[1].modified, orig.modified);
    assert!(s.verify(&c.id).unwrap().ok);

    // The library itself and things that aren't backups are refused.
    let root = s.root().to_string_lossy().into_owned();
    assert!(matches!(
        s.restore_backup_as_copies(&root),
        Err(StoreError::InvalidInput(_))
    ));
    assert!(matches!(
        s.restore_backup_as_copies(&dir.path().to_string_lossy()),
        Err(StoreError::InvalidInput(_))
    ));
}

#[test]
fn retention_keeps_dailies_weeklies_manual_and_pre_migration() {
    let dir = tempfile::tempdir().unwrap();
    let (clock, mut s) = open(&lib(dir.path()));
    seed(&mut s);
    // A pre-migration backup made by an earlier open, and a manual one.
    let pre_dir = s.root().join("Backups/pre-migration-1-2-2026-10-01");
    let pre = pre_dir.join("projects/x");
    fs::create_dir_all(&pre).unwrap();
    fs::write(pre.join("f"), b"12345").unwrap();
    fs::write(
        pre_dir.join("backup.json"),
        r#"{"v":1,"kind":"pre-migration","at":1791000000000,"bytes":5,"format":1,"projects":1,"complete":true}"#,
    )
    .unwrap();
    // A pre-migration copy that never finished (no manifest) is not a backup.
    fs::create_dir_all(
        s.root()
            .join("Backups/pre-migration-1-2-2026-10-02/projects/y"),
    )
    .unwrap();
    let manual = s.backup_manual().unwrap();
    assert_eq!(manual.kind, BackupKind::Manual);
    // T0 is a Saturday. One automatic backup a day for 10 days: Sat … Mon.
    for _ in 0..10 {
        s.backup_now().unwrap();
        clock.advance(DAY);
    }
    let all = s.backups();
    let autos: Vec<_> = all.iter().filter(|b| b.kind == BackupKind::Auto).collect();
    // Daily: the last 7 days (day 9 … 3). Weekly: day 9, day 8 (week before) and day 1 (Sunday of
    // T0's week, newest of that week). Day 0 and day 2 are gone.
    assert_eq!(autos.len(), 8);
    let names: Vec<String> = autos
        .iter()
        .map(|b| {
            Path::new(&b.path)
                .file_name()
                .unwrap()
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    assert!(names.iter().any(|n| n.starts_with("auto-2026-10-25")));
    assert!(!names.iter().any(|n| n.starts_with("auto-2026-10-24")));
    assert!(!names.iter().any(|n| n.starts_with("auto-2026-10-26")));
    assert!(all.contains(&manual));
    let pm: Vec<_> = all
        .iter()
        .filter(|b| b.kind == BackupKind::PreMigration)
        .collect();
    assert_eq!(pm.len(), 1);
    assert_eq!((pm[0].bytes, pm[0].projects), (5, 1));
    // Newest first.
    assert!(autos.windows(2).all(|w| w[0].at > w[1].at));
    // Folders that aren't ours are never touched.
    fs::create_dir_all(dir.path().join("Backups/auto-not-ours")).unwrap();
    s.backup_now().unwrap();
    assert!(dir.path().join("Backups/auto-not-ours").exists());
}

#[test]
fn half_written_backup_is_never_listed_and_is_cleaned() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(&lib(dir.path()));
    seed(&mut s);
    let tmp = dir.path().join("Backups/.tmp-auto-2026-10-23-2359-1");
    fs::create_dir_all(tmp.join("projects")).unwrap();
    // A fresh one may be another library's backup in progress (the folder is shared): kept.
    let fresh = dir.path().join("Backups/.tmp-auto-2026-10-24-0000-2");
    fs::create_dir_all(fresh.join("projects")).unwrap();
    let old = std::time::SystemTime::now() - std::time::Duration::from_secs(2 * 3600);
    fs::File::open(&tmp).unwrap().set_modified(old).unwrap();
    // A finished-looking folder whose manifest says incomplete is not listed either.
    let partial = dir.path().join("Backups/auto-2026-10-23-2358");
    fs::create_dir_all(&partial).unwrap();
    fs::write(
        partial.join("backup.json"),
        r#"{"v":1,"kind":"auto","at":1,"bytes":0,"format":1,"projects":0,"complete":false}"#,
    )
    .unwrap();
    assert!(s.backups().is_empty());
    s.backup_now().unwrap();
    assert!(!tmp.exists());
    assert!(fresh.exists());
    assert_eq!(s.backups().len(), 1);
}

#[test]
fn v1_fixture_backs_up_and_restores() {
    let dir = tempfile::tempdir().unwrap();
    copy_dir(&fixtures().join("library-v1"), &lib(dir.path()), &|_| false).unwrap();
    let (tc, clock) = TestClock::new(1_790_100_000_000);
    let mut s = Store::open_with(lib(dir.path()), "mac-test", opts(clock)).unwrap();
    drop(tc);
    let b = s.backup_now().unwrap();
    let copies = s.restore_backup_as_copies(&b.path).unwrap();
    assert_eq!(
        copies.iter().map(|p| p.title.as_str()).collect::<Vec<_>>(),
        ["등대지기의 딸", "The Salt Road"]
    );
    let o = s.outline(&copies[0].id).unwrap();
    assert_eq!(o.folders[0].sheets.len(), 2);
    assert_eq!(o.folders[0].sheets[0].title, "1화 · 섬");
}
