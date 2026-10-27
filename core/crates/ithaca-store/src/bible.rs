//! Story bible over a project (ADR-0010, core/API.md §Story bible): entries, the names they are
//! mentioned by, and where. Everything is computed from the live sheet text on request; nothing is
//! stored or cached.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use ithaca_ledger::Kind;
use ithaca_model::bible::{self, Matcher, NameMatch, ParsedEntry, mention_lines};
use ithaca_model::{EntryKind, Language, SheetEntry, Toc, title_of};

use crate::error::{Result, StoreError};
use crate::project::{Project, remove_cache};
use crate::textimport::{decode, path_cmp, shown, walk};
use crate::types::{Appearance, BibleEntry, ImportedEntry, Mention};
use crate::{Store, new_id};

/// One live entry sheet.
struct Entry<'a> {
    sheet: &'a str,
    folder: &'a str,
    parsed: ParsedEntry,
}

/// A live non-entry sheet, in reading order.
struct Page<'a> {
    sheet: &'a str,
    folder: &'a str,
    text: &'a str,
}

/// A project's live sheets split into entries and manuscript pages, plus a matcher over the names
/// of the matchable entries (`matched[i]` = the entry index of matcher entry `i`).
struct Index<'a> {
    entries: Vec<Entry<'a>>,
    pages: Vec<Page<'a>>,
    matcher: Matcher,
    matched: Vec<usize>,
}

impl<'a> Index<'a> {
    fn of(p: &'a Project) -> Index<'a> {
        let mut entries = Vec::new();
        let mut pages = Vec::new();
        for f in p.toc.folders.iter().filter(|f| f.deleted.is_none()) {
            for s in p.toc.live_sheets(f) {
                let text = p.chains.get(s).map_or("", |c| c.text.as_str());
                match bible::parse_entry(text) {
                    Some(parsed) => entries.push(Entry {
                        sheet: s,
                        folder: &f.id,
                        parsed,
                    }),
                    None => pages.push(Page {
                        sheet: s,
                        folder: &f.id,
                        text,
                    }),
                }
            }
        }
        let mut idx = Index {
            entries,
            pages,
            matcher: Matcher::default(),
            matched: Vec::new(),
        };
        idx.build(|_| true);
        idx
    }

    /// Rebuilds the matcher over the matchable entries `keep` accepts.
    fn build(&mut self, keep: impl Fn(&Entry) -> bool) {
        self.matched = (0..self.entries.len())
            .filter(|i| self.entries[*i].parsed.matchable && keep(&self.entries[*i]))
            .collect();
        self.matcher = Matcher::new(self.matched.iter().map(|i| {
            let e = &self.entries[*i].parsed;
            (e.name.as_str(), e.aliases.iter().map(String::as_str))
        }));
    }

    /// Matches in `text` grouped by entry index, each group in text order.
    fn by_entry(&self, text: &str) -> HashMap<usize, Vec<NameMatch>> {
        let mut out: HashMap<usize, Vec<NameMatch>> = HashMap::new();
        for m in self.matcher.find(text) {
            out.entry(self.matched[m.entry]).or_default().push(m);
        }
        out
    }
}

fn appearance(p: &Project, page: &Page, matches: &[NameMatch]) -> Appearance {
    let first = matches[0];
    Appearance {
        sheet: page.sheet.to_string(),
        title: title_of(page.text),
        folder: page.folder.to_string(),
        number: p
            .toc
            .sheets
            .get(page.sheet)
            .and_then(|e| e.episode.as_ref())
            .and_then(|e| e.number),
        count: matches.len() as u32,
        offset: first.offset,
        length: first.length,
        lines: mention_lines(page.text, matches),
    }
}

fn bible_entry(e: &Entry, last_seen: Option<Appearance>) -> BibleEntry {
    BibleEntry {
        sheet: e.sheet.to_string(),
        folder: e.folder.to_string(),
        kind: e.parsed.kind,
        name: e.parsed.name.clone(),
        aliases: e.parsed.aliases.clone(),
        fields: e.parsed.fields.clone(),
        sections: e.parsed.sections.clone(),
        matchable: e.parsed.matchable,
        last_seen,
    }
}

impl Store {
    /// Every live entry of the project, the most recently seen first (by the reading position of
    /// `last_seen`); entries never seen last; ties by name.
    pub fn bible(&self, project: &str) -> Result<Vec<BibleEntry>> {
        let p = self.project(project)?;
        let idx = Index::of(p);
        // Latest sheet first: an entry's first hit going backwards is its last_seen.
        let mut seen: Vec<Option<(usize, Appearance)>> = vec![None; idx.entries.len()];
        let mut left = idx.matched.len();
        for (pos, page) in idx.pages.iter().enumerate().rev() {
            if left == 0 {
                break;
            }
            for (e, ms) in idx.by_entry(page.text) {
                if seen[e].is_none() {
                    seen[e] = Some((pos, appearance(p, page, &ms)));
                    left -= 1;
                }
            }
        }
        let mut out: Vec<(Option<usize>, BibleEntry)> = idx
            .entries
            .iter()
            .zip(seen)
            .map(|(e, s)| match s {
                Some((pos, a)) => (Some(pos), bible_entry(e, Some(a))),
                None => (None, bible_entry(e, None)),
            })
            .collect();
        out.sort_by(|(a, x), (b, y)| {
            b.cmp(a) // Some(later) > Some(earlier) > None
                .then_with(|| x.name.cmp(&y.name))
        });
        Ok(out.into_iter().map(|(_, e)| e).collect())
    }

