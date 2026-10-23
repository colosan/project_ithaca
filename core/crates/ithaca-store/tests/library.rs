mod common;

use std::fs;

use common::*;
use ithaca_ledger::{Actor, Block, Body, Kind, delta};
use ithaca_model::{ExportOptions, Goal, GoalBasis, Language};
use ithaca_store::{IssueKind, ProjectPatch, SNAPSHOT_EVERY, Store, StoreError};

fn new_project(s: &mut Store) -> (String, String, String) {
    let p = s
        .create_project("등대", Language::Ko, &["연재".into(), "설정".into()])
        .unwrap();
    let o = s.outline(&p.id).unwrap();
    (
        p.id,
        o.folders[0].id.clone(),
        o.folders[0].sheets[0].id.clone(),
    )
}

#[test]
fn create_save_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, _f, sheet) = new_project(&mut s);
    s.save_sheet(&p, &sheet, "# 1화\n\n첫 문장.").unwrap();
    let sum = s
        .save_sheet(&p, &sheet, "# 1화\n\n첫 문장. 둘째 문장.")
        .unwrap();
    assert_eq!(sum.title, "1화");
    assert_eq!(sum.counts.paragraphs, 1);
    let hist_len = s.history(&p, &sheet).unwrap().len();
    // Unchanged text writes nothing.
    s.save_sheet(&p, &sheet, "# 1화\n\n첫 문장. 둘째 문장.")
        .unwrap();
    assert_eq!(s.history(&p, &sheet).unwrap().len(), hist_len);
    assert_eq!(hist_len, 3); // empty seed + two saves
    drop(s);

    let (_c, s) = open(dir.path());
    assert_eq!(
        s.sheet_text(&p, &sheet).unwrap(),
        "# 1화\n\n첫 문장. 둘째 문장."
    );
    assert_eq!(s.projects().len(), 1);
    let o = s.outline(&p).unwrap();
    assert_eq!(
        o.folders
            .iter()
            .map(|f| f.name.as_str())
            .collect::<Vec<_>>(),
        ["연재", "설정"]
    );
}

#[test]
fn caches_are_rebuildable() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, f, sheet) = new_project(&mut s);
    for i in 0..10 {
        s.save_sheet(&p, &sheet, &format!("본문 {i}")).unwrap();
    }
    let other = s.create_sheet(&p, &f, "둘째").unwrap().id;
    let before = s.outline(&p).unwrap();
    let hist = s.history(&p, &sheet).unwrap();
    drop(s);
    fs::remove_dir_all(dir.path().join("projects").join(&p).join("cache")).unwrap();
    let (_c, s) = open(dir.path());
    assert_eq!(s.outline(&p).unwrap(), before);
    assert_eq!(s.history(&p, &sheet).unwrap(), hist);
    assert_eq!(s.sheet_text(&p, &other).unwrap(), "둘째");
}

#[test]
fn stale_cache_picks_up_newer_blocks() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, _f, sheet) = new_project(&mut s);
    s.save_sheet(&p, &sheet, "하나").unwrap();
    let cache = dir
        .path()
        .join("projects")
        .join(&p)
        .join("cache")
        .join(format!("{sheet}.json"));
    let old = fs::read(&cache).unwrap();
    s.save_sheet(&p, &sheet, "하나 둘").unwrap();
    drop(s);
    // As if the app died after writing the block but before the cache.
    fs::write(&cache, old).unwrap();
    let (_c, s) = open(dir.path());
    assert_eq!(s.sheet_text(&p, &sheet).unwrap(), "하나 둘");
}

#[test]
fn half_written_block_is_ignored() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, _f, sheet) = new_project(&mut s);
    s.save_sheet(&p, &sheet, "끝까지 쓴 글").unwrap();
    let ch = changes(&s, &p);
    drop(s);
    let tmp = ch.join(".tmp-0123abcd-77-0");
    fs::write(&tmp, b"{\"v\":1,\"hash\":\"ab").unwrap();
    let (_c, s) = open(dir.path());
    assert_eq!(s.sheet_text(&p, &sheet).unwrap(), "끝까지 쓴 글");
    assert!(!tmp.exists(), "temp files are cleaned up when writable");
    assert!(s.verify(&p).unwrap().ok);
}

