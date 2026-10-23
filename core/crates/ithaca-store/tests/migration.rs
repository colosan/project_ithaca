//! Format versions and migrations (ADR-0008 §5) against the frozen v1 fixture in core/fixtures/library-v1.

mod common;

use std::fs;
use std::path::{Path, PathBuf};

use common::*;
use ithaca_model::{ExportOptions, Language};
use ithaca_store::format::LibraryFile;
use ithaca_store::fsutil::copy_dir;
use ithaca_store::{Migration, OpenOptions, ProjectPatch, Store, StoreError};

/// A day after the fixture was written, so its trash is not yet due for purging.
const FIXTURE_NOW: i64 = 1_790_100_000_000;

fn open_fixture(root: &Path) -> (TestClock, Store) {
    let (tc, clock) = TestClock::new(FIXTURE_NOW);
    (tc, Store::open_with(root, "mac-test", opts(clock)).unwrap())
}

fn fixture_copy() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    copy_dir(&fixtures().join("library-v1"), dir.path(), &|_| false).unwrap();
    dir
}

/// Regenerates the frozen fixture. Run only when FORMAT.md v1 itself changes (it never should):
/// `cargo test -p ithaca-store --test migration -- --ignored write_v1_fixture`
#[test]
#[ignore]
fn write_v1_fixture() {
    let out = fixtures().join("library-v1");
    let _ = fs::remove_dir_all(&out);
    let (_c, mut s) = {
        let (tc, clock) = TestClock::new(1_790_000_000_000);
        (
            tc,
            Store::open_with(&out, "fixture-mac", opts(clock)).unwrap(),
        )
    };
    let p = s
        .create_project(
            "등대지기의 딸",
            Language::Ko,
            &["연재".into(), "설정".into()],
        )
        .unwrap()
        .id;
    let o = s.outline(&p).unwrap();
    let (serial, lore) = (o.folders[0].id.clone(), o.folders[1].id.clone());
    let ep1 = o.folders[0].sheets[0].id.clone();
    for t in [
        "# 1화 · 섬",
        "# 1화 · 섬\n\n그 섬에는 등대가 하나 있었다.",
        "# 1화 · 섬\n\n그 섬에는 등대가 하나 있었다.\n\n* * *\n\n바람이 불었다. 👨‍👩‍👧",
    ] {
        s.save_sheet(&p, &ep1, t).unwrap();
    }
    let ep2 = s
        .create_sheet(&p, &serial, "# 2화 · 안개\n\n안개가 **섬을** 삼켰다.")
        .unwrap()
        .id;
    let gone = s.create_sheet(&p, &serial, "# 버린 3화").unwrap().id;
    s.trash_sheet(&p, &gone).unwrap();
    s.create_sheet(&p, &lore, "# 인물\n\n- 서연: 열일곱 살")
        .unwrap();
    s.save_sheet(
        &p,
        &ep2,
        "# 2화 · 안개\n\n안개가 **섬을** 삼켰다.\n불빛이 깜빡였다.",
    )
    .unwrap();
    let en = s
        .create_project("The Salt Road", Language::En, &["Chapters".into()])
        .unwrap()
        .id;
    let ch1 = s.outline(&en).unwrap().folders[0].sheets[0].id.clone();
    s.save_sheet(&en, &ch1, "# Chapter One\n\nThe road ran white with salt.")
        .unwrap();
    drop(s);
    // Caches are derived: the fixture holds only what FORMAT.md defines. Plus one crashed write.
    for p in [&p, &en] {
        fs::remove_dir_all(out.join("projects").join(p).join("cache")).unwrap();
    }
    fs::write(
        out.join("projects")
            .join(&p)
            .join("changes")
            .join(".tmp-crashed-write-1-0"),
        b"{\"v\":1,\"hash\":\"9f",
    )
    .unwrap();
}

