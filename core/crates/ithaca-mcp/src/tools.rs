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

/// (changed: qa4) `read_sheet` pages: default and largest `limit`, in characters.
pub const DEFAULT_SHEET_CHARS: usize = 20_000;
pub const MAX_SHEET_CHARS: usize = 200_000;
/// (changed: qa4) `get_lore` pages (whole sheets): default and largest `limit`, in characters.
pub const DEFAULT_LORE_CHARS: usize = 30_000;
pub const MAX_LORE_CHARS: usize = 150_000;
/// (added: qa4) Sheet rows one `get_outline` / `get_episode_stats` call returns; `offset` pages on.
pub const MAX_ROWS: usize = 500;
/// (added: qa4) Longer queries are refused (-32602); queries over the echo limit are not repeated.
pub const MAX_QUERY_CHARS: usize = 1_000;
pub const ECHO_QUERY_CHARS: usize = 200;
/// (added: qa4) JSON longer than this (bytes, compact) is sent once, in the text, after a summary
/// line, instead of twice (pretty text + `structuredContent`).
pub const LARGE_OUTPUT_BYTES: usize = 8_000;
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
    /// Small: pretty JSON in the text and the same value as `structuredContent`. Large: the
    /// summary line and the compact JSON, in the text only.
    fn json(summary: String, v: Value) -> Output {
        let compact = v.to_string();
        if compact.len() > LARGE_OUTPUT_BYTES {
            return Output {
                text: format!("{summary}\n\n{compact}"),
                structured: None,
            };
        }
        Output {
            text: serde_json::to_string_pretty(&v).unwrap_or(compact),
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
/// Arguments the protocol refuses (-32602) before the tool runs (added: qa4).
type Check = fn(&Map<String, Value>) -> Result<(), String>;

pub struct Tool {
    pub name: &'static str,
    pub title: &'static str,
    pub description: &'static str,
    pub access: Access,
    pub run: Run,
    pub check: Check,
    schema: fn() -> Value,
}

fn project_prop() -> Value {
    json!({ "type": "string", "description": "Project id from list_projects, or its exact title." })
}

fn offset_prop(what: &str) -> Value {
    json!({ "type": "integer", "minimum": 0, "description": what })
}

fn no_check(_: &Map<String, Value>) -> Result<(), String> {
    Ok(())
}

fn check_search(args: &Map<String, Value>) -> Result<(), String> {
    match args.get("query").and_then(Value::as_str) {
        Some(q) if q.chars().count() > MAX_QUERY_CHARS => {
            Err(format!("query is longer than {MAX_QUERY_CHARS} characters"))
        }
        _ => Ok(()),
    }
}

pub const TOOLS: &[Tool] = &[
    Tool {
        name: "list_projects",
        title: "List projects",
        description: "List the writing projects the writer shared with Claude: id, title, language, \
            number of sheets, total length and length goal. Call this first.",
        access: Access::Read,
        run: list_projects,
        check: no_check,
        schema: || json!({ "type": "object", "additionalProperties": false }),
    },
    Tool {
        name: "get_outline",
        title: "Project outline",
        description: "The folders of a project in order and the sheets in each, in serial order: \
            sheet id, title, length, and episode information (number, status, publish time, \
            platform) for serial folders. Trashed sheets are left out. At most 500 sheet rows per \
            call; when `page.truncated` is true, call again with `offset` = `page.nextOffset`.",
        access: Access::Read,
        run: get_outline,
        check: no_check,
        schema: || {
            json!({ "type": "object", "properties": {
                        "project": project_prop(),
                        "offset": offset_prop("Sheet rows to skip, counted across folders in order. Default 0.") },
                    "required": ["project"], "additionalProperties": false })
        },
    },
    Tool {
        name: "read_sheet",
        title: "Read a sheet",
        description: "The text of one sheet (Markdown as the writer typed it; the first line is \
            the title), with its folder, length counts (Ithaca, Munpia, Novelpia) and episode \
            information. Long sheets come in pages of `limit` characters (default 20000): the \
            `Page:` line says whether the text is truncated and the `nextOffset` to ask for next.",
        access: Access::Read,
        run: read_sheet,
        check: no_check,
        schema: || {
            json!({ "type": "object", "properties": {
                        "project": project_prop(),
                        "sheet": { "type": "string", "description": "Sheet id from get_outline or search, or its exact title." },
                        "offset": offset_prop("First character to return (0-based). Default 0."),
                        "limit": { "type": "integer", "minimum": 1, "maximum": MAX_SHEET_CHARS,
                                   "description": "Characters to return. Default 20000, at most 200000." } },
                    "required": ["project", "sheet"], "additionalProperties": false })
        },
    },
    Tool {
        name: "search",
        title: "Search text",
        description: "Case-insensitive plain-text search over the shared projects (or one project). \
            Returns up to 100 hits with the sheet and the surrounding line. Queries are at most \
            1000 characters.",
        access: Access::Read,
        run: search,
        check: check_search,
        schema: || {
            json!({ "type": "object", "properties": {
                        "query": { "type": "string", "maxLength": MAX_QUERY_CHARS, "description": "Text to find, as written (Korean or English)." },
                        "project": { "type": "string", "description": "Optional: limit to this project (id or exact title)." } },
                    "required": ["query"], "additionalProperties": false })
        },
    },
    Tool {
        name: "get_lore",
        title: "Setting notes",
        description: "The sheets of the project's non-serial folders (setting notes, characters, \
            world-building, plot notes) in one text, each under a heading with its folder and \
            sheet id. Paged by whole sheets, about `limit` characters (default 30000) per call: \
            the `Page:` line gives `nextOffset` (a sheet index) when more notes follow.",
        access: Access::Read,
        run: get_lore,
        check: no_check,
        schema: || {
            json!({ "type": "object", "properties": {
                        "project": project_prop(),
                        "offset": offset_prop("Setting-note sheets to skip. Default 0."),
                        "limit": { "type": "integer", "minimum": 1, "maximum": MAX_LORE_CHARS,
                                   "description": "Characters per page. Default 30000, at most 150000." } },
                    "required": ["project"], "additionalProperties": false })
        },
    },
    Tool {
        name: "get_episode_stats",
        title: "Episode statistics",
        description: "Serial statistics per folder: episodes, total and average length, Munpia and \
            Novelpia totals, how many are published / scheduled / drafts, stock (episodes written \
            but not yet published), the next scheduled release, and one row per episode (at most \
            500 rows per call; when `page.truncated` is true, call again with `offset` = \
            `page.nextOffset`).",
        access: Access::Read,
        run: get_episode_stats,
        check: no_check,
        schema: || {
            json!({ "type": "object", "properties": {
                        "project": project_prop(),
                        "folder": { "type": "string", "description": "Optional: folder id or name. Default: every serial folder." },
                        "offset": offset_prop("Episode rows to skip, counted across the folders. Default 0.") },
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

/// A non-negative integer argument (a whole-number float is accepted too).
fn opt_uint(args: &Map<String, Value>, key: &str) -> Result<Option<usize>, ToolError> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => v
            .as_u64()
            .or_else(|| {
                v.as_f64()
                    .filter(|f| *f >= 0.0 && f.fract() == 0.0 && *f < 1e15)
                    .map(|f| f as u64)
            })
            .map(|n| Some(usize::try_from(n).unwrap_or(usize::MAX)))
            .ok_or_else(|| ToolError(format!("Argument {key} must be a non-negative integer."))),
    }
}

/// `limit` within `1..=max`, `default` when absent.
fn limit_arg(args: &Map<String, Value>, default: usize, max: usize) -> Result<usize, ToolError> {
    match opt_uint(args, "limit")? {
        None => Ok(default),
        Some(0) => Err(ToolError("Argument limit must be at least 1.".into())),
        Some(n) => Ok(n.min(max)),
    }
}

/// Which slice of the rows a paged list returns, and the `page` object describing it.
fn row_page(offset: usize, total: usize) -> (std::ops::Range<usize>, Value) {
    let start = offset.min(total);
    let end = (start + MAX_ROWS).min(total);
    let truncated = end < total;
    (
        start..end,
        json!({
            "offset": start,
            "returned": end - start,
            "total": total,
            "truncated": truncated,
            "nextOffset": if truncated { json!(end) } else { Value::Null },
        }),
    )
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

/// Byte index of character `n` of `s` (its length when `n` is past the end).
fn byte_at(s: &str, n: usize) -> usize {
    s.char_indices().nth(n).map_or(s.len(), |(i, _)| i)
}

/// Up to `limit` characters of `s` from character `offset`, and the character offset of the rest
/// when there is more. A cut prefers the end of a line in the second half of the page.
fn page(s: &str, offset: usize, limit: usize) -> (&str, Option<usize>) {
    let start = byte_at(s, offset);
    let rest = &s[start..];
    let end = byte_at(rest, limit);
    if end == rest.len() {
        return (rest, None);
    }
    let mut shown = &rest[..end];
    if let Some(nl) = shown.rfind('\n')
        && shown[..nl].chars().count() >= limit / 2
    {
        shown = &shown[..=nl];
    }
    (shown, Some(offset + shown.chars().count()))
}

// ── Tools ─────────────────────────────────────────────────────────────

fn list_projects(ctx: &Ctx, _: &Map<String, Value>) -> Result<Output, ToolError> {
    let ps: Vec<Value> = shared_projects(ctx).iter().map(project_json).collect();
    let note = if ps.is_empty() {
        "The writer has not shared any project with Claude yet (Ithaca → Settings → Claude)."
    } else {
        ""
    };
    let summary = format!("{} shared projects.", ps.len());
    Ok(Output::json(
        summary,
        json!({ "projects": ps, "note": note }),
    ))
}

pub fn get_outline(ctx: &Ctx, args: &Map<String, Value>) -> Result<Output, ToolError> {
    let p = project(ctx, arg(args, "project")?)?;
    let offset = opt_uint(args, "offset")?.unwrap_or(0);
    let o = ctx.store.outline(&p.id)?;
    let serial = serial_flags(&o);
    let total: usize = o.folders.iter().map(|f| f.sheets.len()).sum();
    let (range, pg) = row_page(offset, total);
    let mut first = 0usize; // row index of the folder's first sheet
    let folders: Vec<Value> = o
        .folders
        .iter()
        .zip(&serial)
        .map(|(f, serial)| {
            let (a, b) = (first, first + f.sheets.len());
            first = b;
            let (from, to) = (range.start.clamp(a, b) - a, range.end.clamp(a, b) - a);
            json!({
                "id": f.id,
                "name": f.name,
                "kind": if *serial { "serial" } else { "notes" },
                "sheetCount": f.sheets.len(),
                "sheets": f.sheets[from..to].iter().map(sheet_row).collect::<Vec<_>>(),
            })
        })
        .collect();
    let mut v = json!({ "project": project_json(&p), "folders": folders, "page": pg });
    if pg["truncated"] == true {
        v["note"] = json!(format!(
            "Only {MAX_ROWS} sheet rows are listed per call. Call get_outline with offset {} for \
             the next ones.",
            range.end
        ));
    }
    let summary = format!(
        "Outline of \"{}\": {} folders, {total} sheets (rows {}–{} shown).",
        p.title,
        o.folders.len(),
        range.start,
        range.end
    );
    Ok(Output::json(summary, v))
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
    let offset = opt_uint(args, "offset")?.unwrap_or(0);
    let limit = limit_arg(args, DEFAULT_SHEET_CHARS, MAX_SHEET_CHARS)?;
    let text = ctx.store.sheet_text(&p.id, &s.id)?;
    let total = text.chars().count();
    if offset > total {
        return Err(ToolError(format!(
            "offset {offset} is past the end of the sheet ({total} characters)."
        )));
    }
    let body = ithaca_model::platform_body(&text);
    let (shown, next) = page(&text, offset, limit);
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
    head.push(format!(
        "Page: {}",
        json!({
            "offset": offset,
            "returned": shown.chars().count(),
            "totalChars": total,
            "truncated": next.is_some(),
            "nextOffset": next,
        })
    ));
    if let Some(n) = next {
        head.push(format!(
            "Note: the text continues. Call read_sheet with offset {n} for the next part."
        ));
    }
    Ok(Output::text(format!(
        "{}\n\n---\n\n{shown}",
        head.join("\n")
    )))
}

fn search(ctx: &Ctx, args: &Map<String, Value>) -> Result<Output, ToolError> {
    let query = arg(args, "query")?;
    if let Err(m) = check_search(args) {
        return Err(ToolError(m));
    }
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
    let n = query.chars().count();
    let mut v = json!({
        "hits": hits,
        "truncated": truncated,
        "note": "The match is in [brackets]. Use read_sheet for the whole sheet.",
    });
    if n <= ECHO_QUERY_CHARS {
        v["query"] = json!(query);
    } else {
        v["queryChars"] = json!(n);
    }
    let summary = format!(
        "{} hits{}.",
        hits.len(),
        if truncated { " (more not shown)" } else { "" }
    );
    Ok(Output::json(summary, v))
}

pub fn get_lore(ctx: &Ctx, args: &Map<String, Value>) -> Result<Output, ToolError> {
    let p = project(ctx, arg(args, "project")?)?;
    let offset = opt_uint(args, "offset")?.unwrap_or(0);
    let limit = limit_arg(args, DEFAULT_LORE_CHARS, MAX_LORE_CHARS)?;
    let o = ctx.store.outline(&p.id)?;
    let serial = serial_flags(&o);
    let lore: Vec<(&FolderInfo, &SheetSummary)> = o
        .folders
        .iter()
        .zip(&serial)
        .filter(|(_, s)| !**s)
        .flat_map(|(f, _)| f.sheets.iter().map(move |s| (f, s)))
        .collect();
    let mut out = format!("# {} — setting notes\n", p.title);
    if lore.is_empty() {
        out.push_str(
            "\nThis project has no setting notes: every folder is a serial folder. get_outline \
             lists them.\n",
        );
        return Ok(Output::text(out));
    }
    if offset >= lore.len() {
        return Err(ToolError(format!(
            "offset {offset} is past the last setting note ({} sheets).",
            lore.len()
        )));
    }
    let mut used = 0usize;
    let mut body = String::new();
    let mut next = None;
    for (i, (f, s)) in lore.iter().enumerate().skip(offset) {
        let text = ctx.store.sheet_text(&p.id, &s.id)?;
        let text = text.trim_end();
        let n = text.chars().count();
        if used > 0 && used + n > limit {
            next = Some(i);
            break;
        }
        // The first sheet of a page always goes in; one longer than the page is cut.
        let (shown, rest) = page(text, 0, limit);
        used += shown.chars().count();
        body.push_str(&format!(
            "\n## {} / {}\n(sheet {})\n\n{}\n",
            f.name,
            s.title,
            s.id,
            shown.trim_end()
        ));
        if let Some(r) = rest {
            body.push_str(&format!(
                "\n(This sheet has {n} characters; read the rest with read_sheet, sheet {}, \
                 offset {r}.)\n",
                s.id
            ));
        }
    }
    let end = next.unwrap_or(lore.len());
    out.push_str(&format!(
        "Page: {}\n",
        json!({
            "offset": offset,
            "returned": end - offset,
            "totalSheets": lore.len(),
            "chars": used,
            "truncated": next.is_some(),
            "nextOffset": next,
        })
    ));
    out.push_str(&body);
    if let Some(n) = next {
        let left: Vec<String> = lore[n..]
            .iter()
            .take(MAX_ROWS)
            .map(|(f, s)| {
                format!(
                    "- {} / {} ({}, {} characters)",
                    f.name, s.title, s.id, s.counts.chars
                )
            })
            .collect();
        out.push_str(&format!(
            "\n---\nMore setting notes follow: call get_lore with offset {n}, or read_sheet for \
             one of them:\n{}\n",
            left.join("\n")
        ));
    }
    Ok(Output::text(out))
}

fn get_episode_stats(ctx: &Ctx, args: &Map<String, Value>) -> Result<Output, ToolError> {
    let p = project(ctx, arg(args, "project")?)?;
    let offset = opt_uint(args, "offset")?.unwrap_or(0);
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
    let total: usize = picked.iter().map(|i| o.folders[*i].sheets.len()).sum();
    let (range, pg) = row_page(offset, total);
    let mut first = 0usize;
    let mut folders = Vec::new();
    for i in picked {
        let f = &o.folders[i];
        let (a, b) = (first, first + f.sheets.len());
        first = b;
        let (from, to) = (range.start.clamp(a, b) - a, range.end.clamp(a, b) - a);
        let st = ctx.store.folder_stats(&p.id, &f.id)?;
        let stock = ctx.store.stock(&p.id, &f.id)?;
        let next = ctx.store.next_release(&p.id, &f.id)?;
        let episodes: Vec<Value> = f.sheets[from..to]
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
    let summary = format!(
        "Episode statistics of \"{}\": {} folders, {total} rows (rows {}–{} shown).",
        p.title,
        folders.len(),
        range.start,
        range.end
    );
    let truncated = pg["truncated"] == true;
    let mut v = json!({
        "project": project_json(&p),
        "folders": folders,
        "page": pg,
        "notes": "Totals cover every sheet of the folder; averages and status counts cover episodes \
                  only (sheets marked excluded — prologue, side story, notice — are not episodes). \
                  Stock = episodes not yet published. Munpia/Novelpia totals count the paste-ready \
                  body without titles.",
    });
    if truncated {
        v["note"] = json!(format!(
            "Only {MAX_ROWS} episode rows are listed per call; totals cover every row. Call \
             get_episode_stats with offset {} for the next ones.",
            range.end
        ));
    }
    Ok(Output::json(summary, v))
}