#[test]
fn snapshots_bound_the_delta_chain() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, _f, sheet) = new_project(&mut s);
    let mut text = String::from("# 7화\n\n");
    let mut versions = vec![];
    for i in 0..200 {
        text.push_str(&format!("{i}번째 문장이다. "));
        if i % 50 == 49 {
            text.push('\n');
        }
        s.save_sheet(&p, &sheet, &text).unwrap();
        versions.push(text.clone());
    }
    let hist = s.history(&p, &sheet).unwrap();
    assert_eq!(hist.len(), 201);
    // Every version reads back exactly.
    for (h, want) in hist.iter().take(200).zip(versions.iter().rev()) {
        assert_eq!(&s.text_at(&p, &sheet, &h.hash).unwrap(), want);
    }
    // Deltas, mostly; a snapshot at least every SNAPSHOT_EVERY blocks.
    let mut snaps = 0;
    for h in &hist {
        let b = Block::parse(&fs::read(changes(&s, &p).join(&h.hash)).unwrap()).unwrap();
        if matches!(b.body, Body::Snapshot(_)) {
            snaps += 1;
        }
    }
    assert!(
        snaps >= 201 / SNAPSHOT_EVERY as usize && snaps <= 201 / SNAPSHOT_EVERY as usize + 2,
        "{snaps} snapshots"
    );
    assert_eq!(hist[0].added, "199번째 문장이다. \n".chars().count() as u32);
}

#[test]
fn verify_reports_tampering() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, _f, sheet) = new_project(&mut s);
    for t in ["하나", "하나 둘", "하나 둘 셋"] {
        s.save_sheet(&p, &sheet, t).unwrap();
    }
    let ok = s.verify(&p).unwrap();
    assert!(ok.ok && ok.issues.is_empty());
    assert_eq!(ok.chains, 2);
    let hist = s.history(&p, &sheet).unwrap();
    let middle = &hist[1].hash; // "하나 둘"
    let path = changes(&s, &p).join(middle);
    let tampered = String::from_utf8(fs::read(&path).unwrap())
        .unwrap()
        .replace("\"at\":", "\"at\":1");
    fs::write(&path, tampered).unwrap();
    fs::write(changes(&s, &p).join("notes.txt"), "hi").unwrap();
    let r = s.verify(&p).unwrap();
    assert!(!r.ok);
    assert!(
        r.issues
            .iter()
            .any(|i| i.kind == IssueKind::HashMismatch && &i.file == middle)
    );
    assert!(
        r.issues
            .iter()
            .any(|i| i.kind == IssueKind::MissingParent && i.file == hist[0].hash)
    );
    assert!(r.issues.iter().any(|i| i.kind == IssueKind::UnexpectedFile));
    drop(s);
    // Without the cache the bad block is left out and the text falls back to the last good version.
    fs::remove_dir_all(dir.path().join("projects").join(&p).join("cache")).unwrap();
    let (_c, s) = open(dir.path());
    assert_eq!(s.sheet_text(&p, &sheet).unwrap(), "하나");
}

#[test]
fn restore_version_adds_a_block() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, _f, sheet) = new_project(&mut s);
    s.save_sheet(&p, &sheet, "초고").unwrap();
    s.save_sheet(&p, &sheet, "퇴고").unwrap();
    let hist = s.history(&p, &sheet).unwrap();
    let draft = &hist[1].hash;
    let sum = s.restore_version(&p, &sheet, draft).unwrap();
    assert_eq!(sum.title, "초고");
    let after = s.history(&p, &sheet).unwrap();
    assert_eq!(after.len(), hist.len() + 1);
    assert!(
        after.iter().any(|h| h.hash == hist[0].hash),
        "nothing erased"
    );
    assert_eq!(s.text_at(&p, &sheet, &hist[0].hash).unwrap(), "퇴고");
    assert_eq!(
        s.text_at(&p, &sheet, "0".repeat(64).as_str()),
        Err(StoreError::NotFound)
    );
}

