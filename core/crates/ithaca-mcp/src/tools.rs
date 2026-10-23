//! The tools Claude can call. Descriptions are English (ADR-0005); manuscript text is returned as
//! written.
//!
//! Every tool is a plain function over a [`Ctx`] (settings + a fresh read-only snapshot). Adding a
//! write tool later: give it `Access::Edit`, list it only when `mcp.json` grants edit, and have it
//! go through the app — the lock holder — so its blocks are recorded as `actor: claude`
//! (ADR-0002 §6) and can be reverted from history. This server never opens the library writable.

use ithaca_model::{CountRule, EpisodeInfo, EpisodeStatus, GoalBasis, count_for, munpia_pages};
use ithaca_store::{FolderInfo, Outline, ProjectSummary, SheetSummary};
use serde_json::{Map, Value, json};

use crate::{Ctx, ToolError};

/// Longest sheet text `read_sheet` returns, in characters.
pub const MAX_SHEET_CHARS: usize = 200_000;
/// Longest `get_lore` output, in characters; the sheets left out are listed so Claude can read them.
pub const MAX_LORE_CHARS: usize = 150_000;
/// Search hits returned in all, and per project.
pub const MAX_HITS: usize = 100;
pub const MAX_HITS_PER_PROJECT: usize = 50;

/// What a tool may do. Only `Read` exists; see the module docs for `Edit`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    Read,
}

pub struct Output {
    pub text: String,
    /// Also sent as `structuredContent`; `text` is then its JSON.
    pub structured: Option<Value>,
}

impl Output {
    fn json(v: Value) -> Output {
        Output {
            text: serde_json::to_string_pretty(&v).unwrap_or_default(),
            structured: Some(v),
        }
    }

    fn text(t: String) -> Output {
        Output {
            text: t,
            structured: None,
        }
    }
}

type Run = fn(&Ctx, &Map<String, Value>) -> Result<Output, ToolError>;

pub struct Tool {
    pub name: &'static str,
    pub title: &'static str,
    pub description: &'static str,
    pub access: Access,
    pub run: Run,
    schema: fn() -> Value,
}

fn project_prop() -> Value {
    json!({ "type": "string", "description": "Project id from list_projects, or its exact title." })
}

pub const TOOLS: &[Tool] = &[
    Tool {
        name: "list_projects",
        title: "List projects",
        description: "List the writing projects the writer shared with Claude: id, title, language, \
            number of sheets, total length and length goal. Call this first.",
        access: Access::Read,
        run: list_projects,
        schema: || json!({ "type": "object", "additionalProperties": false }),
    },
    Tool {
        name: "get_outline",
        title: "Project outline",
        description: "The folders of a project in order and the sheets in each, in serial order: \
            sheet id, title, length, and episode information (number, status, publish time, \
            platform) for serial folders. Trashed sheets are left out.",
        access: Access::Read,
        run: get_outline,
        schema: || {
            json!({ "type": "object", "properties": { "project": project_prop() },
                    "required": ["project"], "additionalProperties": false })
        },
    },
    Tool {
        name: "read_sheet",
        title: "Read a sheet",
        description: "The full text of one sheet (Markdown as the writer typed it; the first line is \
            the title), with its folder, length counts (Ithaca, Munpia, Novelpia) and episode \
            information.",
        access: Access::Read,
        run: read_sheet,
        schema: || {
            json!({ "type": "object", "properties": {
                        "project": project_prop(),
                        "sheet": { "type": "string", "description": "Sheet id from get_outline or search, or its exact title." } },
                    "required": ["project", "sheet"], "additionalProperties": false })
        },
    },
    Tool {
        name: "search",
        title: "Search text",
        description: "Case-insensitive plain-text search over the shared projects (or one project). \
            Returns up to 100 hits with the sheet and the surrounding line.",
        access: Access::Read,
        run: search,
        schema: || {
            json!({ "type": "object", "properties": {
                        "query": { "type": "string", "description": "Text to find, as written (Korean or English)." },
                        "project": { "type": "string", "description": "Optional: limit to this project (id or exact title)." } },
                    "required": ["query"], "additionalProperties": false })
        },
    },
    Tool {
        name: "get_lore",
        title: "Setting notes",
        description: "Every sheet of the project's non-serial folders (setting notes, characters, \
            world-building, plot notes) in one text, each under a heading with its folder and \
            sheet id. Very long notes are cut; the sheets left out are listed for read_sheet.",
        access: Access::Read,
        run: get_lore,
        schema: || {
            json!({ "type": "object", "properties": { "project": project_prop() },
                    "required": ["project"], "additionalProperties": false })
        },
    },
    Tool {
        name: "get_episode_stats",
        title: "Episode statistics",
        description: "Serial statistics per folder: episodes, total and average length, Munpia and \
            Novelpia totals, how many are published / scheduled / drafts, stock (episodes written \
            but not yet published), the next scheduled release, and one row per episode.",
        access: Access::Read,
        run: get_episode_stats,
        schema: || {
            json!({ "type": "object", "properties": {
                        "project": project_prop(),
                        "folder": { "type": "string", "description": "Optional: folder id or name. Default: every serial folder." } },
                    "required": ["project"], "additionalProperties": false })
        },
    },
];

