//! Story bible over a library (ADR-0010, core/API.md §Story bible).

mod common;

use std::time::Instant;

use common::*;
use ithaca_model::{EntryKind, Language, entry_template};
use ithaca_store::{Store, StoreError, bible_import_preview};

struct Fixture {
    p: String,
    serial: String,
    notes: String,
    ep: Vec<String>,
    seoyun: String,
    island: String,
    haewon: String,
    hana: String,
    lamp: String,
}

fn entry(kind: &str, name: &str, extra: &str, body: &str) -> String {
    format!("---\n종류: {kind}\n{extra}---\n# {name}\n\n{body}")
}

fn fixture(s: &mut Store) -> Fixture {
    let p = s
        .create_project(
            "등대지기의 딸",
            Language::Ko,
            &["연재".into(), "설정".into()],
        )
        .unwrap()
        .id;
    let o = s.outline(&p).unwrap();
    let (serial, notes) = (o.folders[0].id.clone(), o.folders[1].id.clone());
    let e1 = o.folders[0].sheets[0].id.clone();
    s.save_sheet(
        &p,
        &e1,
        "# 1화 안개\n\n서윤이가 등대로 갔다.\n“윤이야, 어디 가?”\n벼리섬에 안개가 꼈다.",
    )
    .unwrap();
    let e2 = s
        .create_sheet(
            &p,
            &serial,
            "# 2화 불빛\n\n해원은 서윤을 기다렸다. 하나, 둘.",
        )
        .unwrap()
        .id;
    let e3 = s
        .create_sheet(&p, &serial, "# 3화 빈 등대\n\n아무도 없었다.")
        .unwrap()
        .id;
    // (note) Only `원고` (episode metadata) are numbered: make every serial sheet one.
    for x in s.outline(&p).unwrap().folders[0]
        .sheets
        .iter()
        .map(|x| x.id.clone())
        .collect::<Vec<_>>()
    {
        s.set_episode(&p, &x, Some(ithaca_model::EpisodeInfo::default()))
            .unwrap();
    }
    s.renumber_episodes(&p, &serial).unwrap();
    let seoyun = s
        .create_sheet(
            &p,
            &notes,
            &entry(
                "인물",
                "서윤",
                "별칭: 윤이\n나이: 17\n",
                "## 한 줄 소개\n불빛 횟수를 세는 아이.\n\n## 관계\n해원과 자랐다.\n",
            ),
        )
        .unwrap()
        .id;
    let island = s
        .create_sheet(
            &p,
            &notes,
            &entry("장소", "벼리섬", "", "## 한 줄 소개\n안개 섬.\n"),
        )
        .unwrap()
        .id;
    let haewon = s
        .create_sheet(&p, &notes, &entry("인물", "해원", "", ""))
        .unwrap()
        .id;
    let hana = s
        .create_sheet(
            &p,
            &notes,
            &entry("용어", "하나", "본문에서 찾지 않음: 예\n", ""),
        )
        .unwrap()
        .id;
    let lamp = s
        .create_sheet(&p, &notes, &entry("용어", "등불", "", ""))
        .unwrap()
        .id;
    // A trashed entry and a trashed episode are not part of the bible.
    let gone = s
        .create_sheet(&p, &notes, &entry("인물", "아무개", "", ""))
        .unwrap()
        .id;
    s.trash_sheet(&p, &gone).unwrap();
    let gone_ep = s
        .create_sheet(&p, &serial, "# 4화\n\n서윤과 아무개가 떠났다.")
        .unwrap()
        .id;
    s.trash_sheet(&p, &gone_ep).unwrap();
    Fixture {
        p,
        serial,
        notes,
        ep: vec![e1, e2, e3],
        seoyun,
        island,
        haewon,
        hana,
        lamp,
    }
}

