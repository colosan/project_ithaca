//! Import of a realistic web backup (core/fixtures/web-backup.json).

mod common;

use common::*;
use ithaca_model::{Goal, GoalBasis, Language};
use ithaca_store::{ImportReport, StoreError};

#[test]
fn imports_web_backup_as_new_projects() {
    let json = std::fs::read_to_string(fixtures().join("web-backup.json")).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    let existing = s
        .create_project("이미 있던 작품", Language::Ko, &["연재".into()])
        .unwrap()
        .id;

    let r = s.import_web_backup(&json).unwrap();
    // Deleted project, deleted folder and trashed sheets are skipped; the empty folder is kept.
    assert_eq!(
        r,
        ImportReport {
            projects: 2,
            folders: 4,
            sheets: 5
        }
    );
    let ps = s.projects();
    assert_eq!(ps.len(), 3);
    // Imported projects keep their creation time, so they sort before the newer existing one.
    assert_eq!(
        ps[2].id, existing,
        "nothing overwritten, creation order kept"
    );
    let ko = ps.iter().find(|p| p.title == "등대지기의 딸").unwrap();
    assert_eq!(
        (ko.language, ko.goal, ko.created),
        (
            Language::Ko,
            Some(Goal {
                count: 5500,
                basis: GoalBasis::WithSpaces
            }),
            1_790_000_000_000
        )
    );
    assert!(
        !["p8k2m1xa9qz1", "pq7w3n0v2bx4"].contains(&ko.id.as_str()),
        "new ids"
    );

    let o = s.outline(&ko.id).unwrap();
    assert_eq!(
        o.folders
            .iter()
            .map(|f| f.name.as_str())
            .collect::<Vec<_>>(),
        ["연재", "설정", "자료"]
    );
    let serial = &o.folders[0].sheets;
    assert_eq!(
        serial.iter().map(|x| x.title.as_str()).collect::<Vec<_>>(),
        ["1화 · 섬", "2화 · 안개", "3화 · 귀항"]
    );
    assert_eq!(
        (serial[1].created, serial[1].modified),
        (1_790_100_000_000, 1_790_200_000_000)
    );
    assert_eq!(
        s.history(&ko.id, &serial[1].id).unwrap()[0].at,
        1_790_200_000_000
    );
    assert!(o.trash.is_empty());
    assert!(
        s.sheet_text(&ko.id, &serial[1].id)
            .unwrap()
            .contains("👨‍👩‍👧 가족사진")
    );
    assert!(s.verify(&ko.id).unwrap().ok);

    let en = ps.iter().find(|p| p.title == "The Salt Road").unwrap();
    assert_eq!(
        (en.language, en.goal, en.counts.words),
        (Language::En, None, 13)
    );

    // Importing again adds copies; still nothing overwritten.
    s.import_web_backup(&json).unwrap();
    assert_eq!(s.projects().len(), 5);
}

#[test]
fn rejects_what_is_not_a_web_backup() {
    let dir = tempfile::tempdir().unwrap();
    let (_c, mut s) = open(dir.path());
    for bad in [
        "",
        "[]",
        "{\"version\":2,\"projects\":[],\"folders\":[],\"sheets\":[]}",
        "{\"version\":1}",
    ] {
        assert!(
            matches!(s.import_web_backup(bad), Err(StoreError::InvalidInput(_))),
            "{bad}"
        );
    }
    assert!(s.projects().is_empty());
}
