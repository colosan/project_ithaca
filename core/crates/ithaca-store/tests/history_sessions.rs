// History grouped into writing sessions (core/API.md §History, design/screens/history/spec.md "Mac (0.5.3)").
mod common;

use common::*;
use ithaca_model::Language;
use ithaca_store::{SESSION_GAP_MS, Store};

fn new_sheet(s: &mut Store) -> (String, String) {
    let p = s
        .create_project("등대", Language::Ko, &["연재".into()])
        .unwrap();
    let o = s.outline(&p.id).unwrap();
    (p.id, o.folders[0].sheets[0].id.clone())
}

#[test]
fn autosaves_within_the_gap_are_one_session_with_net_change() {
    let dir = tempfile::tempdir().unwrap();
    let (clock, mut s) = open(dir.path());
    let (p, sheet) = new_sheet(&mut s);
    // Autosaves every few seconds: typed, then a sentence typed and taken back.
    for t in ["첫", "첫 문장.", "첫 문장. 군더더기", "첫 문장."] {
        clock.advance(3_000);
        s.save_sheet(&p, &sheet, t).unwrap();
    }
    let blocks = s.history(&p, &sheet).unwrap();
    let sessions = s.history_sessions(&p, &sheet).unwrap();
    assert_eq!(sessions.len(), 1, "{sessions:#?}");
    let one = &sessions[0];
    assert_eq!(one.entries.len(), blocks.len());
    assert_eq!(one.base, None, "starts at the chain's first block");
    // Net from "" to "첫 문장.": the typed-and-deleted words don't count.
    assert_eq!((one.added, one.removed), (5, 0));
    assert_eq!(one.entries[0].hash, blocks[0].hash, "newest first");
    assert!(one.start < one.end);
}

#[test]
fn a_pause_device_or_kind_change_starts_a_new_session_and_nothing_is_lost() {
    let dir = tempfile::tempdir().unwrap();
    let (clock, mut s) = open(dir.path());
    let (p, sheet) = new_sheet(&mut s);
    s.save_sheet(&p, &sheet, "하나").unwrap();
    s.save_sheet(&p, &sheet, "하나 둘").unwrap();
    clock.advance(SESSION_GAP_MS);
    s.save_sheet(&p, &sheet, "하나 둘 셋").unwrap();
    s.save_sheet(&p, &sheet, "하나 셋").unwrap();
    drop(s);
    // Another install writes the next session.
    let (_c2, clock2) = TestClock::new(T0 + 3 * SESSION_GAP_MS);
    let mut s = Store::open_with(dir.path(), "mac-other", opts(clock2)).unwrap();
    s.save_sheet(&p, &sheet, "하나 셋 넷").unwrap();

    let blocks = s.history(&p, &sheet).unwrap();
    let sessions = s.history_sessions(&p, &sheet).unwrap();
    assert_eq!(sessions.len(), 3, "{sessions:#?}");
    assert_eq!(sessions[0].device, "mac-other");
    assert_eq!((sessions[0].added, sessions[0].removed), (2, 0));
    // Second session: "하나 둘" → "하나 셋" nets to +1 −1, not the +2 −2 of its two blocks.
    assert_eq!(sessions[1].entries.len(), 2);
    assert_eq!((sessions[1].added, sessions[1].removed), (1, 1));
    assert_eq!(
        sessions[1].base.as_deref(),
        Some(sessions[2].entries[0].hash.as_str())
    );
    // Every block is in exactly one session, in the plain list's order.
    let flat: Vec<String> = sessions
        .iter()
        .flat_map(|g| g.entries.iter().map(|e| e.hash.clone()))
        .collect();
    assert_eq!(
        flat,
        blocks.iter().map(|b| b.hash.clone()).collect::<Vec<_>>()
    );
    // The text before a session is its `base`.
    assert_eq!(
        s.text_at(&p, &sheet, sessions[0].base.as_ref().unwrap())
            .unwrap(),
        "하나 셋"
    );
}

#[test]
fn restore_works_on_any_point_and_grouping_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let (_clock, mut s) = open(dir.path());
    let (p, sheet) = new_sheet(&mut s);
    s.save_sheet(&p, &sheet, "초고").unwrap();
    s.save_sheet(&p, &sheet, "초고를 고쳤다").unwrap();
    s.save_sheet(&p, &sheet, "퇴고").unwrap();
    let before = snapshot_tree(dir.path());
    let sessions = s.history_sessions(&p, &sheet).unwrap();
    assert_eq!(
        snapshot_tree(dir.path()),
        before,
        "display grouping writes no file"
    );
    // A point in the middle of the session.
    let mid = &sessions[0].entries[1];
    assert_eq!(s.text_at(&p, &sheet, &mid.hash).unwrap(), "초고를 고쳤다");
    s.restore_version(&p, &sheet, &mid.hash).unwrap();
    assert_eq!(s.sheet_text(&p, &sheet).unwrap(), "초고를 고쳤다");
    let after = s.history_sessions(&p, &sheet).unwrap();
    let n: usize = after.iter().map(|g| g.entries.len()).sum();
    assert_eq!(n, s.history(&p, &sheet).unwrap().len());
    assert!(
        after
            .iter()
            .flat_map(|g| &g.entries)
            .any(|e| e.hash == sessions[0].entries[0].hash),
        "nothing erased"
    );
}

#[test]
fn long_chains_across_snapshots_keep_exact_net_counts() {
    let dir = tempfile::tempdir().unwrap();
    let (clock, mut s) = open(dir.path());
    let (p, sheet) = new_sheet(&mut s);
    let mut text = String::new();
    // 3 sessions × 40 autosaves (past SNAPSHOT_EVERY), each adding one word.
    for _ in 0..3 {
        for _ in 0..40 {
            text.push_str("말 ");
            s.save_sheet(&p, &sheet, &text).unwrap();
        }
        clock.advance(SESSION_GAP_MS * 2);
    }
    let sessions = s.history_sessions(&p, &sheet).unwrap();
    assert_eq!(
        sessions.len(),
        3,
        "{:?}",
        sessions.iter().map(|g| g.entries.len()).collect::<Vec<_>>()
    );
    for g in &sessions[..2] {
        assert_eq!((g.added, g.removed), (80, 0));
    }
}