fn check_v1_content(s: &Store) {
    let ps = s.projects();
    assert_eq!(
        ps.iter().map(|p| p.title.as_str()).collect::<Vec<_>>(),
        ["등대지기의 딸", "The Salt Road"]
    );
    let o = s.outline(&ps[0].id).unwrap();
    let titles: Vec<Vec<&str>> = o
        .folders
        .iter()
        .map(|f| f.sheets.iter().map(|x| x.title.as_str()).collect())
        .collect();
    assert_eq!(titles, [vec!["1화 · 섬", "2화 · 안개"], vec!["인물"]]);
    assert_eq!(o.trash.len(), 1);
    let ep1 = &o.folders[0].sheets[0];
    assert_eq!(s.history(&ps[0].id, &ep1.id).unwrap().len(), 4);
    assert_eq!(ep1.counts.paragraphs, 2);
    let text = s
        .export_text(&ps[0].id, &[], &ExportOptions::default())
        .unwrap();
    assert!(text.starts_with("1화 · 섬\n\n그 섬에는 등대가 하나 있었다.\n\n* * *\n\n바람이 불었다. 👨‍👩‍👧\n\n\n2화 · 안개\n\n안개가 섬을 삼켰다."));
    for p in &ps {
        assert!(s.verify(&p.id).unwrap().ok);
    }
}

#[test]
fn v1_fixture_opens_with_this_core() {
    let dir = fixture_copy();
    let (_c, s) = open_fixture(dir.path());
    assert_eq!(s.info().format, 1);
    assert!(!s.info().read_only);
    assert_eq!(s.info().migrated_from, None);
    check_v1_content(&s);
    // The crashed write was ignored and cleaned up.
    let ch = dir
        .path()
        .join("projects")
        .join(&s.projects()[0].id)
        .join("changes");
    assert!(!ch.join(".tmp-crashed-write-1-0").exists());
}

/// A stand-in v1 → v2 step: adds a field to library.json and a marker file.
fn dummy_v2(root: &Path) -> Result<(), StoreError> {
    let mut f = LibraryFile::read(root)?.unwrap();
    f.extra.insert(
        "v2-note".into(),
        serde_json::json!("added by the test migration"),
    );
    f.write(root)?;
    fs::write(root.join("MIGRATED-TO-2"), "ok")?;
    Ok(())
}

fn v2_options() -> OpenOptions {
    let (_tc, clock) = TestClock::new(FIXTURE_NOW);
    OpenOptions {
        supported_format: 2,
        migrations: vec![Migration {
            from: 1,
            run: dummy_v2,
        }],
        clock,
    }
}

#[test]
fn migration_backs_up_then_migrates() {
    let dir = fixture_copy();
    let before = snapshot_tree(dir.path());
    let s = Store::open_with(dir.path(), "mac-test", v2_options()).unwrap();
    let info = s.info();
    assert_eq!(
        (info.format, info.read_only, info.migrated_from),
        (2, false, Some(1))
    );
    let backup = Path::new(info.backup_path.as_deref().unwrap()).to_path_buf();
    assert_eq!(
        backup,
        dir.path().join("Backups").join(format!(
            "pre-migration-1-2-{}",
            ithaca_store::fsutil::utc_date(FIXTURE_NOW)
        ))
    );
    // The backup is the library exactly as it was, plus its manifest.
    let copied: Vec<_> = snapshot_tree(&backup)
        .into_iter()
        .filter(|(p, _)| p != Path::new("backup.json"))
        .collect();
    assert_eq!(copied, before);
    assert!(
        s.backups()
            .iter()
            .any(|b| b.kind == ithaca_store::BackupKind::PreMigration
                && Path::new(&b.path) == backup)
    );
    assert_eq!(LibraryFile::read(&backup).unwrap().unwrap().format, 1);
    // The migration ran and the format moved on, keeping the step's own changes.
    let lf = LibraryFile::read(dir.path()).unwrap().unwrap();
    assert_eq!(lf.format, 2);
    assert!(lf.extra.contains_key("v2-note"));
    assert!(dir.path().join("MIGRATED-TO-2").exists());
    check_v1_content(&s);
    drop(s);

    // Opening again does not migrate again.
    let s = Store::open_with(dir.path(), "mac-test", v2_options()).unwrap();
    assert_eq!(s.info().migrated_from, None);
    drop(s);

    // And now this (format 1) core finds a newer library: read-only.
    newer_library_is_read_only_at(dir.path(), 2);
}