#[test]
fn trash_restore_keeps_order() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, f, first) = new_project(&mut s);
    let ids: Vec<String> = std::iter::once(first)
        .chain((2..=4).map(|i| s.create_sheet(&p, &f, &format!("{i}화")).unwrap().id))
        .collect();
    let live = |s: &Store| {
        s.outline(&p).unwrap().folders[0]
            .sheets
            .iter()
            .map(|x| x.id.clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(live(&s), ids);
    s.trash_sheet(&p, &ids[1]).unwrap();
    s.trash_sheet(&p, &ids[2]).unwrap();
    let o = s.outline(&p).unwrap();
    assert_eq!(live(&s), [ids[0].clone(), ids[3].clone()]);
    assert_eq!(o.folders[0].sheets[1].order, 1);
    assert_eq!(
        o.trash.iter().map(|x| x.id.clone()).collect::<Vec<_>>(),
        [ids[2].clone(), ids[1].clone()]
    ); // newest first
    assert!(o.trash[0].trashed.is_some());
    s.restore_sheet(&p, &ids[2]).unwrap();
    s.restore_sheet(&p, &ids[1]).unwrap();
    assert_eq!(live(&s), ids);

    // Move: `4화` before `2화`, then to the other folder.
    s.move_sheet(&p, &ids[3], &f, Some(&ids[1])).unwrap();
    assert_eq!(
        live(&s),
        [
            ids[0].clone(),
            ids[3].clone(),
            ids[1].clone(),
            ids[2].clone()
        ]
    );
    let other = s.outline(&p).unwrap().folders[1].id.clone();
    s.move_sheet(&p, &ids[3], &other, None).unwrap();
    assert_eq!(s.outline(&p).unwrap().folders[1].sheets[0].id, ids[3]);

    // Forever: files go, a tombstone stays.
    s.trash_sheet(&p, &ids[2]).unwrap();
    let hashes: Vec<String> = s
        .history(&p, &ids[2])
        .unwrap()
        .into_iter()
        .map(|h| h.hash)
        .collect();
    s.empty_trash(&p).unwrap();
    assert!(s.outline(&p).unwrap().trash.is_empty());
    assert!(hashes.iter().all(|h| !changes(&s, &p).join(h).exists()));
    assert_eq!(s.sheet_text(&p, &ids[2]), Err(StoreError::NotFound));
    drop(s);
    let (_c, s) = open(dir.path());
    assert_eq!(live(&s), [ids[0].clone(), ids[1].clone()]);
    assert!(s.verify(&p).unwrap().ok);
}

#[test]
fn folders_delete_and_restore_together() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, f, first) = new_project(&mut s);
    let second = s.create_sheet(&p, &f, "둘").unwrap().id;
    s.trash_sheet(&p, &second).unwrap(); // trashed earlier: stays in the trash after restore_folder
    s.delete_folder(&p, &f).unwrap();
    let o = s.outline(&p).unwrap();
    assert_eq!(o.folders.len(), 1);
    assert_eq!(o.trash.len(), 2);
    let last = o.folders[0].id.clone();
    assert!(matches!(
        s.delete_folder(&p, &last),
        Err(StoreError::InvalidInput(_))
    ));
    s.restore_folder(&p, &f).unwrap();
    let o = s.outline(&p).unwrap();
    assert_eq!(
        o.folders[0]
            .sheets
            .iter()
            .map(|x| &x.id)
            .collect::<Vec<_>>(),
        [&first]
    );
    assert_eq!(o.trash.len(), 1);
    // Restoring the sheet brings its (now live) folder back as well.
    s.rename_folder(&p, &f, "본편").unwrap();
    let nf = s.create_folder(&p, "외전").unwrap();
    assert_eq!(nf.order, 2);
    assert_eq!(s.outline(&p).unwrap().folders[0].name, "본편");
}