    /// Mentions of the project's matchable entries in `text` (the editor's text, maybe unsaved):
    /// in order, non-overlapping, longest name first, the text's own front matter skipped. When
    /// `text` is itself an entry, its own name is not reported.
    pub fn mentions_in(&self, project: &str, text: &str) -> Result<Vec<Mention>> {
        let p = self.project(project)?;
        let mut idx = Index::of(p);
        if let Some(own) = bible::parse_entry(text) {
            idx.build(|e| !(e.parsed.kind == own.kind && e.parsed.name == own.name));
        }
        Ok(idx
            .matcher
            .find(text)
            .into_iter()
            .map(|m| Mention {
                entry: idx.entries[idx.matched[m.entry]].sheet.to_string(),
                offset: m.offset,
                length: m.length,
                alias: m.alias,
            })
            .collect())
    }

    /// Every live non-entry sheet mentioning `entry`, in reading order. Empty for an entry marked
    /// `본문에서 찾지 않음`. NotFound when `entry` is not a live entry sheet of the project.
    pub fn appearances(&self, project: &str, entry: &str) -> Result<Vec<Appearance>> {
        let p = self.project(project)?;
        let idx = Index::of(p);
        let e = idx
            .entries
            .iter()
            .position(|x| x.sheet == entry)
            .ok_or(StoreError::NotFound)?;
        let mut out = Vec::new();
        for page in &idx.pages {
            if let Some(ms) = idx.by_entry(page.text).remove(&e) {
                out.push(appearance(p, page, &ms));
            }
        }
        Ok(out)
    }

    /// Creates the entries (texts from [`import_preview`]) at the end of `folder`, in order, as
    /// one table-of-contents change. All or nothing. Returns the new sheet ids.
    pub fn import_bible(
        &mut self,
        project: &str,
        folder: &str,
        entries: &[String],
    ) -> Result<Vec<String>> {
        self.writable()?;
        let p = self.project(project)?;
        if p.toc.folder(folder).is_none_or(|f| f.deleted.is_some()) {
            return Err(StoreError::NotFound);
        }
        if entries.is_empty() {
            return Ok(Vec::new());
        }
        let now = self.now();
        let mut ids: Vec<String> = Vec::with_capacity(entries.len());
        let result = (|| -> Result<()> {
            for text in entries {
                let sid = new_id();
                ids.push(sid.clone());
                self.append(project, &sid, text, Kind::Edit, now)?;
            }
            self.edit_toc(project, |t: &mut Toc, now| {
                let f = t.folder_mut(folder).expect("checked");
                f.sheets.extend(ids.iter().cloned());
                for s in &ids {
                    t.sheets.insert(s.clone(), SheetEntry::new(now));
                }
                Ok(())
            })
        })();
        if let Err(e) = result {
            // The new chains are not in the table of contents: take their files away again.
            if let Ok(p) = self.project_mut(project) {
                for s in &ids {
                    p.remove_chain_files(s);
                    remove_cache(&p.dir, s);
                }
            }
            return Err(e);
        }
        Ok(ids)
    }
}

fn is_markdown(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("md") || e.eq_ignore_ascii_case("markdown"))
}

/// A Notion export (one `.md` file, or a folder of them, recursively) as entry texts of `kind`
/// (ADR-0010 §6, rules in `ithaca_model::bible::import_markdown`). Reads only; writes nothing.
/// Files come in path order (natural order, like the text import). A missing path is NotFound.
pub fn import_preview(
    path: &Path,
    kind: EntryKind,
    language: Language,
) -> Result<Vec<ImportedEntry>> {
    let meta = fs::metadata(path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => StoreError::NotFound,
        _ => e.into(),
    })?;
    let (root, mut files): (PathBuf, Vec<PathBuf>) = if meta.is_dir() {
        let mut files = Vec::new();
        let mut skipped = Vec::new();
        walk(path, Path::new(""), &mut files, &mut skipped);
        files.retain(|f| is_markdown(f));
        (path.to_path_buf(), files)
    } else {
        let name = path.file_name().map(PathBuf::from).unwrap_or_default();
        (
            path.parent().map(Path::to_path_buf).unwrap_or_default(),
            vec![name],
        )
    };
    files.sort_by(|a, b| path_cmp(a, b));
    let mut out = Vec::with_capacity(files.len());
    for rel in files {
        let bytes = fs::read(root.join(&rel))?;
        let stem = rel
            .file_stem()
            .map(crate::textimport::nfc)
            .unwrap_or_default();
        let r = bible::import_markdown(&decode(&bytes), &stem, kind, language);
        out.push(ImportedEntry {
            source: shown(&rel),
            name: r.name,
            fields: r.fields,
            sections: r.sections,
            text: r.text,
        });
    }
    Ok(out)
}
