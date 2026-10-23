//! Mac QA round 1: damaged sheets, project order, search fairness, backup timing and names.

mod common;

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use common::*;
use ithaca_model::Language;
use ithaca_store::{Store, StoreError};

fn lib(dir: &Path) -> PathBuf {
    dir.join("Library")
}

/// A project with one sheet, written as `versions` in turn (one block each). Returns (project, sheet).
fn sheet_with(s: &mut Store, versions: &[&str]) -> (String, String) {
    let p = s
        .create_project("등대", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let sheet = s.outline(&p).unwrap().folders[0].sheets[0].id.clone();
    for v in versions {
        s.save_sheet(&p, &sheet, v).unwrap();
    }
    (p, sheet)
}

/// The block that produced `version`, counting from the oldest (0 = the empty first block).
fn block_of(s: &Store, p: &str, sheet: &str, version: usize) -> String {
    let mut h = s.history(p, sheet).unwrap();
    h.reverse();
    h[version].hash.clone()
}

/// Flips one byte inside the block's body, as a failing disk would.
fn flip(s: &Store, p: &str, hash: &str) {
    let path = changes(s, p).join(hash);
    let mut bytes = fs::read(&path).unwrap();
    let at = bytes.windows(7).position(|w| w == b"\"body\":").unwrap() + 12;
    bytes[at] ^= 0x01;
    fs::write(&path, bytes).unwrap();
}

/// Drops the store, deletes every cache, opens again.
fn reopen(s: Store) -> Store {
    let root = s.root().to_path_buf();
    drop(s);
    for p in fs::read_dir(root.join("projects")).unwrap() {
        let _ = fs::remove_dir_all(p.unwrap().path().join("cache"));
    }
    open(&root).1
}

const V: [&str; 4] = [
    "# 1화\n\n첫 문장.",
    "# 1화\n\n첫 문장. 둘째 문장.",
    "# 1화\n\n첫 문장. 둘째 문장. 셋째 문장.",
    "# 1화\n\n첫 문장. 둘째 문장. 셋째 문장. 넷째.",
];

#[test]
fn damaged_block_is_flagged_not_emptied_and_recovers_exactly() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(&lib(dir.path()));
    let (p, sheet) = sheet_with(&mut s, &V);
    s.backup_now().unwrap();
    // Version 3 (block index 3) is damaged; version 4 builds on it, so the last good text is version 2.
    let bad = block_of(&s, &p, &sheet, 3);
    flip(&s, &p, &bad);
    let mut s = reopen(s);

    let sum = s.sheet_summary_of(&p, &sheet).unwrap();
    assert!(sum.damaged);
    assert_eq!(s.sheet_text(&p, &sheet).unwrap(), V[1]);
    assert_eq!(sum.title, "1화");
    assert!(
        s.info().problems.iter().any(|m| m.contains("damaged")),
        "{:?}",
        s.info().problems
    );
    assert_eq!(s.damaged_sheets(&p).unwrap(), vec![sum.clone()]);
    assert!(matches!(
        s.save_sheet(&p, &sheet, "덮어쓰기"),
        Err(StoreError::Corrupt(_))
    ));
    assert_eq!(
        s.sheet_text(&p, &sheet).unwrap(),
        V[1],
        "nothing written on top"
    );
    // Other writes to the project still work.
    s.create_sheet(&p, &sum.folder, "다른 글").unwrap();

    // The backup has the exact block: it goes back, the whole history with it.
    let r = s.recover_sheet_from_backup(&p, &sheet).unwrap();
    assert!(!r.damaged);
    assert_eq!(s.sheet_text(&p, &sheet).unwrap(), V[3]);
    assert!(s.verify(&p).unwrap().ok);
    let kept = s
        .root()
        .join("projects")
        .join(&p)
        .join("damaged")
        .join(&bad);
    assert!(kept.is_file(), "the broken file is kept aside");
    s.save_sheet(&p, &sheet, "고친 뒤").unwrap();
    // And it stays fixed.
    let s = reopen(s);
    assert!(!s.sheet_summary_of(&p, &sheet).unwrap().damaged);
    assert_eq!(s.sheet_text(&p, &sheet).unwrap(), "고친 뒤");
    assert!(s.info().problems.is_empty(), "{:?}", s.info().problems);
}

#[test]
fn damage_after_the_backup_restores_the_backup_text_as_a_new_block() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(&lib(dir.path()));
    let (p, sheet) = sheet_with(&mut s, &V[..2]);
    s.backup_now().unwrap();
    s.save_sheet(&p, &sheet, V[2]).unwrap();
    s.save_sheet(&p, &sheet, V[3]).unwrap();
    let blocks_before = s.history(&p, &sheet).unwrap().len();
    flip(&s, &p, &block_of(&s, &p, &sheet, 4)); // the newest block, not in the backup
    let mut s = reopen(s);
    assert!(s.sheet_summary_of(&p, &sheet).unwrap().damaged);
    assert_eq!(s.sheet_text(&p, &sheet).unwrap(), V[2]);

    let r = s.recover_sheet_from_backup(&p, &sheet).unwrap();
    assert!(!r.damaged);
    assert_eq!(
        s.sheet_text(&p, &sheet).unwrap(),
        V[1],
        "the backup's version"
    );
    let h = s.history(&p, &sheet).unwrap();
    // The broken block moved aside; one new block with the backup's text.
    assert_eq!(h.len(), blocks_before - 1 + 1);
    let texts: Vec<String> = h
        .iter()
        .map(|e| s.text_at(&p, &sheet, &e.hash).unwrap())
        .collect();
    assert!(
        texts.contains(&V[2].to_string()),
        "the last good text stays in history"
    );
    assert!(s.verify(&p).unwrap().ok);
}