#[test]
fn delete_project_is_soft_then_purged_after_30_days() {
    let dir = tempfile::tempdir().unwrap();
    let (clock, mut s) = open(dir.path());
    let (p, _f, sheet) = new_project(&mut s);
    let keep = s
        .create_project("남길 작품", Language::En, &["Chapters".into()])
        .unwrap()
        .id;
    s.save_sheet(&p, &sheet, "지울 원고").unwrap();
    s.delete_project(&p).unwrap();
    assert_eq!(
        s.projects().iter().map(|x| &x.id).collect::<Vec<_>>(),
        [&keep]
    );
    assert_eq!(s.deleted_projects()[0].id, p);
    s.restore_project(&p).unwrap();
    assert_eq!(s.projects().len(), 2);
    s.delete_project(&p).unwrap();
    drop(s);

    // 29 days later: still there.
    clock.advance(29 * 86_400_000);
    let c = ithaca_store::OpenOptions {
        clock: std::sync::Arc::new({
            let t = clock.0.clone();
            move || t.fetch_add(1000, std::sync::atomic::Ordering::SeqCst)
        }),
        ..Default::default()
    };
    let s = Store::open_with(dir.path(), "mac-test", c.clone()).unwrap();
    assert_eq!(s.deleted_projects().len(), 1);
    drop(s);
    clock.advance(2 * 86_400_000);
    // 31 days on, but nothing was written since the delete: the clock alone is not trusted
    // (it may have jumped), so nothing is purged yet.
    let mut s = Store::open_with(dir.path(), "mac-test", c.clone()).unwrap();
    assert_eq!(s.deleted_projects().len(), 1);
    // Writing confirms the clock; the next open purges.
    let ks = s.outline(&keep).unwrap().folders[0].sheets[0].id.clone();
    s.save_sheet(&keep, &ks, "오늘 쓴 글").unwrap();
    drop(s);
    let s = Store::open_with(dir.path(), "mac-test", c).unwrap();
    assert!(s.deleted_projects().is_empty());
    assert!(!dir.path().join("projects").join(&p).exists());
    assert_eq!(s.projects().len(), 1);
}

#[test]
fn old_trash_is_emptied_on_open() {
    let dir = tempfile::tempdir().unwrap();
    let (clock, mut s) = open(dir.path());
    let (p, f, first) = new_project(&mut s);
    let x = s.create_sheet(&p, &f, "버림").unwrap().id;
    s.trash_sheet(&p, &x).unwrap();
    drop(s);
    clock.advance(31 * 86_400_000);
    let t = clock.0.clone();
    let o = ithaca_store::OpenOptions {
        clock: std::sync::Arc::new(move || t.fetch_add(1, std::sync::atomic::Ordering::SeqCst)),
        ..Default::default()
    };
    let mut s = Store::open_with(dir.path(), "mac-test", o.clone()).unwrap();
    assert_eq!(
        s.outline(&p).unwrap().trash.len(),
        1,
        "clock not yet confirmed"
    );
    s.save_sheet(&p, &first, "오늘").unwrap();
    drop(s);
    let s = Store::open_with(dir.path(), "mac-test", o).unwrap();
    assert!(s.outline(&p).unwrap().trash.is_empty());
}

#[test]
fn clock_jump_forward_purges_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let (clock, mut s) = open(dir.path());
    let (p, f, _) = new_project(&mut s);
    let x = s.create_sheet(&p, &f, "버림").unwrap().id;
    s.trash_sheet(&p, &x).unwrap();
    let gone = s
        .create_project("지운 작품", Language::Ko, &["F".into()])
        .unwrap()
        .id;
    s.delete_project(&gone).unwrap();
    drop(s);
    // The clock jumps a year ahead (bad clock, manual change). Opening repeatedly purges nothing.
    clock.advance(365 * 86_400_000);
    for _ in 0..3 {
        let t = clock.0.clone();
        let o = ithaca_store::OpenOptions {
            clock: std::sync::Arc::new(move || t.fetch_add(1, std::sync::atomic::Ordering::SeqCst)),
            ..Default::default()
        };
        let s = Store::open_with(dir.path(), "mac-test", o).unwrap();
        assert_eq!(s.outline(&p).unwrap().trash.len(), 1);
        assert_eq!(s.deleted_projects().len(), 1);
    }
    assert!(dir.path().join("projects").join(&gone).exists());
}