/// `tools/list` entries, in a fixed order.
pub fn list() -> Vec<Value> {
    TOOLS
        .iter()
        .filter(|t| t.access == Access::Read)
        .map(|t| {
            json!({
                "name": t.name,
                "title": t.title,
                "description": t.description,
                "inputSchema": (t.schema)(),
                "annotations": { "title": t.title, "readOnlyHint": true, "openWorldHint": false },
            })
        })
        .collect()
}

pub fn find(name: &str) -> Option<&'static Tool> {
    TOOLS.iter().find(|t| t.name == name)
}

// ── Helpers ───────────────────────────────────────────────────────────

fn arg<'a>(args: &'a Map<String, Value>, key: &str) -> Result<&'a str, ToolError> {
    opt_arg(args, key)?.ok_or_else(|| ToolError(format!("Missing argument: {key}.")))
}

fn opt_arg<'a>(args: &'a Map<String, Value>, key: &str) -> Result<Option<&'a str>, ToolError> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if s.trim().is_empty() => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.trim())),
        Some(_) => Err(ToolError(format!("Argument {key} must be a string."))),
    }
}

/// Live projects the writer shared, in library order.
pub fn shared_projects(ctx: &Ctx) -> Vec<ProjectSummary> {
    ctx.store
        .projects()
        .into_iter()
        .filter(|p| ctx.settings.exposes(&p.id))
        .collect()
}

/// A shared project by id or exact title. Hidden and missing projects look the same.
fn project(ctx: &Ctx, key: &str) -> Result<ProjectSummary, ToolError> {
    let shared = shared_projects(ctx);
    shared
        .iter()
        .find(|p| p.id == key)
        .or_else(|| shared.iter().find(|p| p.title == key))
        .or_else(|| {
            shared
                .iter()
                .find(|p| p.title.to_lowercase() == key.to_lowercase())
        })
        .cloned()
        .ok_or_else(|| {
            ToolError(format!(
                "No shared project \"{key}\". Call list_projects for the projects the writer shared."
            ))
        })
}

/// Serial folders: those with episode information. A project with none treats its first folder
/// as the serial (new projects and imports put episodes there).
fn serial_flags(o: &Outline) -> Vec<bool> {
    let flags: Vec<bool> = o
        .folders
        .iter()
        .map(|f| f.sheets.iter().any(|s| s.episode.is_some()))
        .collect();
    if flags.iter().any(|f| *f) {
        flags
    } else {
        (0..flags.len()).map(|i| i == 0).collect()
    }
}