#[test]
fn bible_lists_entries_by_last_seen() {
    let dir = tempfile::tempdir().unwrap();
    let (_tc, mut s) = open(dir.path());
    let f = fixture(&mut s);
    let b = s.bible(&f.p).unwrap();
    let names: Vec<&str> = b.iter().map(|e| e.name.as_str()).collect();
    // `2화`: `서윤` · `해원` (by name), `1화`: `벼리섬`, never seen: `등불` · `하나` (by name).
    assert_eq!(names, ["서윤", "해원", "벼리섬", "등불", "하나"]);
    let seoyun = &b[0];
    assert_eq!(seoyun.sheet, f.seoyun);
    assert_eq!(seoyun.folder, f.notes);
    assert_eq!(seoyun.kind, EntryKind::Character);
    assert_eq!(seoyun.aliases, ["윤이"]);
    assert_eq!(seoyun.fields.len(), 1);
    assert_eq!(seoyun.fields[0].key, "나이");
    assert_eq!(seoyun.sections[0].body, "불빛 횟수를 세는 아이.");
    let last = seoyun.last_seen.as_ref().unwrap();
    assert_eq!(last.sheet, f.ep[1]);
    assert_eq!(last.folder, f.serial);
    assert_eq!(last.title, "2화 불빛");
    assert_eq!(last.number, Some(2));
    assert_eq!(last.count, 1);
    assert_eq!(last.lines, ["해원은 서윤을 기다렸다. 하나, 둘."]);
    assert_eq!(b[2].sheet, f.island);
    assert_eq!(b[2].last_seen.as_ref().unwrap().sheet, f.ep[0]);
    assert_eq!(b[1].sheet, f.haewon);
    assert_eq!(b[3].sheet, f.lamp);
    // Marked no-match: listed, never seen.
    assert_eq!(b[4].sheet, f.hana);
    assert!(!b[4].matchable && b[4].last_seen.is_none());
    assert_eq!(s.bible("nope"), Err(StoreError::NotFound));
}

#[test]
fn appearances_in_reading_order() {
    let dir = tempfile::tempdir().unwrap();
    let (_tc, mut s) = open(dir.path());
    let f = fixture(&mut s);
    let a = s.appearances(&f.p, &f.seoyun).unwrap();
    assert_eq!(a.len(), 2);
    assert_eq!(a[0].sheet, f.ep[0]);
    assert_eq!(a[0].number, Some(1));
    assert_eq!(a[0].count, 2);
    // First mention: `서윤` of `서윤이가`, on the third line.
    let t = s.sheet_text(&f.p, &f.ep[0]).unwrap();
    let u: Vec<u16> = t.encode_utf16().collect();
    let first = String::from_utf16(&u[a[0].offset as usize..(a[0].offset + a[0].length) as usize]);
    assert_eq!(first.unwrap(), "서윤");
    // A dialogue line wins over narration.
    assert_eq!(a[0].lines, ["“윤이야, 어디 가?”"]);
    assert_eq!(a[1].sheet, f.ep[1]);
    // Entry sheets themselves are not appearances (the sheet of `해원` mentions nobody; that of `서윤` mentions `해원`).
    let h = s.appearances(&f.p, &f.haewon).unwrap();
    assert_eq!(
        h.iter().map(|x| x.sheet.as_str()).collect::<Vec<_>>(),
        [f.ep[1].as_str()]
    );
    assert!(s.appearances(&f.p, &f.hana).unwrap().is_empty());
    assert!(s.appearances(&f.p, &f.lamp).unwrap().is_empty());
    assert_eq!(
        s.appearances(&f.p, &f.ep[0]),
        Err(StoreError::NotFound),
        "not an entry"
    );
}

#[test]
fn mentions_in_unsaved_text() {
    let dir = tempfile::tempdir().unwrap();
    let (_tc, mut s) = open(dir.path());
    let f = fixture(&mut s);
    let text = "# 5화\n\n윤이는 벼리섬으로, 해원은 등불을 들고. 하나도 없다. 서윤희는 다른 사람.";
    let m = s.mentions_in(&f.p, text).unwrap();
    let u: Vec<u16> = text.encode_utf16().collect();
    let got: Vec<(String, String, bool)> = m
        .iter()
        .map(|x| {
            let s = String::from_utf16(&u[x.offset as usize..(x.offset + x.length) as usize]);
            (x.entry.clone(), s.unwrap(), x.alias)
        })
        .collect();
    let want = |e: &str, n: &str, a: bool| (e.to_string(), n.to_string(), a);
    assert_eq!(
        got,
        [
            want(&f.seoyun, "윤이", true),
            want(&f.island, "벼리섬", false),
            want(&f.haewon, "해원", false),
            want(&f.lamp, "등불", false),
        ]
    );
    // An entry's own text: its front matter is skipped and its own name not reported.
    let own = s.sheet_text(&f.p, &f.seoyun).unwrap();
    let m = s.mentions_in(&f.p, &own).unwrap();
    assert_eq!(m.len(), 1);
    assert_eq!(m[0].entry, f.haewon);
    assert!(s.mentions_in(&f.p, "").unwrap().is_empty());
}