#[test]
fn missing_migration_path_changes_nothing() {
    let dir = fixture_copy();
    let before = snapshot_tree(dir.path());
    let (_tc, clock) = TestClock::new(T0);
    let o = OpenOptions {
        supported_format: 3,
        migrations: vec![Migration {
            from: 1,
            run: dummy_v2,
        }],
        clock,
    };
    assert!(matches!(
        Store::open_with(dir.path(), "mac-test", o),
        Err(StoreError::Corrupt(_))
    ));
    // Only the (empty) lock file was created.
    assert_eq!(without_lock(snapshot_tree(dir.path())), before);
}

fn without_lock(tree: Vec<(PathBuf, u64)>) -> Vec<(PathBuf, u64)> {
    tree.into_iter()
        .filter(|(p, _)| p != Path::new(".lock"))
        .collect()
}

#[test]
fn newer_format_opens_read_only() {
    let dir = fixture_copy();
    let mut f = LibraryFile::read(dir.path()).unwrap().unwrap();
    f.format = 99;
    f.write(dir.path()).unwrap();
    newer_library_is_read_only_at(dir.path(), 99);
}

fn newer_library_is_read_only_at(root: &Path, format: u32) {
    let before = snapshot_tree(root);
    let (_c, mut s) = open_fixture(root);
    let info = s.info();
    assert_eq!((info.format, info.read_only), (format, true));
    // Reading works.
    let p = s.projects()[0].id.clone();
    let o = s.outline(&p).unwrap();
    let (f, sheet) = (o.folders[0].id.clone(), o.folders[0].sheets[0].id.clone());
    assert!(s.sheet_text(&p, &sheet).unwrap().starts_with("# 1화"));
    assert!(!s.search("등대", None).is_empty());
    // Every write is refused.
    let ro = Err::<(), _>(StoreError::ReadOnly);
    assert_eq!(s.save_sheet(&p, &sheet, "x").map(|_| ()), ro);
    assert_eq!(
        s.create_project("x", Language::Ko, &["a".into()])
            .map(|_| ()),
        ro
    );
    assert_eq!(
        s.update_project(&p, ProjectPatch::default()).map(|_| ()),
        ro
    );
    assert_eq!(s.delete_project(&p), ro);
    assert_eq!(s.restore_project(&p), ro);
    assert_eq!(s.create_folder(&p, "x").map(|_| ()), ro);
    assert_eq!(s.rename_folder(&p, &f, "x"), ro);
    assert_eq!(s.delete_folder(&p, &f), ro);
    assert_eq!(s.restore_folder(&p, &f), ro);
    assert_eq!(s.create_sheet(&p, &f, "x").map(|_| ()), ro);
    assert_eq!(s.move_sheet(&p, &sheet, &f, None), ro);
    assert_eq!(s.trash_sheet(&p, &sheet), ro);
    assert_eq!(s.restore_sheet(&p, &sheet), ro);
    assert_eq!(s.delete_sheet_forever(&p, &sheet), ro);
    assert_eq!(s.empty_trash(&p), ro);
    let h = s.history(&p, &sheet).unwrap()[1].hash.clone();
    assert_eq!(s.restore_version(&p, &sheet, &h).map(|_| ()), ro);
    assert_eq!(s.import_web_backup("{}").map(|_| ()), ro);
    assert_eq!(s.purge_expired(), ro);
    drop(s);
    assert_eq!(
        snapshot_tree(root),
        before,
        "a read-only open writes nothing"
    );
}

#[test]
fn missing_library_file_with_projects_opens_read_only() {
    let dir = fixture_copy();
    fs::remove_file(dir.path().join("library.json")).unwrap();
    let before = snapshot_tree(dir.path());
    let mut s = Store::open(dir.path(), "mac-test").unwrap();
    let info = s.info();
    assert!(info.read_only && !info.locked_by_other);
    assert!(
        info.problems[0].contains("library.json is missing"),
        "{info:?}"
    );
    // The projects are still readable, nothing is initialised over them, nothing is written.
    check_v1_content(&s);
    assert!(matches!(
        s.create_project("x", ithaca_model::Language::Ko, &["F".into()]),
        Err(StoreError::ReadOnly)
    ));
    drop(s);
    assert_eq!(snapshot_tree(dir.path()), before);
    assert!(!dir.path().join("library.json").exists());
}
