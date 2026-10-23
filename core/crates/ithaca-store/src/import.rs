//! Import of the web app's backup JSON (app-web/src/store.ts `State`, version 1; ADR-0007/0008).
//! Everything becomes new projects with new ids; nothing in the library is touched.

use ithaca_model::{FolderEntry, Goal, GoalBasis, Language, Toc};
use serde_json::Value;

use crate::error::{Result, StoreError};

pub struct WebProject {
    pub toc: Toc,
    /// (folder index, text, created, modified) in serial order.
    pub sheets: Vec<crate::NewSheet>,
}

fn num(v: &Value, key: &str) -> Option<f64> {
    v.get(key).and_then(Value::as_f64)
}

fn int(v: &Value, key: &str) -> Option<i64> {
    num(v, key).map(|n| n as i64)
}

fn string(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_string)
}

/// A JS timestamp is "set" when it is truthy (`deleted?: number`, `trashed?: number`).
fn set(v: &Value, key: &str) -> bool {
    num(v, key).is_some_and(|n| n != 0.0)
}

fn array<'a>(root: &'a Value, key: &str) -> Result<&'a Vec<Value>> {
    root.get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| StoreError::InvalidInput(format!("not an Ithaca web backup: no {key}")))
}

pub fn parse(json: &str) -> Result<Vec<WebProject>> {
    let root: Value = serde_json::from_str(json)
        .map_err(|e| StoreError::InvalidInput(format!("not JSON: {e}")))?;
    if root.get("version").and_then(Value::as_u64) != Some(1) {
        return Err(StoreError::InvalidInput(
            "not an Ithaca web backup (version 1)".into(),
        ));
    }
    let (projects, folders, sheets) = (
        array(&root, "projects")?,
        array(&root, "folders")?,
        array(&root, "sheets")?,
    );
    let mut out = Vec::new();
    for p in projects {
        let Some(pid) = string(p, "id") else { continue };
        if set(p, "deleted") {
            continue;
        }
        let created = int(p, "created").unwrap_or(0);
        let goal = p.get("goal").filter(|g| g.is_object()).and_then(|g| {
            let count = int(g, "count").filter(|c| *c > 0)? as u32;
            let basis = match g.get("basis").and_then(Value::as_str)? {
                "withSpaces" => GoalBasis::WithSpaces,
                "withoutSpaces" => GoalBasis::WithoutSpaces,
                "words" => GoalBasis::Words,
                _ => return None,
            };
            Some(Goal { count, basis })
        });
        let mut pf: Vec<&Value> = folders
            .iter()
            .filter(|f| {
                f.get("projectId").and_then(Value::as_str) == Some(pid.as_str())
                    && !set(f, "deleted")
                    && string(f, "id").is_some()
            })
            .collect();
        pf.sort_by(|a, b| {
            num(a, "order")
                .unwrap_or(0.0)
                .total_cmp(&num(b, "order").unwrap_or(0.0))
        });
        let mut toc = Toc {
            title: string(p, "title").unwrap_or_default(),
            language: if p.get("language").and_then(Value::as_str) == Some("en") {
                Language::En
            } else {
                Language::Ko
            },
            goal,
            created,
            ..Default::default()
        };
        let mut wsheets = Vec::new();
        for (fi, f) in pf.iter().enumerate() {
            let fid = string(f, "id").unwrap_or_default();
            toc.folders
                .push(FolderEntry::new("", string(f, "name").unwrap_or_default()));
            let mut fs: Vec<&Value> = sheets
                .iter()
                .filter(|s| {
                    s.get("folderId").and_then(Value::as_str) == Some(fid.as_str())
                        && !set(s, "trashed")
                })
                .filter(|s| s.get("body").is_some_and(Value::is_string))
                .collect();
            // sheetsIn(): order, then created.
            fs.sort_by(|a, b| {
                num(a, "order")
                    .unwrap_or(f64::MAX)
                    .total_cmp(&num(b, "order").unwrap_or(f64::MAX))
                    .then_with(|| {
                        int(a, "created")
                            .unwrap_or(0)
                            .cmp(&int(b, "created").unwrap_or(0))
                    })
            });
            for (n, s) in fs.into_iter().enumerate() {
                let c = int(s, "created").unwrap_or(created);
                let m = int(s, "modified").unwrap_or(c).max(c);
                wsheets.push(crate::NewSheet {
                    folder: fi,
                    text: string(s, "body").unwrap_or_default(),
                    created: c,
                    modified: m,
                    // The first folder is the serial: its sheets become episodes 1..n (added: qa1).
                    episode: (fi == 0).then(|| ithaca_model::EpisodeInfo {
                        number: Some(n as u32 + 1),
                        ..Default::default()
                    }),
                });
            }
        }
        if toc.folders.is_empty() {
            // The web app always keeps one live folder; a hand-edited file might not.
            toc.folders.push(FolderEntry::new("", ""));
        }
        for f in &mut toc.folders {
            f.id = uuid::Uuid::new_v4().simple().to_string();
        }
        out.push(WebProject {
            toc,
            sheets: wsheets,
        });
    }
    Ok(out)
}