fn status_name(s: EpisodeStatus) -> &'static str {
    match s {
        EpisodeStatus::Draft => "draft",
        EpisodeStatus::Revising => "revising",
        EpisodeStatus::Scheduled => "scheduled",
        EpisodeStatus::Published => "published",
    }
}

fn basis_name(b: GoalBasis) -> &'static str {
    match b {
        GoalBasis::WithSpaces => "characters with spaces",
        GoalBasis::WithoutSpaces => "characters without spaces",
        GoalBasis::Words => "words",
        GoalBasis::Munpia => "Munpia characters",
        GoalBasis::Novelpia => "Novelpia characters",
    }
}

/// `2026-10-24 18:00 +09:00` in the Mac's time zone.
pub fn local_time(ms: i64) -> String {
    let off = ithaca_store::fsutil::local_offset_ms(ms);
    let local = ms + off;
    let mins = local.div_euclid(60_000).rem_euclid(1440);
    let sign = if off < 0 { '-' } else { '+' };
    let o = off.abs() / 60_000;
    format!(
        "{} {:02}:{:02} {sign}{:02}:{:02}",
        ithaca_store::fsutil::utc_date(local),
        mins / 60,
        mins % 60,
        o / 60,
        o % 60
    )
}

fn time(ms: Option<i64>) -> Value {
    ms.map_or(Value::Null, |t| json!({ "ms": t, "local": local_time(t) }))
}

fn episode_json(e: &Option<EpisodeInfo>) -> Value {
    match e {
        None => Value::Null,
        Some(e) => json!({
            "number": e.number,
            "status": status_name(e.status),
            "publishAt": time(e.publish_at),
            "platform": e.platform,
            "excluded": e.excluded,
        }),
    }
}

fn project_json(p: &ProjectSummary) -> Value {
    json!({
        "id": p.id,
        "title": p.title,
        "language": match p.language { ithaca_model::Language::Ko => "ko", ithaca_model::Language::En => "en" },
        "sheets": p.sheets,
        "chars": p.counts.chars,
        "charsNoSpace": p.counts.chars_no_space,
        "words": p.counts.words,
        "goalPerEpisode": p.goal.map(|g| json!({ "count": g.count, "basis": basis_name(g.basis) })),
        "modified": time(Some(p.modified)),
    })
}

fn sheet_row(s: &SheetSummary) -> Value {
    json!({
        "id": s.id,
        "title": s.title,
        "chars": s.counts.chars,
        "episode": episode_json(&s.episode),
        "damaged": s.damaged,
    })
}

fn folder_by<'a>(o: &'a Outline, key: &str) -> Result<(usize, &'a FolderInfo), ToolError> {
    o.folders
        .iter()
        .enumerate()
        .find(|(_, f)| f.id == key)
        .or_else(|| o.folders.iter().enumerate().find(|(_, f)| f.name == key))
        .ok_or_else(|| {
            ToolError(format!(
                "No folder \"{key}\" in this project. get_outline lists the folders."
            ))
        })
}

/// The first `max` characters of `s`, and whether it was cut.
fn cut(s: &str, max: usize) -> (&str, bool) {
    match s.char_indices().nth(max) {
        Some((i, _)) => (&s[..i], true),
        None => (s, false),
    }
}

// ── Tools ─────────────────────────────────────────────────────────────

fn list_projects(ctx: &Ctx, _: &Map<String, Value>) -> Result<Output, ToolError> {
    let ps: Vec<Value> = shared_projects(ctx).iter().map(project_json).collect();
    let note = if ps.is_empty() {
        "The writer has not shared any project with Claude yet (Ithaca → Settings → Claude)."
    } else {
        ""
    };
    Ok(Output::json(json!({ "projects": ps, "note": note })))
}