#[test]
fn summaries_search_and_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let f = {
        let (_tc, mut s) = open(dir.path());
        let f = fixture(&mut s);
        let sum = s.sheet_summary_of(&f.p, &f.seoyun).unwrap();
        assert_eq!(sum.entry, Some(EntryKind::Character));
        assert_eq!(sum.title, "서윤");
        assert_eq!(sum.excerpt, "불빛 횟수를 세는 아이.");
        assert_eq!(s.sheet_summary_of(&f.p, &f.ep[0]).unwrap().entry, None);
        // Search skips an entry's front matter: `윤이` is only an alias there.
        let hits = s.search("윤이", Some(&f.p));
        assert_eq!(hits.len(), 2); // `서윤이가` · `윤이야`
        assert!(hits.iter().all(|h| h.sheet == f.ep[0]));
        // A hit in an entry's body keeps sheet-relative offsets.
        let hits = s.search("횟수", Some(&f.p));
        assert_eq!(hits.len(), 1);
        let t = s.sheet_text(&f.p, &f.seoyun).unwrap();
        let u: Vec<u16> = t.encode_utf16().collect();
        let h = &hits[0];
        assert_eq!(
            String::from_utf16(&u[h.offset as usize..(h.offset + h.length) as usize]).unwrap(),
            "횟수"
        );
        assert_eq!(h.title, "서윤");
        // Export leaves front matter out.
        let txt = s
            .export_text(&f.p, std::slice::from_ref(&f.seoyun), &Default::default())
            .unwrap();
        assert!(!txt.contains("종류") && txt.starts_with("서윤"));
        f
    };
    // Reopened from caches: the kinds are the same (they are derived from the text).
    let (_tc, s) = open(dir.path());
    let o = s.outline(&f.p).unwrap();
    let kinds: Vec<Option<EntryKind>> = o.folders[1].sheets.iter().map(|x| x.entry).collect();
    assert_eq!(
        kinds,
        [
            Some(EntryKind::Character),
            Some(EntryKind::Place),
            Some(EntryKind::Character),
            Some(EntryKind::Term),
            Some(EntryKind::Term),
        ]
    );
    assert_eq!(s.bible(&f.p).unwrap().len(), 5);
}

#[test]
fn notion_import_preview_then_create() {
    let dir = tempfile::tempdir().unwrap();
    let (_tc, mut s) = open(&dir.path().join("lib"));
    let f = fixture(&mut s);
    let src = dir.path().join("notion");
    std::fs::create_dir_all(src.join("인물 0123456789abcdef0123456789abcdef")).unwrap();
    std::fs::write(
        src.join("인물 0123456789abcdef0123456789abcdef/도윤 fedcba9876543210fedcba9876543210.md"),
        "# 도윤\n\n나이: 19\n별칭: 윤\n\n## 말투\n반말.\n",
    )
    .unwrap();
    std::fs::write(
        src.join("가람 0123456789abcdef0123456789abcdef.md"),
        "그냥 메모.\n",
    )
    .unwrap();
    std::fs::write(src.join("image.png"), [0u8, 1, 2]).unwrap();
    let before = snapshot_tree(dir.path());
    let preview = bible_import_preview(&src, EntryKind::Character, Language::Ko).unwrap();
    assert_eq!(snapshot_tree(dir.path()), before, "preview writes nothing");
    let rows: Vec<(&str, &str, u32, u32)> = preview
        .iter()
        .map(|e| (e.source.as_str(), e.name.as_str(), e.fields, e.sections))
        .collect();
    assert_eq!(
        rows,
        [
            ("가람 0123456789abcdef0123456789abcdef.md", "가람", 0, 1),
            (
                "인물 0123456789abcdef0123456789abcdef/도윤 fedcba9876543210fedcba9876543210.md",
                "도윤",
                2,
                1
            ),
        ]
    );
    // One file works too.
    let one = bible_import_preview(
        &src.join("가람 0123456789abcdef0123456789abcdef.md"),
        EntryKind::Term,
        Language::En,
    )
    .unwrap();
    assert_eq!(one.len(), 1);
    assert!(one[0].text.starts_with("---\nkind: term\n"));
    assert_eq!(
        bible_import_preview(&src.join("missing"), EntryKind::Term, Language::Ko),
        Err(StoreError::NotFound)
    );

    let texts: Vec<String> = preview.iter().map(|e| e.text.clone()).collect();
    // A folder that isn't there: nothing is created.
    let blocks = std::fs::read_dir(changes(&s, &f.p)).unwrap().count();
    assert_eq!(
        s.import_bible(&f.p, "nope", &texts),
        Err(StoreError::NotFound)
    );
    assert_eq!(
        std::fs::read_dir(changes(&s, &f.p)).unwrap().count(),
        blocks
    );

    let ids = s.import_bible(&f.p, &f.notes, &texts).unwrap();
    assert_eq!(ids.len(), 2);
    // One block per sheet and one table-of-contents block.
    assert_eq!(
        std::fs::read_dir(changes(&s, &f.p)).unwrap().count(),
        blocks + 3
    );
    let o = s.outline(&f.p).unwrap();
    let tail: Vec<&str> = o.folders[1]
        .sheets
        .iter()
        .rev()
        .take(2)
        .map(|x| x.id.as_str())
        .collect();
    assert_eq!(tail, [ids[1].as_str(), ids[0].as_str()]);
    let b = s.bible(&f.p).unwrap();
    let doyun = b.iter().find(|e| e.name == "도윤").unwrap();
    assert_eq!(doyun.aliases, ["윤"]);
    assert_eq!(
        doyun
            .sections
            .iter()
            .find(|x| x.title == "말투")
            .unwrap()
            .body,
        "반말."
    );
    assert!(s.import_bible(&f.p, &f.notes, &[]).unwrap().is_empty());
}

