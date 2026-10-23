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
            sheets: 5,
            skipped: vec![]
        }
    );
    let ps = s.projects();
    assert_eq!(ps.len(), 3);
    // (qa1) Projects are listed in the order they came into this library: imports go last, even
    // though they keep their (older) creation time.
    assert_eq!(
        ps[0].id, existing,
        "nothing overwritten, library order kept"
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
    // (qa1) The first folder's sheets become episodes 1..n, Draft; other folders get none.
    let eps: Vec<_> = serial
        .iter()
        .map(|x| x.episode.as_ref().map(|e| (e.number, e.status)))
        .collect();
    assert_eq!(
        eps,
        [1, 2, 3].map(|n| Some((Some(n), ithaca_model::EpisodeStatus::Draft)))
    );
    assert!(
        o.folders[1..]
            .iter()
            .flat_map(|f| &f.sheets)
            .all(|x| x.episode.is_none())
    );
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

    // Importing again adds copies at the end; still nothing overwritten. A suffix marks them.
    s.import_web_backup_with_suffix(&json, " (웹)").unwrap();
    let ps = s.projects();
    assert_eq!(ps.len(), 5);
    assert!(ps[3..].iter().all(|p| p.title.ends_with(" (웹)")), "{ps:?}");
    assert!(ps[..3].iter().all(|p| !p.title.ends_with(" (웹)")));
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
