//! Import of a folder of plain-text manuscripts (core/fixtures/text-folder). (added: txt-import)

mod common;

use std::fs;
use std::path::Path;

use common::*;
use ithaca_model::{EpisodeStatus, Language};
use ithaca_store::{ImportReport, StoreError};

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for e in fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        if e.file_type().unwrap().is_dir() {
            copy_dir(&e.path(), &to.join(e.file_name()));
        } else {
            fs::copy(e.path(), to.join(e.file_name())).unwrap();
        }
    }
}

#[test]
fn imports_a_folder_of_manuscripts() {
    let tmp = tempfile::tempdir().unwrap();
    let src = tmp.path().join("등대지기의 딸");
    copy_dir(&fixtures().join("text-folder"), &src);
    // What Hangul Office / Notepad save as "ANSI" on Korean Windows: CP949, CRLF.
    let (cp949, _, bad) = encoding_rs::EUC_KR.encode("11화 · 똠방\r\n\r\n뱃고동이 울렸다.\r\n");
    assert!(!bad);
    fs::write(src.join("11화.txt"), &cp949).unwrap();
    assert!(std::str::from_utf8(&cp949).is_err(), "really not UTF-8");
    let be: Vec<u8> = [0xFE, 0xFF]
        .into_iter()
        .chain("12화\n\n끝.".encode_utf16().flat_map(u16::to_be_bytes))
        .collect();
    fs::write(src.join("12화.txt"), be).unwrap();
    fs::write(src.join(".DS_Store"), b"\0\0\0\x01Bud1").unwrap();
    fs::write(src.join("설정/.DS_Store"), b"\0\0\0\x01Bud1").unwrap();
    fs::write(src.join("큰 파일.txt"), vec![b'a'; 5 * 1024 * 1024 + 1]).unwrap();
    fs::create_dir(src.join(".git")).unwrap();
    fs::write(src.join(".git/HEAD.txt"), "ref").unwrap();
    fs::create_dir(src.join("빈 폴더")).unwrap();

    let lib = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(lib.path());
    let r = s.import_text_folder(&src, None, None).unwrap();
    assert_eq!(
        r,
        ImportReport {
            projects: 1,
            folders: 2,
            sheets: 10,
            skipped: vec![
                "큰 파일.txt (larger than 5 MB)".into(),
                "표지.jpg (not .txt or .md)".into(),
            ],
        }
    );

    let ps = s.projects();
    assert_eq!(ps.len(), 1);
    let p = &ps[0];
    assert_eq!(
        (p.title.as_str(), p.language),
        ("등대지기의 딸", Language::Ko)
    );
    let o = s.outline(&p.id).unwrap();
    let names: Vec<_> = o.folders.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(
        names,
        ["연재", "설정"],
        "root files first; empty folder left out"
    );

    let serial = &o.folders[0].sheets;
    assert_eq!(
        serial.iter().map(|x| x.title.as_str()).collect::<Vec<_>>(),
        [
            "1화 · 섬",
            "2화 · 안개",
            "3화 · 등대",
            "10화 · 귀항",
            "11화 · 똠방",
            "12화",
            "제4화",
        ],
        "natural order; UTF-16 LE/BE, BOM and CP949 decoded; long first line → file name as title"
    );
    let eps: Vec<_> = serial
        .iter()
        .map(|x| x.episode.as_ref().map(|e| (e.number, e.status)))
        .collect();
    assert_eq!(
        eps,
        (1..=7)
            .map(|n| Some((Some(n), EpisodeStatus::Draft)))
            .collect::<Vec<_>>()
    );
    let text = |i: usize| s.sheet_text(&p.id, &serial[i].id).unwrap();
    assert_eq!(text(1), "2화 · 안개\n\n안개가 짙었다.\n", "CRLF → LF");
    assert_eq!(text(2), "3화 · 등대\n\n불빛이 깜박였다.\n");
    assert_eq!(text(3), "10화 · 귀항\n\n배가 돌아왔다.\n", "BOM dropped");
    assert_eq!(text(4), "11화 · 똠방\n\n뱃고동이 울렸다.\n");
    assert!(text(6).starts_with("# 제4화\n\n그날 밤 등대지기는"));

    let notes = &o.folders[1].sheets;
    assert_eq!(
        notes.iter().map(|x| x.title.as_str()).collect::<Vec<_>>(),
        ["지명", "지도", "인물"],
        "nested 세계/지도 flattened into 설정"
    );
    assert!(notes.iter().all(|x| x.episode.is_none()));
    assert!(s.verify(&p.id).unwrap().ok);
}

#[test]
fn title_and_language_given_or_detected() {
    let tmp = tempfile::tempdir().unwrap();
    let src = tmp.path().join("salt");
    fs::create_dir(&src).unwrap();
    fs::write(src.join("chapter 2.txt"), "Two\n\nThe road went on.").unwrap();
    fs::write(src.join("chapter 10.txt"), "Ten\n\nThe sea.").unwrap();
    fs::write(src.join("empty.md"), "").unwrap();

    let lib = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(lib.path());
    s.import_text_folder(&src, None, None).unwrap();
    s.import_text_folder(&src, Some("소금길"), Some(Language::Ko))
        .unwrap();
    let ps = s.projects();
    assert_eq!(
        ps.iter()
            .map(|p| (p.title.as_str(), p.language))
            .collect::<Vec<_>>(),
        [("salt", Language::En), ("소금길", Language::Ko)]
    );
    let o = s.outline(&ps[0].id).unwrap();
    assert_eq!(o.folders[0].name, "Episodes");
    assert_eq!(
        o.folders[0]
            .sheets
            .iter()
            .map(|x| x.title.as_str())
            .collect::<Vec<_>>(),
        ["Two", "Ten", "empty"]
    );
    assert_eq!(s.outline(&ps[1].id).unwrap().folders[0].name, "연재");
}

#[test]
fn rejects_what_has_nothing_to_import() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(lib.path());
    let empty = tmp.path().join("empty");
    fs::create_dir_all(empty.join("sub")).unwrap();
    fs::write(empty.join(".hidden.txt"), "x").unwrap();
    fs::write(empty.join("cover.png"), "x").unwrap();
    let file = tmp.path().join("one.txt");
    fs::write(&file, "x").unwrap();
    for bad in [empty.clone(), file, tmp.path().join("missing")] {
        assert!(
            matches!(
                s.import_text_folder(&bad, None, None),
                Err(StoreError::InvalidInput(_))
            ),
            "{bad:?}"
        );
    }
    assert!(s.projects().is_empty());
    assert!(
        !lib.path().join("projects").exists()
            || fs::read_dir(lib.path().join("projects")).unwrap().count() == 0
    );
}