pub fn get_outline(ctx: &Ctx, args: &Map<String, Value>) -> Result<Output, ToolError> {
    let p = project(ctx, arg(args, "project")?)?;
    let o = ctx.store.outline(&p.id)?;
    let serial = serial_flags(&o);
    let folders: Vec<Value> = o
        .folders
        .iter()
        .zip(&serial)
        .map(|(f, serial)| {
            json!({
                "id": f.id,
                "name": f.name,
                "kind": if *serial { "serial" } else { "notes" },
                "sheets": f.sheets.iter().map(sheet_row).collect::<Vec<_>>(),
            })
        })
        .collect();
    Ok(Output::json(
        json!({ "project": project_json(&p), "folders": folders }),
    ))
}

fn read_sheet(ctx: &Ctx, args: &Map<String, Value>) -> Result<Output, ToolError> {
    let p = project(ctx, arg(args, "project")?)?;
    let key = arg(args, "sheet")?;
    let o = ctx.store.outline(&p.id)?;
    let found = o
        .folders
        .iter()
        .flat_map(|f| f.sheets.iter().map(move |s| (f, s)))
        .find(|(_, s)| s.id == key)
        .or_else(|| {
            o.folders
                .iter()
                .flat_map(|f| f.sheets.iter().map(move |s| (f, s)))
                .find(|(_, s)| s.title == key)
        });
    let Some((folder, s)) = found else {
        return Err(ToolError(format!(
            "No sheet \"{key}\" in \"{}\". get_outline lists the sheets.",
            p.title
        )));
    };
    let text = ctx.store.sheet_text(&p.id, &s.id)?;
    let body = ithaca_model::platform_body(&text);
    let (shown, truncated) = cut(&text, MAX_SHEET_CHARS);
    let mut head = vec![
        format!("Project: {} ({})", p.title, p.id),
        format!("Folder: {} ({})", folder.name, folder.id),
        format!("Sheet: {} ({})", s.title, s.id),
        format!(
            "Length: {} characters with spaces, {} without, {} words; Munpia {} ({} pages), Novelpia {}",
            s.counts.chars,
            s.counts.chars_no_space,
            s.counts.words,
            count_for(&body, CountRule::Munpia),
            munpia_pages(&body),
            count_for(&body, CountRule::Novelpia),
        ),
        format!("Last edited: {}", local_time(s.modified)),
    ];
    if let Some(e) = &s.episode {
        let mut line = format!("Episode: {}", status_name(e.status));
        if let Some(n) = e.number {
            line.push_str(&format!(", number {n}"));
        }
        if e.excluded {
            line.push_str(", not counted as an episode (prologue/side story/notice)");
        }
        if let Some(t) = e.publish_at {
            line.push_str(&format!(", publish time {}", local_time(t)));
        }
        if let Some(pl) = &e.platform {
            line.push_str(&format!(", platform {pl}"));
        }
        head.push(line);
    }
    if s.damaged {
        head.push("Note: this sheet is damaged on disk; the text is its last good version.".into());
    }
    if truncated {
        head.push(format!(
            "Note: only the first {MAX_SHEET_CHARS} characters are shown."
        ));
    }
    Ok(Output::text(format!(
        "{}\n\n---\n\n{shown}",
        head.join("\n")
    )))
}

fn search(ctx: &Ctx, args: &Map<String, Value>) -> Result<Output, ToolError> {
    let query = arg(args, "query")?;
    let projects = match opt_arg(args, "project")? {
        Some(key) => vec![project(ctx, key)?],
        None => shared_projects(ctx),
    };
    let mut hits = Vec::new();
    let mut truncated = false;
    for p in &projects {
        let found = ctx.store.search(query, Some(&p.id));
        let room = MAX_HITS
            .saturating_sub(hits.len())
            .min(MAX_HITS_PER_PROJECT);
        truncated |= found.len() > room;
        for h in found.into_iter().take(room) {
            hits.push(json!({
                "project": p.id,
                "projectTitle": p.title,
                "sheet": h.sheet,
                "sheetTitle": h.title,
                "line": format!("{}[{}]{}", h.snippet_before, h.snippet_match, h.snippet_after),
            }));
        }
    }
    Ok(Output::json(json!({
        "query": query,
        "hits": hits,
        "truncated": truncated,
        "note": "The match is in [brackets]. Use read_sheet for the whole sheet.",
    })))
}

