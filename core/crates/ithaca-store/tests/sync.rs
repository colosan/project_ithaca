//! Two libraries kept in step through a shared file store (added: sync, ADR-0013).
mod common;

use std::collections::BTreeMap;

use common::*;
use ithaca_model::Language;
use ithaca_store::{Store, SyncFile};

/// The shared store: path → bytes, like a repository's files.
#[derive(Default)]
struct Remote(BTreeMap<String, Vec<u8>>);

/// One device's side of a sync, the way the app does it: list, plan, fetch, send, prune.
/// Returns the new base (the listing after this sync).
fn sync(s: &mut Store, remote: &mut Remote, base: &[String]) -> Vec<String> {
    let listing: Vec<String> = remote.0.keys().cloned().collect();
    let plan = s.sync_plan(&listing, base);
    let files = plan
        .download
        .iter()
        .map(|p| SyncFile {
            path: p.clone(),
            bytes: remote.0[p].clone(),
        })
        .collect();
    let r = s.sync_ingest(files).unwrap();
    assert!(r.skipped.is_empty(), "{:?}", r.skipped);
    // Ingesting may have written merge blocks: send everything still missing.
    let plan2 = s.sync_plan(&remote.0.keys().cloned().collect::<Vec<_>>(), base);
    for p in plan.upload.iter().chain(&plan2.upload) {
        remote.0.insert(p.clone(), s.sync_read(p).unwrap());
    }
    for p in &plan.delete_remote {
        remote.0.remove(p);
    }
    remote.0.keys().cloned().collect()
}

fn device(path: &std::path::Path, name: &str) -> Store {
    let (_tc, clock) = TestClock::new(T0);
    Store::open_with(path, name, opts(clock)).unwrap()
}

