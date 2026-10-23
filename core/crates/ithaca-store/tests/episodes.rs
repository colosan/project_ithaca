//! Episode metadata in the table of contents: backward compatible with format-1 tables of contents
//! written before it existed (core/fixtures/library-v1).

mod common;

use common::*;
use ithaca_model::{EpisodeInfo, EpisodeStatus, Language, Toc};
use ithaca_store::fsutil::copy_dir;
use ithaca_store::{Store, StoreError};

fn ep(number: Option<u32>, status: EpisodeStatus) -> EpisodeInfo {
    EpisodeInfo {
        number,
        status,
        ..Default::default()
    }
}

#[test]
fn v1_fixture_without_episodes_loads_and_takes_them() {
    let dir = tempfile::tempdir().unwrap();
    copy_dir(&fixtures().join("library-v1"), dir.path(), &|_| false).unwrap();
    let (_tc, clock) = TestClock::new(1_790_100_000_000);
    let mut s = Store::open_with(dir.path(), "mac-test", opts(clock.clone())).unwrap();
    let p = s.projects()[0].id.clone();
    let o = s.outline(&p).unwrap();
    assert!(
        o.folders
            .iter()
            .flat_map(|f| &f.sheets)
            .all(|x| x.episode.is_none())
    );
    assert!(o.trash.iter().all(|x| x.episode.is_none()));
    let serial = o.folders[0].id.clone();
    let (ep1, ep2) = (
        o.folders[0].sheets[0].id.clone(),
        o.folders[0].sheets[1].id.clone(),
    );
    // No metadata: every live sheet is stock.
    assert_eq!(s.stock(&p, &serial).unwrap(), 2);

    let info = EpisodeInfo {
        number: Some(1),
        status: EpisodeStatus::Published,
        publish_at: Some(1_790_050_000_000),
        platform: Some("노벨피아".into()),
    };
    let sum = s.set_episode(&p, &ep1, Some(info.clone())).unwrap();
    assert_eq!(sum.episode, Some(info.clone()));
    s.set_episode(&p, &ep2, Some(ep(None, EpisodeStatus::Scheduled)))
        .unwrap();
    assert_eq!(s.stock(&p, &serial).unwrap(), 1);
    drop(s);

    let s = Store::open_with(dir.path(), "mac-test", opts(clock)).unwrap();
    let o = s.outline(&p).unwrap();
    assert_eq!(o.folders[0].sheets[0].episode, Some(info));
    assert_eq!(
        o.folders[0].sheets[1].episode.as_ref().map(|e| e.status),
        Some(EpisodeStatus::Scheduled)
    );
    assert!(s.verify(&p).unwrap().ok);
}

#[test]
fn episode_json_shape_and_old_tocs() {
    // A format-1 toc as round 1 wrote it, plus a field from some later core.
    let old = r#"{"title":"t","language":"ko","goal":null,"created":1,"deleted":null,
        "folders":[{"id":"f","name":"연재","deleted":null,"sheets":["a","b"],"color":"blue"}],
        "sheets":{"a":{"created":1,"trashed":null},"b":{"created":2,"trashed":null,"pinned":true}},
        "removed":[],"futureField":{"x":1}}"#;
    let mut toc = Toc::from_text(old).unwrap();
    assert!(toc.sheets["a"].episode.is_none());
    toc.sheets.get_mut("a").unwrap().episode = Some(EpisodeInfo {
        number: Some(3),
        status: EpisodeStatus::Revising,
        publish_at: None,
        platform: None,
    });
    let text = toc.to_text();
    // Unknown fields survive a rewrite; empty episode fields are left out.
    for needle in [
        r#""futureField""#,
        r#""color": "blue""#,
        r#""pinned": true"#,
        r#""episode": {"#,
        r#""number": 3"#,
        r#""status": "revising""#,
    ] {
        assert!(text.contains(needle), "{needle} in {text}");
    }
    assert!(!text.contains("publishAt"));
    assert_eq!(Toc::from_text(&text).unwrap(), toc);
    // A sheet without episode metadata writes no "episode" key at all.
    assert_eq!(text.matches("\"episode\"").count(), 1);
}

#[test]
fn renumber_and_stock() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let p = s
        .create_project("등대", Language::Ko, &["연재".into(), "설정".into()])
        .unwrap()
        .id;
    let o = s.outline(&p).unwrap();
    let serial = o.folders[0].id.clone();
    let prologue = o.folders[0].sheets[0].id.clone();
    let a = s.create_sheet(&p, &serial, "a").unwrap().id;
    let b = s.create_sheet(&p, &serial, "b").unwrap().id;
    let c = s.create_sheet(&p, &serial, "c").unwrap().id;
    let gone = s.create_sheet(&p, &serial, "x").unwrap().id;
    for x in [&a, &b, &c, &gone] {
        s.set_episode(&p, x, Some(ep(Some(99), EpisodeStatus::Draft)))
            .unwrap();
    }
    s.trash_sheet(&p, &gone).unwrap();
    s.move_sheet(&p, &c, &serial, Some(&a)).unwrap(); // prologue, c, a, b
    s.set_episode(&p, &b, Some(ep(Some(99), EpisodeStatus::Published)))
        .unwrap();
    let blocks_before = s.history(&p, &a).unwrap().len();
    assert_eq!(s.renumber_episodes(&p, &serial).unwrap(), 3);
    assert_eq!(s.history(&p, &a).unwrap().len(), blocks_before);
    let o = s.outline(&p).unwrap();
    let nums: Vec<Option<u32>> = o.folders[0]
        .sheets
        .iter()
        .map(|x| x.episode.as_ref().and_then(|e| e.number))
        .collect();
    assert_eq!(nums, [None, Some(1), Some(2), Some(3)]);
    // Status is untouched by renumbering; the trashed sheet keeps its old number.
    assert_eq!(
        o.folders[0].sheets[3].episode.as_ref().unwrap().status,
        EpisodeStatus::Published
    );
    assert_eq!(o.trash[0].episode.as_ref().unwrap().number, Some(99));
    // prologue (no metadata), c, a are stock; b is published; the trashed sheet doesn't count.
    assert_eq!(s.stock(&p, &serial).unwrap(), 3);
    s.set_episode(&p, &prologue, None).unwrap();
    assert_eq!(s.stock(&p, &o.folders[1].id).unwrap(), 0);
    assert!(matches!(s.stock(&p, "nope"), Err(StoreError::NotFound)));
    assert!(matches!(
        s.renumber_episodes(&p, "nope"),
        Err(StoreError::NotFound)
    ));
    assert!(matches!(
        s.set_episode(&p, "toc", None),
        Err(StoreError::NotFound)
    ));
}