pub fn get_lore(ctx: &Ctx, args: &Map<String, Value>) -> Result<Output, ToolError> {
    let p = project(ctx, arg(args, "project")?)?;
    let o = ctx.store.outline(&p.id)?;
    let serial = serial_flags(&o);
    let mut out = format!("# {} — setting notes\n", p.title);
    let mut used = 0usize;
    let mut left_out = Vec::new();
    let mut any = false;
    for (f, _) in o.folders.iter().zip(&serial).filter(|(_, s)| !**s) {
        for s in &f.sheets {
            any = true;
            let text = ctx.store.sheet_text(&p.id, &s.id)?;
            let n = text.chars().count();
            if used + n > MAX_LORE_CHARS {
                left_out.push(format!(
                    "- {} / {} ({}, {n} characters)",
                    f.name, s.title, s.id
                ));
                continue;
            }
            used += n;
            out.push_str(&format!(
                "\n## {} / {}\n(sheet {})\n\n{}\n",
                f.name,
                s.title,
                s.id,
                text.trim_end()
            ));
        }
    }
    if !any {
        out.push_str(
            "\nThis project has no setting notes: every folder is a serial folder. get_outline \
             lists them.\n",
        );
    }
    if !left_out.is_empty() {
        out.push_str(&format!(
            "\n---\nLeft out to stay under {MAX_LORE_CHARS} characters (read them with read_sheet):\n{}\n",
            left_out.join("\n")
        ));
    }
    Ok(Output::text(out))
}

fn get_episode_stats(ctx: &Ctx, args: &Map<String, Value>) -> Result<Output, ToolError> {
    let p = project(ctx, arg(args, "project")?)?;
    let o = ctx.store.outline(&p.id)?;
    let picked: Vec<usize> = match opt_arg(args, "folder")? {
        Some(key) => vec![folder_by(&o, key)?.0],
        None => serial_flags(&o)
            .iter()
            .enumerate()
            .filter(|(_, s)| **s)
            .map(|(i, _)| i)
            .collect(),
    };
    let mut folders = Vec::new();
    for i in picked {
        let f = &o.folders[i];
        let st = ctx.store.folder_stats(&p.id, &f.id)?;
        let stock = ctx.store.stock(&p.id, &f.id)?;
        let next = ctx.store.next_release(&p.id, &f.id)?;
        let episodes: Vec<Value> = f
            .sheets
            .iter()
            .map(|s| {
                let e = s.episode.as_ref();
                json!({
                    "sheet": s.id,
                    "title": s.title,
                    "number": e.and_then(|e| e.number),
                    "status": status_name(e.map_or(EpisodeStatus::Draft, |e| e.status)),
                    "excluded": e.is_some_and(|e| e.excluded),
                    "publishAt": time(e.and_then(|e| e.publish_at)),
                    "chars": s.counts.chars,
                })
            })
            .collect();
        folders.push(json!({
            "id": f.id,
            "name": f.name,
            "sheets": st.sheets,
            "episodes": st.episodes,
            "totalChars": st.total.chars,
            "totalCharsNoSpace": st.total.chars_no_space,
            "totalWords": st.total.words,
            "averageChars": st.average_chars,
            "munpiaTotal": st.munpia_total,
            "novelpiaTotal": st.novelpia_total,
            "published": st.published,
            "scheduled": st.scheduled,
            "drafts": st.drafts,
            "stock": stock,
            "nextRelease": time(next),
            "rows": episodes,
        }));
    }
    Ok(Output::json(json!({
        "project": project_json(&p),
        "folders": folders,
        "notes": "Totals cover every sheet of the folder; averages and status counts cover episodes \
                  only (sheets marked excluded — prologue, side story, notice — are not episodes). \
                  Stock = episodes not yet published. Munpia/Novelpia totals count the paste-ready \
                  body without titles.",
    })))
}
