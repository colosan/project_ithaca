//! Round 3: excluded episodes, next release, folder stats, platform goal bases, read-only opens
//! beside a writer, and the Claude connector settings file.

mod common;

use common::*;
use ithaca_model::{EpisodeInfo, EpisodeStatus, Goal, GoalBasis, Language};
use ithaca_store::mcp::{MCP_FILE, McpSettings};
use ithaca_store::{ProjectPatch, Store, StoreError};

const DAY: i64 = 86_400_000;

fn ep(status: EpisodeStatus) -> EpisodeInfo {
    EpisodeInfo {
        status,
        ..Default::default()
    }
}

#[test]
fn excluded_sheets_keep_no_number_and_are_not_stock() {
    let dir = tempfile::tempdir().unwrap();
    let (_tc, mut s) = open(dir.path());
    let p = s
        .create_project("작품", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let o = s.outline(&p).unwrap();
    let f = o.folders[0].id.clone();
    let prologue = o.folders[0].sheets[0].id.clone();
    s.save_sheet(&p, &prologue, "# 프롤로그\n\n밤.").unwrap();
    let e1 = s.create_sheet(&p, &f, "# 1화\n\n가 나.").unwrap().id;
    let notice = s.create_sheet(&p, &f, "# 공지\n\n휴재").unwrap().id;
    let e2 = s.create_sheet(&p, &f, "# 2화\n\n다라마바").unwrap().id;
    assert_eq!(s.renumber_episodes(&p, &f).unwrap(), 4);
    for id in [&prologue, &notice] {
        let mut info = s.sheet_summary_of(&p, id).unwrap().episode.unwrap();
        info.excluded = true;
        s.set_episode(&p, id, Some(info)).unwrap();
    }
    assert_eq!(s.renumber_episodes(&p, &f).unwrap(), 2);
    let num = |s: &Store, id: &str| s.sheet_summary_of(&p, id).unwrap().episode.unwrap().number;
    assert_eq!(num(&s, &prologue), None);
    assert_eq!(num(&s, &e1), Some(1));
    assert_eq!(num(&s, &notice), None);
    assert_eq!(num(&s, &e2), Some(2));
    assert_eq!(s.stock(&p, &f).unwrap(), 2);
    s.set_status_through(&p, &f, &e1, EpisodeStatus::Published)
        .unwrap();
    assert_eq!(s.stock(&p, &f).unwrap(), 1);

    // Survives a reopen (stored in the toc as "excluded": true).
    drop(s);
    let (_tc, s) = open(dir.path());
    assert!(
        s.sheet_summary_of(&p, &notice)
            .unwrap()
            .episode
            .unwrap()
            .excluded
    );
    let st = s.folder_stats(&p, &f).unwrap();
    assert_eq!((st.sheets, st.episodes), (4, 2));
    // Every episode is published (e1) or a draft (e2); the prologue was published too but is excluded.
    assert_eq!((st.published, st.scheduled, st.drafts), (1, 0, 1));
    let all: u32 = s.outline(&p).unwrap().folders[0]
        .sheets
        .iter()
        .map(|x| x.counts.chars)
        .sum();
    assert_eq!(st.total.chars, all);
    let e1c = s.sheet_summary_of(&p, &e1).unwrap().counts.chars;
    let e2c = s.sheet_summary_of(&p, &e2).unwrap().counts.chars;
    assert_eq!(st.average_chars, (e1c + e2c).div_ceil(2));
    // Bodies without titles: `밤.` `가 나.` `휴재` `다라마바`.
    assert_eq!(st.munpia_total, 2 + 4 + 2 + 4);
    assert_eq!(st.novelpia_total, 1 + 2 + 2 + 4);
    assert!(matches!(
        s.folder_stats(&p, "nope"),
        Err(StoreError::NotFound)
    ));
}

#[test]
fn next_release_is_the_earliest_future_scheduled_time() {
    let dir = tempfile::tempdir().unwrap();
    let (tc, mut s) = open(dir.path());
    let p = s
        .create_project("작품", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let f = s.outline(&p).unwrap().folders[0].id.clone();
    assert_eq!(s.next_release(&p, &f).unwrap(), None);
    let mk = |s: &mut Store, status, at: Option<i64>| {
        let id = s.create_sheet(&p, &f, "글").unwrap().id;
        let info = EpisodeInfo {
            publish_at: at,
            ..ep(status)
        };
        s.set_episode(&p, &id, Some(info)).unwrap();
        id
    };
    mk(&mut s, EpisodeStatus::Scheduled, Some(T0 + 3 * DAY));
    mk(&mut s, EpisodeStatus::Scheduled, Some(T0 - DAY)); // past: already out
    mk(&mut s, EpisodeStatus::Draft, Some(T0 + DAY)); // not scheduled
    let soon = mk(&mut s, EpisodeStatus::Scheduled, Some(T0 + 2 * DAY));
    mk(&mut s, EpisodeStatus::Scheduled, None);
    assert_eq!(s.next_release(&p, &f).unwrap(), Some(T0 + 2 * DAY));
    s.trash_sheet(&p, &soon).unwrap();
    assert_eq!(s.next_release(&p, &f).unwrap(), Some(T0 + 3 * DAY));
    tc.advance(4 * DAY);
    assert_eq!(s.next_release(&p, &f).unwrap(), None);
}

#[test]
fn platform_goal_bases_round_trip() {
    let dir = tempfile::tempdir().unwrap();
    let (_tc, mut s) = open(dir.path());
    let p = s
        .create_project("작품", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    for basis in [GoalBasis::Munpia, GoalBasis::Novelpia] {
        let goal = Goal { count: 5000, basis };
        let patch = ProjectPatch {
            goal: Some(goal),
            ..Default::default()
        };
        assert_eq!(s.update_project(&p, patch).unwrap().goal, Some(goal));
    }
    drop(s);
    let (_tc, s) = open(dir.path());
    assert_eq!(
        s.project_summary_of(&p).unwrap().goal.map(|g| g.basis),
        Some(GoalBasis::Novelpia)
    );
}

#[test]
fn read_only_open_beside_the_writer_sees_new_blocks_and_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    assert!(matches!(
        Store::open_read_only(dir.path().join("missing")),
        Err(StoreError::NotFound)
    ));
    let (_tc, mut w) = open(dir.path());
    let p = w
        .create_project("작품", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let sheet = w.outline(&p).unwrap().folders[0].sheets[0].id.clone();
    w.save_sheet(&p, &sheet, "# 1화\n\n하나").unwrap();

    let before = snapshot_tree(dir.path());
    let mut r = Store::open_read_only(dir.path()).unwrap();
    assert!(r.read_only() && !r.info().locked_by_other);
    assert_eq!(r.sheet_text(&p, &sheet).unwrap(), "# 1화\n\n하나");
    assert!(matches!(
        r.save_sheet(&p, &sheet, "x"),
        Err(StoreError::ReadOnly)
    ));
    assert!(matches!(
        r.set_mcp_settings(true, std::slice::from_ref(&p)),
        Err(StoreError::ReadOnly)
    ));

    // The writer goes on (new block, new sheet, a toc change); a fresh read-only open sees it all.
    w.save_sheet(&p, &sheet, "# 1화\n\n하나 둘").unwrap();
    let f = w.outline(&p).unwrap().folders[0].id.clone();
    let s2 = w.create_sheet(&p, &f, "# 2화").unwrap().id;
    assert_eq!(
        r.sheet_text(&p, &sheet).unwrap(),
        "# 1화\n\n하나",
        "a snapshot"
    );
    let r2 = Store::open_read_only(dir.path()).unwrap();
    assert_eq!(r2.sheet_text(&p, &sheet).unwrap(), "# 1화\n\n하나 둘");
    assert_eq!(r2.outline(&p).unwrap().folders[0].sheets[1].id, s2);
    assert!(r2.info().problems.is_empty(), "{:?}", r2.info().problems);
    drop((r, r2));

    // Nothing the read-only opens did changed a file: only the writer's new files differ.
    let after = snapshot_tree(dir.path());
    for (path, size) in &before {
        if path.starts_with("projects") && path.to_string_lossy().contains("cache") {
            continue; // the writer rewrote its own caches
        }
        assert!(after.contains(&(path.clone(), *size)), "{path:?} changed");
    }
    // And the writer still holds the lock: a read-only open never took it.
    assert!(!w.read_only());
}

#[test]
fn mcp_settings_file() {
    let dir = tempfile::tempdir().unwrap();
    let (_tc, mut s) = open(dir.path());
    assert_eq!(s.mcp_settings(), McpSettings::default());
    let got = s
        .set_mcp_settings(true, &["a".into(), "b".into(), "a".into()])
        .unwrap();
    assert_eq!(got.projects, vec!["a", "b"]);
    let on_disk = McpSettings::read(dir.path()).unwrap().unwrap();
    assert_eq!(on_disk, got);
    let raw = std::fs::read_to_string(dir.path().join(MCP_FILE)).unwrap();
    assert!(raw.contains("\"permission\": \"read\""), "{raw}");
    s.set_mcp_settings(false, &[]).unwrap();
    assert!(!s.mcp_settings().enabled);
}