#[test]
fn a_sheet_with_no_readable_block_is_damaged_not_empty() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(&lib(dir.path()));
    let p = s
        .create_project("등대", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let folder = s.outline(&p).unwrap().folders[0].id.clone();
    let sheet = s.create_sheet(&p, &folder, V[0]).unwrap().id;
    let only = block_of(&s, &p, &sheet, 0);
    flip(&s, &p, &only);
    let mut s = reopen(s);
    let sum = s.sheet_summary_of(&p, &sheet).unwrap();
    assert!(sum.damaged);
    assert!(matches!(
        s.save_sheet(&p, &sheet, "x"),
        Err(StoreError::Corrupt(_))
    ));
    // No backup holds it.
    assert!(matches!(
        s.recover_sheet_from_backup(&p, &sheet),
        Err(StoreError::NotFound)
    ));
    // The writer can still choose to go on with what's left (here: nothing).
    let r = s.keep_last_good_text(&p, &sheet).unwrap();
    assert!(!r.damaged);
    s.save_sheet(&p, &sheet, "다시 쓴다").unwrap();
    assert!(matches!(
        s.keep_last_good_text(&p, &sheet),
        Err(StoreError::InvalidInput(_))
    ));
    let s = reopen(s);
    assert_eq!(s.sheet_text(&p, &sheet).unwrap(), "다시 쓴다");
    assert!(
        s.root()
            .join("projects")
            .join(&p)
            .join("damaged")
            .join(&only)
            .is_file()
    );
}

#[test]
fn projects_are_listed_in_the_order_they_came_into_the_library() {
    let dir = tempfile::tempdir().unwrap();
    let (clock, mut s) = open(&lib(dir.path()));
    let (a, _) = sheet_with(&mut s, &["가"]);
    let b = s.backup_now().unwrap();
    clock.advance(3_600_000);
    let c = s
        .create_project("나중", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let copies = s
        .restore_backup_as_copies_with_suffix(&b.path, " (백업)")
        .unwrap();
    assert_eq!(copies[0].title, "등대 (백업)");
    let order: Vec<String> = s.projects().into_iter().map(|p| p.id).collect();
    assert_eq!(order, [a, c, copies[0].id.clone()]);
    // The copy keeps its original creation time all the same.
    assert!(copies[0].created < s.project_summary_of(&order[1]).unwrap().created);
}

#[test]
fn search_is_fair_across_projects() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(&lib(dir.path()));
    let (big, _) = sheet_with(&mut s, &[&"바다 ".repeat(300)]);
    let (small, _) = sheet_with(&mut s, &[&"바다 ".repeat(10)]);
    let all = s.search_all("바다", None);
    assert_eq!(all.len(), 210);
    assert!(all[..200].iter().all(|h| h.project == big));
    let mine = s.search_all("바다", Some(&small));
    assert_eq!(mine.len(), 210);
    assert!(mine[..10].iter().all(|h| h.project == small));
    assert_eq!(s.search("바다", None), all);
    assert_eq!(s.search("바다", Some(&big)).len(), 300);
}

#[test]
fn backups_are_due_only_after_changes_and_named_in_local_time() {
    let dir = tempfile::tempdir().unwrap();
    let (tc, clock) = TestClock::new(T0);
    let o = ithaca_store::OpenOptions {
        local_offset: Arc::new(|_| 9 * 3_600_000), // KST
        ..opts(clock)
    };
    let mut s = Store::open_with(lib(dir.path()), "mac-test", o).unwrap();
    // An empty project is not worth a backup.
    let p = s
        .create_project("빈 작품", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    assert!(!s.backup_due());
    // An automatic backup an older core made of the empty library (no `textSheets`).
    let m = s.backup_manual().unwrap();
    let old_auto = dir.path().join("Backups/auto-2026-10-24-0900");
    fs::rename(&m.path, &old_auto).unwrap();
    let manifest = fs::read_to_string(old_auto.join("backup.json")).unwrap();
    let manifest = manifest
        .replace("\"manual\"", "\"auto\"")
        .replace(",\n  \"textSheets\": 0", "");
    assert!(!manifest.contains("textSheets"), "{manifest}");
    fs::write(old_auto.join("backup.json"), manifest).unwrap();
    // Text arrives (e.g. an import) within the day: the empty backup doesn't count.
    let sheet = s.outline(&p).unwrap().folders[0].sheets[0].id.clone();
    s.save_sheet(&p, &sheet, "글").unwrap();
    assert!(s.backup_due());
    let b = s.backup_now().unwrap();
    let name = Path::new(&b.path)
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    assert!(name.starts_with("auto-2026-10-24-09"), "{name}");
    assert!(!s.backup_due());
    // A day later, unchanged: not due. Changed: due.
    tc.advance(25 * 3_600_000);
    assert!(!s.backup_due());
    s.save_sheet(&p, &sheet, "글 더").unwrap();
    assert!(s.backup_due());
    // Listing order comes from the manifest's UTC time, newest first.
    let b2 = s.backup_now().unwrap();
    assert_eq!(s.backups()[0], b2);
}