/// 300 sheets × 5,000 characters × 40 entries. Run in release for the real number:
/// `cargo test --release -p ithaca-store --test bible -- --ignored --nocapture`.
#[test]
#[ignore]
fn bench_bible_and_appearances() {
    let dir = tempfile::tempdir().unwrap();
    let (_tc, mut s) = open(dir.path());
    let p = s
        .create_project("벤치", Language::Ko, &["연재".into(), "설정".into()])
        .unwrap()
        .id;
    let o = s.outline(&p).unwrap();
    let (serial, notes) = (o.folders[0].id.clone(), o.folders[1].id.clone());
    let names: Vec<String> = (0..40)
        .map(|i| {
            let a = char::from_u32(0xAC00 + (i % 19) * 588).unwrap();
            let b = char::from_u32(0xB098 + i * 28).unwrap();
            format!("{a}{b}윤")
        })
        .collect();
    let mut first_entry = String::new();
    for n in &names {
        let id = s
            .create_sheet(
                &p,
                &notes,
                &entry_template(EntryKind::Character, n, Language::Ko),
            )
            .unwrap()
            .id;
        if first_entry.is_empty() {
            first_entry = id;
        }
    }
    let filler = "그날 밤 바다는 조용했고 등대의 불빛은 세 번 깜빡였다. ";
    for i in 0..300 {
        let mut t = format!("# {}화\n\n", i + 1);
        let mut k = 0;
        while t.chars().count() < 5000 {
            t.push_str(filler);
            if k % 4 == 0 {
                t.push_str(&format!("“{}아, 이리 와.” ", names[(i + k) % names.len()]));
            }
            k += 1;
            if k % 6 == 0 {
                t.push('\n');
            }
        }
        s.create_sheet(&p, &serial, &t).unwrap();
    }
    let t0 = Instant::now();
    let b = s.bible(&p).unwrap();
    let t_bible = t0.elapsed();
    let t1 = Instant::now();
    let a = s.appearances(&p, &first_entry).unwrap();
    let t_app = t1.elapsed();
    assert_eq!(b.len(), 40);
    assert!(b.iter().all(|e| e.last_seen.is_some()));
    assert!(!a.is_empty());
    println!(
        "bible: {t_bible:?}, appearances: {t_app:?}, together {:?} ({} appearances)",
        t_bible + t_app,
        a.len()
    );
    // Worst case for bible: an entry nobody mentions makes it read every sheet.
    s.create_sheet(
        &p,
        &notes,
        &entry_template(EntryKind::Term, "없는말", Language::Ko),
    )
    .unwrap();
    let t2 = Instant::now();
    let b = s.bible(&p).unwrap();
    let t_full = t2.elapsed();
    assert!(b.last().unwrap().last_seen.is_none());
    println!("bible, every sheet read: {t_full:?}");
    if !cfg!(debug_assertions) {
        assert!((t_bible + t_app).as_millis() < 200);
        assert!((t_full + t_app).as_millis() < 200);
    }
}