#[test]
fn project_patch_and_summary() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, _f, sheet) = new_project(&mut s);
    s.save_sheet(&p, &sheet, "가나다 라마").unwrap();
    let goal = Goal {
        count: 5000,
        basis: GoalBasis::WithSpaces,
    };
    let sum = s
        .update_project(
            &p,
            ProjectPatch {
                title: Some("새 제목".into()),
                goal: Some(goal),
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!(
        (sum.title.as_str(), sum.goal, sum.sheets, sum.counts.chars),
        ("새 제목", Some(goal), 1, 6)
    );
    let sum = s
        .update_project(
            &p,
            ProjectPatch {
                goal: Some(Goal {
                    count: 0,
                    basis: GoalBasis::Words,
                }),
                language: Some(Language::En),
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!((sum.goal, sum.language), (None, Language::En));
    assert!(matches!(
        s.create_project("빈", Language::Ko, &[]),
        Err(StoreError::InvalidInput(_))
    ));
}

#[test]
fn search_and_export() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, f, a) = new_project(&mut s);
    s.save_sheet(&p, &a, "# 1화\n\n파도가 쳤다.").unwrap();
    let b = s
        .create_sheet(&p, &f, "# 2화\n\n또 *파도*가.\n＊＊＊\n끝")
        .unwrap()
        .id;
    let hits = s.search("파도", None);
    assert_eq!(hits.len(), 2);
    assert_eq!(
        (hits[0].sheet.as_str(), hits[0].title.as_str()),
        (a.as_str(), "1화")
    );
    assert_eq!(
        hits[1].offset,
        "# 2화\n\n또 *".encode_utf16().count() as u32
    );
    let out = s.export_text(&p, &[], &ExportOptions::default()).unwrap();
    assert_eq!(
        out,
        "1화\n\n파도가 쳤다.\n\n\n2화\n\n또 파도가.\n\n* * *\n\n끝"
    );
    let out = s
        .export_text(
            &p,
            std::slice::from_ref(&b),
            &ExportOptions {
                markdown: true,
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!(out, "# 2화\n\n또 *파도*가.\n＊＊＊\n끝");
    s.delete_project(&p).unwrap();
    assert!(s.search("파도", None).is_empty());
    assert_eq!(s.search("파도", Some(&p)).len(), 2);
}

#[test]
fn offline_fork_is_decided_and_reported_as_branched() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let (p, _f, sheet) = new_project(&mut s);
    s.save_sheet(&p, &sheet, "공통").unwrap();
    let head = s.history(&p, &sheet).unwrap()[0].hash.clone();
    let ch = changes(&s, &p);
    drop(s);
    // Two devices wrote on the same parent while offline (as a sync transport would deliver them).
    let mine = Block::seal(
        vec![head.clone()],
        sheet.as_str(),
        1,
        "mac-a",
        Actor::Me,
        Kind::Edit,
        T0 + 50_000,
        Body::Delta(delta::diff("공통", "공통 맥")),
    );
    let theirs = Block::seal(
        vec![head],
        sheet.as_str(),
        1,
        "phone-b",
        Actor::Me,
        Kind::Edit,
        T0 + 40_000,
        Body::Delta(delta::diff("공통", "공통 폰")),
    );
    for b in [&mine, &theirs] {
        fs::write(ch.join(&b.hash), b.to_bytes()).unwrap();
    }
    let (_c, s) = open(dir.path());
    let sum = s.outline(&p).unwrap().folders[0].sheets[0].clone();
    assert!(sum.branched);
    // Same epoch → the greater device id wins; the other is kept as a branch copy.
    assert_eq!(s.sheet_text(&p, &sheet).unwrap(), "공통 폰");
    assert_eq!(s.text_at(&p, &sheet, &mine.hash).unwrap(), "공통 맥");
    assert!(s.verify(&p).unwrap().ok);
}
