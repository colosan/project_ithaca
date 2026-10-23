//! Mac QA round 4: line endings on save and export, text-folder import order and names.

mod common;

use std::fs;

use common::*;
use ithaca_model::{ExportOptions, Language, platform_body};
use unicode_normalization::UnicodeNormalization;

#[test]
fn crlf_and_cr_become_lf_on_save_and_export() {
    let lib = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(lib.path());
    let p = s
        .create_project("등대", Language::Ko, &["연재".into()])
        .unwrap()
        .id;
    let o = s.outline(&p).unwrap();
    let e1 = o.folders[0].sheets[0].id.clone();
    s.save_sheet(&p, &e1, "# 1화\r\n\r\n첫 줄.\r둘째 줄.\r\n")
        .unwrap();
    assert_eq!(
        s.sheet_text(&p, &e1).unwrap(),
        "# 1화\n\n첫 줄.\n둘째 줄.\n"
    );
    // The same text with `\n` is no change.
    let n = s.history(&p, &e1).unwrap().len();
    s.save_sheet(&p, &e1, "# 1화\n\n첫 줄.\n둘째 줄.\n")
        .unwrap();
    assert_eq!(s.history(&p, &e1).unwrap().len(), n);
    let e2 = s
        .create_sheet(&p, &o.folders[0].id, "# 2화\r\n본문")
        .unwrap()
        .id;
    assert_eq!(s.sheet_text(&p, &e2).unwrap(), "# 2화\n본문");

    // Export and platform bodies treat CR as a line break even in text from elsewhere.
    assert_eq!(
        platform_body("# 3화\r\n\r\n하나\r\n둘\r셋"),
        "하나\n\n둘\n\n셋"
    );
    let md = ExportOptions {
        markdown: true,
        ..Default::default()
    };
    assert_eq!(ithaca_model::export_sheets(["a\r\nb\r\n"], &md), "a\nb");
    let all = s.export_text(&p, &[], &ExportOptions::default()).unwrap();
    assert!(!all.contains('\r'));
}

#[test]
fn prologues_first_extras_after_and_names_in_nfc() {
    let tmp = tempfile::tempdir().unwrap();
    let src = tmp.path().join("검은 탑");
    fs::create_dir_all(&src).unwrap();
    let nfd = |s: &str| s.nfd().collect::<String>();
    for name in [
        "10화.txt",
        "2화.txt",
        "1화.txt",
        "에필로그.txt",
        "외전 2.txt",
        "외전 1.txt",
        "프롤로그.txt",
        "후기.txt",
        "공지 - 휴재.txt",
        "Side Story.md",
    ] {
        let stem = name.rsplit_once('.').unwrap().0;
        fs::write(src.join(name), format!("{stem}\n\n본문")).unwrap();
    }
    // A decomposed name (as macOS may hand it out) with no text: its title is the file name.
    fs::write(src.join(nfd("3화 등대.txt")), "").unwrap();
    // Notes: NFD "하" must sort after NFC "가" (decomposed it would come first).
    let notes = src.join(nfd("설정"));
    fs::create_dir(&notes).unwrap();
    fs::write(notes.join(nfd("하.txt")), "").unwrap();
    fs::write(notes.join("가.txt"), "").unwrap();

    let lib = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(lib.path());
    let r = s.import_text_folder(&src, None, None).unwrap();
    assert!(r.skipped.is_empty(), "{:?}", r.skipped);
    let p = s.projects().pop().unwrap();
    assert_eq!(p.title, "검은 탑");
    let o = s.outline(&p.id).unwrap();
    assert_eq!(o.folders[1].name, "설정", "folder name in NFC");
    let rows: Vec<(String, Option<u32>, bool)> = o.folders[0]
        .sheets
        .iter()
        .map(|x| {
            let e = x.episode.clone().unwrap();
            (x.title.clone(), e.number, e.excluded)
        })
        .collect();
    let row = |t: &str, n: Option<u32>, x: bool| (t.to_string(), n, x);
    assert_eq!(
        rows,
        [
            row("프롤로그", None, true),
            row("1화", Some(1), false),
            row("2화", Some(2), false),
            row("3화 등대", Some(3), false),
            row("10화", Some(4), false),
            row("Side Story", None, true),
            row("공지 - 휴재", None, true),
            row("외전 1", None, true),
            row("외전 2", None, true),
            row("후기", None, true),
            row("에필로그", None, true),
        ]
    );
    assert_eq!(
        o.folders[1]
            .sheets
            .iter()
            .map(|x| x.title.as_str())
            .collect::<Vec<_>>(),
        ["가", "하"]
    );
    assert!(
        o.folders[1].sheets.iter().all(|x| x.episode.is_none()),
        "only the serial folder gets episode information"
    );
}

#[cfg(unix)]
#[test]
fn an_unreadable_subfolder_is_skipped_not_fatal() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let src = tmp.path().join("원고");
    fs::create_dir_all(src.join("잠긴 폴더")).unwrap();
    fs::write(src.join("1화.txt"), "1화").unwrap();
    fs::write(src.join("잠긴 폴더/비밀.txt"), "비밀").unwrap();
    let locked = src.join("잠긴 폴더");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    if fs::read_dir(&locked).is_ok() {
        // Running as root: permissions don't stop reading.
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        return;
    }
    let lib = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(lib.path());
    let r = s.import_text_folder(&src, None, None);
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
    let r = r.unwrap();
    assert_eq!((r.projects, r.folders, r.sheets), (1, 1, 1));
    assert_eq!(r.skipped.len(), 1, "{:?}", r.skipped);
    assert!(
        r.skipped[0].starts_with("잠긴 폴더 (can't read: "),
        "{:?}",
        r.skipped
    );
}