#[test]
fn a_project_travels_and_edits_come_back() {
    let (a_dir, b_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let mut a = device(a_dir.path(), "mac");
    let mut b = device(b_dir.path(), "phone");
    let mut remote = Remote::default();
    let p = a
        .create_project("등대", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let o = a.outline(&p).unwrap();
    let sheet = o.folders[0].sheets[0].id.clone();
    a.save_sheet(&p, &sheet, "# 1화\n\n첫 문장.").unwrap();

    let base_a = sync(&mut a, &mut remote, &[]);
    assert!(!remote.0.is_empty());
    let base_b = sync(&mut b, &mut remote, &[]);
    assert_eq!(b.sheet_text(&p, &sheet).unwrap(), "# 1화\n\n첫 문장.");
    assert_eq!(b.projects().len(), 1);

    b.save_sheet(&p, &sheet, "# 1화\n\n첫 문장. 폰에서 이어 씀.")
        .unwrap();
    let _ = sync(&mut b, &mut remote, &base_b);
    let listing: Vec<String> = remote.0.keys().cloned().collect();
    let plan = a.sync_plan(&listing, &base_a);
    assert_eq!(plan.download.len(), 1);
    let _ = sync(&mut a, &mut remote, &base_a);
    assert_eq!(
        a.sheet_text(&p, &sheet).unwrap(),
        "# 1화\n\n첫 문장. 폰에서 이어 씀."
    );
    assert!(!a.outline(&p).unwrap().folders[0].sheets[0].branched);

    // Reopening reads the same library from disk.
    drop(a);
    let a = device(a_dir.path(), "mac");
    assert_eq!(
        a.sheet_text(&p, &sheet).unwrap(),
        "# 1화\n\n첫 문장. 폰에서 이어 씀."
    );
}

#[test]
fn sheets_made_apart_are_both_kept_and_the_merge_is_the_same_on_both_devices() {
    let (a_dir, b_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let mut a = device(a_dir.path(), "mac");
    let mut b = device(b_dir.path(), "phone");
    let mut remote = Remote::default();
    let p = a
        .create_project("등대", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let folder = a.outline(&p).unwrap().folders[0].id.clone();
    let base_a = sync(&mut a, &mut remote, &[]);
    let base_b = sync(&mut b, &mut remote, &[]);

    // Both add a sheet while apart: the tables of contents fork.
    let on_a = a.create_sheet(&p, &folder, "# 맥에서").unwrap().id;
    let on_b = b.create_sheet(&p, &folder, "# 폰에서").unwrap().id;
    let base_a = sync(&mut a, &mut remote, &base_a);
    let base_b = sync(&mut b, &mut remote, &base_b);
    let _ = sync(&mut a, &mut remote, &base_a);
    let _ = sync(&mut b, &mut remote, &base_b);

    for s in [&a, &b] {
        let o = s.outline(&p).unwrap();
        let ids: Vec<&str> = o.folders[0].sheets.iter().map(|x| x.id.as_str()).collect();
        assert!(
            ids.contains(&on_a.as_str()) && ids.contains(&on_b.as_str()),
            "{ids:?}"
        );
        assert_eq!(s.sheet_text(&p, &on_b).unwrap(), "# 폰에서");
    }
    assert_eq!(a.outline(&p).unwrap(), b.outline(&p).unwrap());
    // One merge block, written by whichever device came first and simply received by the other.
    assert_eq!(a.sync_files(), b.sync_files());
    let listing: Vec<String> = remote.0.keys().cloned().collect();
    let plan = a.sync_plan(&listing, &listing);
    assert!(plan.upload.is_empty() && plan.download.is_empty() && plan.delete_remote.is_empty());
}

#[test]
fn a_sheet_deleted_for_good_is_not_brought_back() {
    let (a_dir, b_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let mut a = device(a_dir.path(), "mac");
    let mut b = device(b_dir.path(), "phone");
    let mut remote = Remote::default();
    let p = a
        .create_project("등대", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let folder = a.outline(&p).unwrap().folders[0].id.clone();
    let gone = a.create_sheet(&p, &folder, "# 지울 것").unwrap().id;
    let base_a = sync(&mut a, &mut remote, &[]);
    let base_b = sync(&mut b, &mut remote, &[]);

    a.trash_sheet(&p, &gone).unwrap();
    a.delete_sheet_forever(&p, &gone).unwrap();
    let base_a = sync(&mut a, &mut remote, &base_a);
    assert!(
        !remote.0.keys().any(|k| k.contains(&gone)),
        "the store is pruned"
    );
    let base_b = sync(&mut b, &mut remote, &base_b);
    assert!(
        b.outline(&p).unwrap().folders[0]
            .sheets
            .iter()
            .all(|s| s.id != gone)
    );
    assert!(
        !b.sync_files().iter().any(|k| k.contains(&gone)),
        "the other device drops its files too"
    );
    // Nothing comes back on either side.
    let _ = sync(&mut a, &mut remote, &base_a);
    let _ = sync(&mut b, &mut remote, &base_b);
    assert!(!remote.0.keys().any(|k| k.contains(&gone)));
}

#[test]
fn bad_files_are_skipped() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = device(dir.path(), "mac");
    let p = a
        .create_project("등대", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let real = a.sync_files()[0].clone();
    let bytes = a.sync_read(&real).unwrap();
    let wrong = real.replace(&real[real.len() - 4..], "0000");
    let r = a
        .sync_ingest(vec![
            SyncFile {
                path: "README.md".into(),
                bytes: b"hi".to_vec(),
            },
            SyncFile {
                path: wrong,
                bytes: bytes.clone(),
            },
            SyncFile {
                path: format!("projects/{p}/toc/{}", "a".repeat(64)),
                bytes: b"{}".to_vec(),
            },
        ])
        .unwrap();
    assert_eq!(r.added, 0);
    assert_eq!(r.skipped.len(), 3);
    let plan = a.sync_plan(&["README.md".into()], &[]);
    assert!(plan.download.is_empty() && plan.delete_remote.is_empty());
}
