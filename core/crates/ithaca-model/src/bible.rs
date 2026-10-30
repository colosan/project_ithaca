//! Story bible entries (ADR-0010): sheets whose front matter names a `종류` / `kind`, and the name
//! index the editor and the Claude connector share. Plain text in, plain data out; no IO.
//!
//! - Front matter: the first line is `---`, then `key: value` lines, then a `---` line. Only a
//!   front matter with a known `종류` / `kind` makes an entry; any other sheet starting with `---`
//!   (a scene break) is an ordinary sheet and nothing about it changes.
//! - Offsets handed out are UTF-16 code units (NSTextView), counted from the start of the text.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

use crate::Language;
use crate::text::{is_heading, js_trim, strip_heading_mark};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EntryKind {
    /// `인물` / `character`
    Character,
    /// `장소` / `place`
    Place,
    /// `집단` / `group` (`세력` / `faction` from 0.6.0 still read as this)
    Group,
    /// `용어` / `term`
    Term,
}

impl EntryKind {
    pub const ALL: [EntryKind; 4] = [
        EntryKind::Character,
        EntryKind::Place,
        EntryKind::Group,
        EntryKind::Term,
    ];

    /// The `종류` / `kind` value, case-insensitive, Korean or English.
    pub fn parse(value: &str) -> Option<EntryKind> {
        let v = js_trim(value).to_lowercase();
        Some(match v.as_str() {
            "인물" | "character" => EntryKind::Character,
            "장소" | "place" => EntryKind::Place,
            "집단" | "group" | "세력" | "faction" => EntryKind::Group,
            "용어" | "term" => EntryKind::Term,
            _ => return None,
        })
    }

    /// The value written into a new entry.
    pub fn label(self, language: Language) -> &'static str {
        match (self, language) {
            (EntryKind::Character, Language::Ko) => "인물",
            (EntryKind::Place, Language::Ko) => "장소",
            (EntryKind::Group, Language::Ko) => "집단",
            (EntryKind::Term, Language::Ko) => "용어",
            (EntryKind::Character, Language::En) => "character",
            (EntryKind::Place, Language::En) => "place",
            (EntryKind::Group, Language::En) => "group",
            (EntryKind::Term, Language::En) => "term",
        }
    }
}

/// One `key: value` line of the front matter (values may be empty).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntryField {
    pub key: String,
    pub value: String,
}

/// One `## title` section: the title without the marks, the text under it trimmed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntrySection {
    pub title: String,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedEntry {
    pub kind: EntryKind,
    pub name: String,
    pub aliases: Vec<String>,
    /// Front matter in order, without `종류` / `별칭` / `본문에서 찾지 않음` (and their English keys).
    pub fields: Vec<EntryField>,
    pub sections: Vec<EntrySection>,
    /// False when `본문에서 찾지 않음` / `no-match` is `예 | yes | true`.
    pub matchable: bool,
    /// UTF-16 offset of the first character after the front matter.
    pub body_start: u32,
}

// ── Keys and templates ───────────────────────────────────────────────

const KIND_KEYS: [&str; 2] = ["종류", "kind"];
const ALIAS_KEYS: [&str; 3] = ["별칭", "aliases", "alias"];
const NO_MATCH_KEYS: [&str; 2] = ["본문에서 찾지 않음", "no-match"];

fn key_is(key: &str, keys: &[&str]) -> bool {
    let k = key.to_lowercase();
    keys.iter().any(|x| *x == k)
}

/// The front matter keys of a new entry after `종류` (the first is always the aliases key).
pub fn field_keys(kind: EntryKind, language: Language) -> &'static [&'static str] {
    match (kind, language) {
        (EntryKind::Character, Language::Ko) => &["별칭", "나이", "소속", "능력", "상태", "외모"],
        (EntryKind::Place, Language::Ko) => &["별칭", "속한 곳"],
        (EntryKind::Group, Language::Ko) => &["별칭", "대표"],
        (EntryKind::Term, Language::Ko) => &["별칭"],
        (EntryKind::Character, Language::En) => &[
            "aliases",
            "age",
            "affiliation",
            "abilities",
            "status",
            "appearance",
        ],
        (EntryKind::Place, Language::En) => &["aliases", "part of"],
        (EntryKind::Group, Language::En) => &["aliases", "leader"],
        (EntryKind::Term, Language::En) => &["aliases"],
    }
}

/// The `## ` sections of a new entry, in order. The last one is always the notes section.
pub fn section_titles(kind: EntryKind, language: Language) -> &'static [&'static str] {
    match (kind, language) {
        (EntryKind::Character, Language::Ko) => {
            &["한 줄 소개", "성격", "말투", "호칭", "반응", "메모"]
        }
        (EntryKind::Place, Language::Ko) => &["한 줄 소개", "감각", "규칙", "메모"],
        (EntryKind::Group, Language::Ko) => &["한 줄 소개", "구성원", "목표", "관계", "메모"],
        (EntryKind::Term, Language::Ko) => &["뜻", "메모"],
        (EntryKind::Character, Language::En) => &[
            "Summary",
            "Personality",
            "Voice",
            "Forms of address",
            "Reactions",
            "Notes",
        ],
        (EntryKind::Place, Language::En) => &["Summary", "Senses", "Rules", "Notes"],
        (EntryKind::Group, Language::En) => &["Summary", "Members", "Goals", "Relations", "Notes"],
        (EntryKind::Term, Language::En) => &["Meaning", "Notes"],
    }
}

fn kind_key(language: Language) -> &'static str {
    match language {
        Language::Ko => "종류",
        Language::En => "kind",
    }
}

/// The text of a new entry: front matter with empty values, `# name`, empty sections.
pub fn entry_template(kind: EntryKind, name: &str, language: Language) -> String {
    let mut out = format!("---\n{}: {}\n", kind_key(language), kind.label(language));
    for k in field_keys(kind, language) {
        out.push_str(k);
        out.push_str(":\n");
    }
    out.push_str("---\n# ");
    out.push_str(js_trim(name));
    out.push('\n');
    for t in section_titles(kind, language) {
        out.push_str("\n## ");
        out.push_str(t);
        out.push('\n');
    }
    out
}

// ── Front matter ──────────────────────────────────────────────────────

/// A `---` … `---` block at the very start of a text, whatever its keys.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrontMatter<'a> {
    /// `key: value` lines in order, both trimmed. Lines without a colon are left out.
    pub pairs: Vec<(&'a str, &'a str)>,
    /// Byte offset just after the closing `---` line (and its line break).
    pub end: usize,
}

fn is_fence(line: &str) -> bool {
    line.trim_end_matches('\r').trim_end_matches([' ', '\t']) == "---"
}

/// Splits `key: value` at the first ASCII or full-width colon.
fn split_pair(line: &str) -> Option<(&str, &str)> {
    let i = line.find([':', '：'])?;
    let colon = line[i..].chars().next().map_or(1, char::len_utf8);
    let key = js_trim(&line[..i]);
    (!key.is_empty()).then(|| (key, js_trim(&line[i + colon..])))
}

/// The front matter block, if the text starts with a `---` line and a later `---` line closes it.
pub fn front_matter(text: &str) -> Option<FrontMatter<'_>> {
    let first_end = text.find('\n')?;
    if !is_fence(&text[..first_end]) {
        return None;
    }
    let mut pos = first_end + 1;
    let mut pairs = Vec::new();
    while pos <= text.len() {
        let end = text[pos..].find('\n').map_or(text.len(), |i| pos + i);
        let line = &text[pos..end];
        if is_fence(line) {
            return Some(FrontMatter {
                pairs,
                end: (end + 1).min(text.len()),
            });
        }
        if let Some(p) = split_pair(line.trim_end_matches('\r')) {
            pairs.push(p);
        }
        if end == text.len() {
            break;
        }
        pos = end + 1;
    }
    None
}

/// The kind an entry's front matter names; `None` for every other sheet.
pub fn entry_kind(text: &str) -> Option<EntryKind> {
    entry_front_matter(text).map(|(k, _)| k)
}

fn entry_front_matter(text: &str) -> Option<(EntryKind, FrontMatter<'_>)> {
    if !text.starts_with("---") {
        return None;
    }
    let fm = front_matter(text)?;
    let kind = fm
        .pairs
        .iter()
        .find(|(k, _)| key_is(k, &KIND_KEYS))
        .and_then(|(_, v)| EntryKind::parse(v))?;
    Some((kind, fm))
}

/// Byte offset where the manuscript starts: after an entry's front matter, else 0.
pub fn body_offset(text: &str) -> usize {
    entry_front_matter(text).map_or(0, |(_, fm)| fm.end)
}

/// The text without an entry's front matter (ADR-0010 §2) and without its `작가의 말`
/// (added: note, [`crate::note`]). Any other text is returned whole.
pub fn body_of(text: &str) -> &str {
    let start = body_offset(text);
    &text[start..crate::note::note_start(text, start)]
}

fn utf16_len(s: &str) -> u32 {
    s.encode_utf16().count() as u32
}

fn is_yes(v: &str) -> bool {
    matches!(v.to_lowercase().as_str(), "예" | "네" | "yes" | "true")
}

/// `,` (also `，` and `、`) separated, trimmed, empty pieces dropped.
fn split_aliases(v: &str) -> Vec<String> {
    v.split([',', '，', '、'])
        .map(js_trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

/// `## ` exactly (not `#` or `###`), followed by a space.
fn section_title(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("##")?;
    if rest.starts_with('#') || !rest.starts_with([' ', '\t']) {
        return None;
    }
    Some(js_trim(rest))
}

fn is_h1(line: &str) -> bool {
    line.strip_prefix('#')
        .is_some_and(|r| r.starts_with([' ', '\t']))
}

/// An entry sheet; `None` when the text has no front matter with a known `종류` / `kind`.
pub fn parse_entry(text: &str) -> Option<ParsedEntry> {
    let (kind, fm) = entry_front_matter(text)?;
    let mut aliases = Vec::new();
    let mut matchable = true;
    let mut fields = Vec::new();
    for (k, v) in &fm.pairs {
        if key_is(k, &KIND_KEYS) {
            continue;
        } else if key_is(k, &ALIAS_KEYS) {
            aliases.extend(split_aliases(v));
        } else if key_is(k, &NO_MATCH_KEYS) {
            matchable &= !is_yes(v);
        } else {
            fields.push(EntryField {
                key: k.to_string(),
                value: v.to_string(),
            });
        }
    }
    let body = &text[fm.end..];
    let lines: Vec<&str> = body.split('\n').map(|l| l.trim_end_matches('\r')).collect();
    let name = lines
        .iter()
        .find(|l| is_h1(l))
        .or_else(|| lines.iter().find(|l| !js_trim(l).is_empty()))
        .map(|l| js_trim(strip_heading_mark(l)).to_string())
        .unwrap_or_default();
    let mut sections: Vec<EntrySection> = Vec::new();
    let mut current: Option<(String, Vec<&str>)> = None;
    let flush = |cur: Option<(String, Vec<&str>)>, out: &mut Vec<EntrySection>| {
        if let Some((title, body)) = cur {
            out.push(EntrySection {
                title,
                body: js_trim(&body.join("\n")).to_string(),
            });
        }
    };
    for l in &lines {
        if let Some(t) = section_title(l) {
            flush(current.take(), &mut sections);
            current = Some((t.to_string(), Vec::new()));
        } else if let Some((_, b)) = current.as_mut() {
            b.push(l);
        }
    }
    flush(current, &mut sections);
    aliases.dedup();
    Some(ParsedEntry {
        kind,
        name,
        aliases,
        fields,
        sections,
        matchable,
        body_start: utf16_len(&text[..fm.end]),
    })
}

// ── Name matching ─────────────────────────────────────────────────────

/// Particles and vocative / copula endings allowed right after a name (ADR-0010 §3). After one of
/// these (or two in a row, e.g. `에게` + `도`) the text must end or go on with a non-letter.
pub const JOSA: &[&str] = &[
    "이",
    "가",
    "은",
    "는",
    "을",
    "를",
    "의",
    "에",
    "에게",
    "에게서",
    "한테",
    "한테서",
    "께",
    "께서",
    "도",
    "만",
    "와",
    "과",
    "랑",
    "이랑",
    "하고",
    "아",
    "야",
    "이여",
    "여",
    "이가",
    "이는",
    "이를",
    "이의",
    "이도",
    "이와",
    "이만",
    "이에게",
    "이한테",
    "이다",
    "이야",
    "이에요",
    "예요",
    "이요",
    "처럼",
    "보다",
    "부터",
    "까지",
    "에서",
    "으로",
    "로",
    "이란",
    "란",
    "이나",
    "나",
    "이며",
    "며",
    "이고",
    "고",
    "이네",
    "네",
    "이지",
    "지",
    "님",
    "씨",
];

/// Copula stems a name may carry with any continuation (`서윤이었다`, `벼리였고`, `서윤이라는`).
pub const JOSA_OPEN: &[&str] = &["이었", "였", "이라", "이라서", "이라고"];

/// Letters and digits of any script (Hangul included): a name next to one is inside a word.
fn is_word_char(c: char) -> bool {
    c.is_alphanumeric()
}

fn boundary(rest: &str) -> bool {
    rest.chars().next().is_none_or(|c| !is_word_char(c))
}

/// What may follow a name: the end, a non-letter, an allowed particle (at most two in a row)
/// and then a non-letter, or an open copula stem.
pub fn suffix_ok(rest: &str) -> bool {
    if boundary(rest) || JOSA_OPEN.iter().any(|j| rest.starts_with(j)) {
        return true;
    }
    JOSA.iter().any(|j| {
        rest.strip_prefix(j).is_some_and(|r| {
            boundary(r)
                || JOSA
                    .iter()
                    .any(|j2| r.strip_prefix(j2).is_some_and(boundary))
        })
    })
}

/// One name the matcher looks for.
#[derive(Debug, Clone)]
struct Pattern {
    text: String,
    entry: usize,
    alias: bool,
}

/// A name found in a text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NameMatch {
    /// Index of the entry in the list the matcher was built from.
    pub entry: usize,
    /// Byte range of the name (particle excluded).
    pub start: usize,
    pub end: usize,
    /// UTF-16 offset and length of the name.
    pub offset: u32,
    pub length: u32,
    pub alias: bool,
}

/// Names (and aliases) of several entries, looked up by their first character, longest first.
#[derive(Debug, Clone, Default)]
pub struct Matcher {
    by_first: HashMap<char, Vec<Pattern>>,
}

/// Names shorter than this (in graphemes) are never matched: one-syllable names hit everywhere.
pub const MIN_NAME_GRAPHEMES: usize = 2;

impl Matcher {
    /// `entries[i]` = (name, aliases). The same spelling under two entries goes to the first.
    pub fn new<'a, I, A>(entries: I) -> Matcher
    where
        I: IntoIterator<Item = (&'a str, A)>,
        A: IntoIterator<Item = &'a str>,
    {
        let mut by_first: HashMap<char, Vec<Pattern>> = HashMap::new();
        let mut seen = std::collections::HashSet::new();
        for (i, (name, aliases)) in entries.into_iter().enumerate() {
            let names =
                std::iter::once((name, false)).chain(aliases.into_iter().map(|a| (a, true)));
            for (n, alias) in names {
                let n = js_trim(n);
                if n.graphemes(true).count() < MIN_NAME_GRAPHEMES || !seen.insert(n.to_string()) {
                    continue;
                }
                let first = n.chars().next().expect("non-empty");
                by_first.entry(first).or_default().push(Pattern {
                    text: n.to_string(),
                    entry: i,
                    alias,
                });
            }
        }
        for v in by_first.values_mut() {
            // Longest first; ties keep the order given (stable sort).
            v.sort_by_key(|p| std::cmp::Reverse(p.text.len()));
        }
        Matcher { by_first }
    }

    pub fn is_empty(&self) -> bool {
        self.by_first.is_empty()
    }

    /// Every name in `text[from..]`, in order, non-overlapping. Offsets count from the start of `text`.
    pub fn find_from(&self, text: &str, from: usize) -> Vec<NameMatch> {
        let mut out = Vec::new();
        if self.by_first.is_empty() {
            return out;
        }
        let mut utf16 = utf16_len(&text[..from]) as usize;
        let mut prev: Option<char> = text[..from].chars().next_back();
        let mut i = from;
        let bytes_len = text.len();
        while i < bytes_len {
            let c = text[i..].chars().next().expect("in bounds");
            if prev.is_none_or(|p| !is_word_char(p))
                && let Some(cands) = self.by_first.get(&c)
            {
                let rest = &text[i..];
                if let Some(p) = cands
                    .iter()
                    .find(|p| rest.starts_with(&p.text) && suffix_ok(&rest[p.text.len()..]))
                {
                    let len16 = utf16_len(&p.text);
                    out.push(NameMatch {
                        entry: p.entry,
                        start: i,
                        end: i + p.text.len(),
                        offset: utf16 as u32,
                        length: len16,
                        alias: p.alias,
                    });
                    utf16 += len16 as usize;
                    i += p.text.len();
                    prev = p.text.chars().next_back();
                    continue;
                }
            }
            utf16 += c.len_utf16();
            i += c.len_utf8();
            prev = Some(c);
        }
        out
    }

    /// Every name in the text, skipping an entry's own front matter.
    pub fn find(&self, text: &str) -> Vec<NameMatch> {
        self.find_from(text, body_offset(text))
    }
}

// ── Appearance lines ──────────────────────────────────────────────────

/// Longest line handed out, in characters (an ellipsis included).
pub const LINE_CHARS: usize = 120;
/// Lines per appearance.
pub const MAX_LINES: usize = 3;

fn is_dialogue(line: &str) -> bool {
    js_trim(line).starts_with(['"', '“', '「', '『', '\'', '‘', '-', '―'])
}

/// The line around one match, trimmed, at most [`LINE_CHARS`] characters: a long line is cut to a
/// window around the name, with `…` where it was cut.
fn line_around(text: &str, m: &NameMatch) -> (usize, String) {
    let ls = text[..m.start].rfind('\n').map_or(0, |n| n + 1);
    let le = text[m.end..].find('\n').map_or(text.len(), |n| m.end + n);
    let line = js_trim(&text[ls..le]);
    let chars: Vec<char> = line.chars().collect();
    if chars.len() <= LINE_CHARS {
        return (ls, line.to_string());
    }
    // Character index of the name inside the trimmed line.
    let lead = text[ls..le].len()
        - text[ls..le]
            .trim_start_matches(crate::text::is_js_space)
            .len();
    let at = text[ls + lead..m.start].chars().count();
    let room = LINE_CHARS - 2;
    let start = at.saturating_sub(room / 3).min(chars.len() - room);
    let end = (start + room).min(chars.len());
    let mut s = String::new();
    if start > 0 {
        s.push('…');
    }
    s.extend(&chars[start..end]);
    if end < chars.len() {
        s.push('…');
    }
    (ls, s)
}

/// Up to [`MAX_LINES`] lines that mention an entry: dialogue lines (starting with a quote mark or
/// dash) first; when none is dialogue, the first lines that mention it. `matches` are the entry's.
pub fn mention_lines(text: &str, matches: &[NameMatch]) -> Vec<String> {
    let mut lines: Vec<(usize, String, bool)> = Vec::new();
    for m in matches {
        let (start, l) = line_around(text, m);
        if lines.iter().any(|(s, _, _)| *s == start) {
            continue;
        }
        let ls_end = text[start..].find('\n').map_or(text.len(), |n| start + n);
        lines.push((start, l, is_dialogue(&text[start..ls_end])));
    }
    let dialogue: Vec<String> = lines
        .iter()
        .filter(|l| l.2)
        .take(MAX_LINES)
        .map(|l| l.1.clone())
        .collect();
    if !dialogue.is_empty() {
        return dialogue;
    }
    lines.into_iter().take(MAX_LINES).map(|l| l.1).collect()
}

// ── Notion import ─────────────────────────────────────────────────────

/// One imported Markdown file turned into entry text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportedText {
    pub name: String,
    /// `key: value` lines taken into the front matter.
    pub fields: u32,
    /// Sections that got text.
    pub sections: u32,
    pub text: String,
}

/// Cuts Notion's ` <32 hex>` id from a page or file name.
pub fn strip_notion_id(s: &str) -> &str {
    let t = js_trim(s);
    if let Some(i) = t.len().checked_sub(33)
        && t.is_char_boundary(i)
        && t[i..].starts_with(' ')
        && t[i + 1..].chars().all(|c| c.is_ascii_hexdigit())
    {
        return js_trim(&t[..i]);
    }
    t
}

/// A Notion property line: a short key without sentence marks, a colon, a value.
fn property(line: &str) -> Option<(&str, &str)> {
    let (k, v) = split_pair(line)?;
    let bad = |c: char| {
        matches!(
            c,
            '#' | '.' | '?' | '!' | '"' | '“' | '”' | '「' | '『' | '(' | '[' | '>' | '*' | '`'
        )
    };
    if k.chars().count() > 30
        || k.chars().any(bad)
        || k.starts_with(['-', '+'])
        || k.contains("://")
    {
        return None;
    }
    Some((k, v))
}

fn known_section(kind: EntryKind, title: &str) -> Option<usize> {
    let t = js_trim(title).to_lowercase();
    [Language::Ko, Language::En].iter().find_map(|l| {
        section_titles(kind, *l)
            .iter()
            .position(|s| s.to_lowercase() == t)
    })
}

/// A Notion page export (`# title`, property lines, `##` sections) as the text of a new entry of
/// `kind` (ADR-0010 §6). `stem` (the file name without `.md`) names it when there is no title.
/// Known sections go to the template's sections, in template order; unknown sections follow as
/// they were; text before the first `##` goes to the notes section, which comes last.
pub fn import_markdown(md: &str, stem: &str, kind: EntryKind, language: Language) -> ImportedText {
    let md = crate::text::normalize_newlines(md);
    let lines: Vec<&str> = md.split('\n').collect();
    let mut i = 0;
    while i < lines.len() && js_trim(lines[i]).is_empty() {
        i += 1;
    }
    let mut name = String::new();
    if i < lines.len() && is_h1(lines[i]) {
        name = strip_notion_id(strip_heading_mark(lines[i])).to_string();
        i += 1;
    }
    if name.is_empty() {
        name = strip_notion_id(stem).to_string();
    }
    // Property lines right after the title (blank lines between them allowed).
    let mut props: Vec<(&str, &str)> = Vec::new();
    let mut j = i;
    while j < lines.len() {
        let l = js_trim(lines[j]);
        if l.is_empty() {
            j += 1;
            continue;
        }
        if is_heading(l) {
            break;
        }
        match property(l) {
            Some(p) => {
                props.push(p);
                j += 1;
                i = j;
            }
            None => break,
        }
    }
    // Sections: text before the first `##` is loose; each `##` opens a known or unknown one.
    let titles = section_titles(kind, language);
    let notes = titles.len() - 1;
    let mut known: Vec<Vec<String>> = vec![Vec::new(); titles.len()];
    let mut unknown: Vec<(String, Vec<String>)> = Vec::new();
    let mut loose: Vec<&str> = Vec::new();
    // (Ok(known index) or Err(unknown index), raw lines)
    let mut opened: Vec<(Result<usize, usize>, Vec<&str>)> = Vec::new();
    for l in &lines[i..] {
        if let Some(t) = section_title(l) {
            let slot = match known_section(kind, t) {
                Some(k) => Ok(k),
                None => {
                    unknown.push((t.to_string(), Vec::new()));
                    Err(unknown.len() - 1)
                }
            };
            opened.push((slot, Vec::new()));
        } else if let Some((_, b)) = opened.last_mut() {
            b.push(l);
        } else {
            loose.push(l);
        }
    }
    let joined = |v: &[&str]| js_trim(&v.join("\n")).to_string();
    for (slot, b) in opened {
        let b = joined(&b);
        if b.is_empty() {
            continue;
        }
        match slot {
            Ok(k) => known[k].push(b),
            Err(u) => unknown[u].1.push(b),
        }
    }
    let loose = joined(&loose);
    if !loose.is_empty() {
        known[notes].insert(0, loose);
    }

    // Front matter: template keys first (filled from properties with the same key), then the rest.
    let mut out = format!("---\n{}: {}\n", kind_key(language), kind.label(language));
    let mut used = vec![false; props.len()];
    let mut fields = 0u32;
    let alias_key = field_keys(kind, language)[0];
    for k in field_keys(kind, language) {
        let is_alias = *k == alias_key;
        let mut values = Vec::new();
        for (n, (pk, pv)) in props.iter().enumerate() {
            let same = if is_alias {
                key_is(pk, &ALIAS_KEYS)
            } else {
                pk.to_lowercase() == k.to_lowercase()
            };
            if same && !used[n] {
                used[n] = true;
                fields += 1;
                values.push(*pv);
            }
        }
        out.push_str(format!("{k}: {}", values.join(", ")).trim_end());
        out.push('\n');
    }
    for (n, (pk, pv)) in props.iter().enumerate() {
        if used[n] || key_is(pk, &KIND_KEYS) {
            continue;
        }
        fields += 1;
        out.push_str(format!("{pk}: {pv}").trim_end());
        out.push('\n');
    }
    out.push_str("---\n# ");
    out.push_str(&name);
    out.push('\n');
    let mut sections = 0u32;
    let mut section = |out: &mut String, title: &str, parts: &[String]| {
        out.push_str("\n## ");
        out.push_str(title);
        out.push('\n');
        if !parts.is_empty() {
            sections += 1;
            out.push_str(&parts.join("\n\n"));
            out.push('\n');
        }
    };
    for (k, t) in titles.iter().enumerate().take(notes) {
        section(&mut out, t, &known[k]);
    }
    for (t, parts) in &unknown {
        section(&mut out, t, parts);
    }
    section(&mut out, titles[notes], &known[notes]);
    ImportedText {
        name,
        fields,
        sections,
        text: out,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SEOYUN: &str = "---\n종류: 인물\n별칭: 윤이, 등대지기의 딸\n나이: 17\n---\n# 서윤\n\n## 한 줄 소개\n불빛 횟수를 세는 아이.\n\n## 말투\n짧게 끊어 말한다.\n";

    fn names(m: &Matcher, text: &str) -> Vec<(usize, String, bool)> {
        m.find(text)
            .into_iter()
            .map(|x| (x.entry, text[x.start..x.end].to_string(), x.alias))
            .collect()
    }

    fn matcher(entries: &[(&'static str, &[&'static str])]) -> Matcher {
        Matcher::new(entries.iter().map(|(n, a)| (*n, a.iter().copied())))
    }

    #[test]
    fn reads_the_old_group_label() {
        for v in ["집단", "Group", "세력", "faction"] {
            assert_eq!(EntryKind::parse(v), Some(EntryKind::Group), "{v}");
        }
        assert_eq!(EntryKind::Group.label(Language::Ko), "집단");
    }

    #[test]
    fn parses_an_entry() {
        let e = parse_entry(SEOYUN).unwrap();
        assert_eq!(e.kind, EntryKind::Character);
        assert_eq!(e.name, "서윤");
        assert_eq!(e.aliases, ["윤이", "등대지기의 딸"]);
        assert_eq!(
            e.fields,
            [EntryField {
                key: "나이".into(),
                value: "17".into()
            }]
        );
        assert_eq!(e.sections.len(), 2);
        assert_eq!(e.sections[0].title, "한 줄 소개");
        assert_eq!(e.sections[0].body, "불빛 횟수를 세는 아이.");
        assert_eq!(e.sections[1].body, "짧게 끊어 말한다.");
        assert!(e.matchable);
        let fm = "---\n종류: 인물\n별칭: 윤이, 등대지기의 딸\n나이: 17\n---\n";
        assert_eq!(e.body_start as usize, fm.encode_utf16().count());
    }

    #[test]
    fn english_keys_and_case() {
        let t = "---\nKind: Place\nAliases: the Isle\nNo-Match: YES\nPart of: North sea\n---\n# Byeori Island\n## Summary\nFoggy.\n### Sub\nmore\n## Rules\n";
        let e = parse_entry(t).unwrap();
        assert_eq!(e.kind, EntryKind::Place);
        assert_eq!(e.name, "Byeori Island");
        assert_eq!(e.aliases, ["the Isle"]);
        assert!(!e.matchable);
        assert_eq!(e.fields[0].key, "Part of");
        assert_eq!(e.sections[0].body, "Foggy.\n### Sub\nmore");
        assert_eq!(e.sections[1].body, "");
        for k in ["예", "true", "True"] {
            let t = format!("---\n종류: 용어\n본문에서 찾지 않음: {k}\n---\n# 하나\n");
            assert!(!parse_entry(&t).unwrap().matchable);
        }
        let t = "---\n종류: 용어\n본문에서 찾지 않음: 아니오\n---\n# 하나\n";
        assert!(parse_entry(t).unwrap().matchable);
    }

    #[test]
    fn not_entries() {
        // No kind, unknown kind, no closing fence, not at the very start.
        for t in [
            "---\n그가 말했다: 안녕\n---\n본문",
            "---\n종류: 괴물\n---\n# 이름",
            "---\n종류: 인물\n# 서윤\n본문",
            "\n---\n종류: 인물\n---\n# 서윤",
            "--- \n",
            "",
            "# 1화\n---\n종류: 인물\n---",
        ] {
            assert_eq!(parse_entry(t), None, "{t:?}");
            assert_eq!(body_of(t), t);
            assert_eq!(entry_kind(t), None);
        }
    }

    #[test]
    fn front_matter_edge_cases() {
        // CRLF (normally already normalized), empty values, a fence with trailing spaces, a full-width colon.
        let t = "---\r\n종류：장소\r\n별칭:\r\n규모:\r\n---  \r\n# 벼리섬\r\n";
        let e = parse_entry(t).unwrap();
        assert_eq!(e.kind, EntryKind::Place);
        assert!(e.aliases.is_empty());
        assert_eq!(
            e.fields,
            [EntryField {
                key: "규모".into(),
                value: "".into()
            }]
        );
        assert_eq!(e.name, "벼리섬");
        // Closing fence at the very end, no body: name empty.
        let t = "---\n종류: 용어\n---";
        let e = parse_entry(t).unwrap();
        assert_eq!(e.name, "");
        assert_eq!(e.body_start, 14);
        assert_eq!(body_of(t), "");
        // No `# ` title: the first non-empty line names it.
        let e = parse_entry("---\n종류: 집단\n---\n\n등대회\n## 목표\n").unwrap();
        assert_eq!(e.name, "등대회");
        // Lines without a colon are ignored; aliases accumulate and dedup.
        let e = parse_entry("---\n종류: 인물\n아무 줄\n별칭: 윤이,, 윤이\n---\n# 서윤").unwrap();
        assert_eq!(e.aliases, ["윤이"]);
        assert!(e.fields.is_empty());
    }

    #[test]
    fn templates_parse_back() {
        for lang in [Language::Ko, Language::En] {
            for kind in EntryKind::ALL {
                let t = entry_template(kind, " 서윤 ", lang);
                let e = parse_entry(&t).unwrap();
                assert_eq!(e.kind, kind);
                assert_eq!(e.name, "서윤");
                assert!(e.aliases.is_empty());
                assert_eq!(e.fields.len(), field_keys(kind, lang).len() - 1);
                assert!(e.fields.iter().all(|f| f.value.is_empty()));
                let titles: Vec<&str> = e.sections.iter().map(|s| s.title.as_str()).collect();
                assert_eq!(titles, section_titles(kind, lang));
                assert!(e.sections.iter().all(|s| s.body.is_empty()));
            }
        }
        assert_eq!(
            entry_template(EntryKind::Term, "등불", Language::Ko),
            "---\n종류: 용어\n별칭:\n---\n# 등불\n\n## 뜻\n\n## 메모\n"
        );
        assert!(
            entry_template(EntryKind::Character, "Kai", Language::En)
                .starts_with("---\nkind: character\naliases:\nage:\n")
        );
    }

    #[test]
    fn josa_and_vocatives() {
        let m = matcher(&[("서윤", &[])]);
        for t in [
            "서윤이가 웃었다.",
            "서윤아, 가자.",
            "서윤은 말했다",
            "서윤",
            "“서윤!”",
            "서윤에게도",
            "서윤이었다.",
            "서윤이라는 아이",
            "(서윤)",
            "서윤의",
            "서윤처럼",
        ] {
            let found = names(&m, t);
            assert_eq!(found, [(0, "서윤".to_string(), false)], "{t}");
        }
        // The name only; the particle is not part of the match.
        let f = m.find("그때 서윤이가")[0];
        assert_eq!((f.offset, f.length), (3, 2));
        for t in ["서윤희", "한서윤", "서윤서", "서윤이네요", "서윤A", "서윤2"] {
            assert!(names(&m, t).is_empty(), "{t}");
        }
    }

    #[test]
    fn not_inside_words() {
        let m = matcher(&[("이안", &[]), ("벼리", &[])]);
        assert!(names(&m, "이 안에 있었다").is_empty());
        assert!(names(&m, "보이안").is_empty());
        assert_eq!(names(&m, "이안과 벼리").len(), 2);
        // `벼리섬` is a different word when only `벼리` is an entry.
        assert!(names(&m, "벼리섬에 도착했다").is_empty());
        assert!(names(&m, "벼리섬").is_empty());
    }

    #[test]
    fn longest_match_wins() {
        let m = matcher(&[("벼리", &[]), ("벼리섬", &[])]);
        assert_eq!(names(&m, "벼리섬에 갔다"), [(1, "벼리섬".into(), false)]);
        assert_eq!(names(&m, "벼리가 갔다"), [(0, "벼리".into(), false)]);
        // A longer name that doesn't fit falls back to the shorter one.
        let m = matcher(&[("서윤", &[]), ("서윤 언니", &[])]);
        assert_eq!(names(&m, "서윤 언니가"), [(1, "서윤 언니".into(), false)]);
        assert_eq!(names(&m, "서윤 언니도"), [(1, "서윤 언니".into(), false)]);
        assert_eq!(names(&m, "서윤 언덕"), [(0, "서윤".into(), false)]);
    }

    #[test]
    fn aliases_offsets_and_order() {
        let m = matcher(&[("서윤", &["윤이", "등대지기의 딸"]), ("해원", &[])]);
        let t = "😀 윤이는 해원에게 갔다. 등대지기의 딸이었다. 서윤!";
        let found = m.find(t);
        let got: Vec<(usize, &str, bool)> = found
            .iter()
            .map(|x| (x.entry, &t[x.start..x.end], x.alias))
            .collect();
        assert_eq!(
            got,
            [
                (0, "윤이", true),
                (1, "해원", false),
                (0, "등대지기의 딸", true),
                (0, "서윤", false)
            ]
        );
        let u: Vec<u16> = t.encode_utf16().collect();
        for x in &found {
            let s =
                String::from_utf16(&u[x.offset as usize..(x.offset + x.length) as usize]).unwrap();
            assert_eq!(s, &t[x.start..x.end]);
        }
        assert_eq!(found[0].offset, 3); // surrogate pair + space
    }

    #[test]
    fn short_names_and_duplicates_are_skipped() {
        let m = matcher(&[("민", &["A"]), ("서윤", &["서윤"]), ("해원", &["서윤"])]);
        assert!(names(&m, "민이 A가").is_empty());
        assert_eq!(names(&m, "서윤과"), [(1, "서윤".into(), false)]);
        assert!(matcher(&[]).find("아무 글").is_empty());
        // Emoji names count graphemes, not code points.
        let m = matcher(&[("👨‍👩‍👧", &[])]);
        assert!(m.is_empty());
    }

    #[test]
    fn front_matter_is_not_searched() {
        let m = matcher(&[("윤이", &[]), ("서윤", &[])]);
        let found = names(&m, SEOYUN);
        assert_eq!(found, [(1, "서윤".into(), false)]); // the title only, not the aliases line
        // A non-entry sheet starting with `---` is searched whole.
        let t = "---\n윤이가 왔다\n---\n";
        assert_eq!(names(&m, t).len(), 1);
    }

    #[test]
    fn lines_prefer_dialogue() {
        let m = matcher(&[("서윤", &[])]);
        let t = "서윤은 걸었다.\n\n“서윤아, 기다려.”\n그는 서윤을 봤다.\n- 서윤, 여기!\n「서윤」\n‘서윤?’";
        let ms = m.find(t);
        assert_eq!(ms.len(), 6);
        assert_eq!(
            mention_lines(t, &ms),
            ["“서윤아, 기다려.”", "- 서윤, 여기!", "「서윤」"]
        );
        let t = "  서윤은 걸었다.  \n그는 서윤을, 서윤을 봤다.\n셋 서윤\n넷 서윤";
        let ms = m.find(t);
        assert_eq!(
            mention_lines(t, &ms),
            ["서윤은 걸었다.", "그는 서윤을, 서윤을 봤다.", "셋 서윤"]
        );
        // A long line is cut around the name.
        let t = format!("{}서윤이 왔다{}", "가".repeat(300), "나".repeat(300));
        let ms = m.find(&t);
        assert!(ms.is_empty()); // `가서윤`: inside a word
        let t = format!("{} 서윤이 왔다 {}", "가".repeat(300), "나".repeat(300));
        let ms = m.find(&t);
        let l = &mention_lines(&t, &ms)[0];
        assert_eq!(l.chars().count(), LINE_CHARS);
        assert!(l.starts_with('…') && l.ends_with('…') && l.contains("서윤이 왔다"));
    }

    #[test]
    fn notion_import() {
        let md = "# 서윤 0123456789abcdef0123456789abcdef\n\n나이: 17\n별칭: 윤이\nCreated: October 27, 2026 3:00 PM\n\n바닷가 마을 출신.\n\n## 말투\n짧게 끊어 말한다.\n\n## 비밀\n불빛을 센다.\n\n## Voice\n존댓말.\n\n## 메모\n메모 하나.\n";
        let r = import_markdown(
            md,
            "서윤 0123456789abcdef0123456789abcdef",
            EntryKind::Character,
            Language::Ko,
        );
        assert_eq!(r.name, "서윤");
        assert_eq!(r.fields, 3);
        assert_eq!(r.sections, 3); // `말투` (two parts), `비밀`, `메모`
        let e = parse_entry(&r.text).unwrap();
        assert_eq!(e.kind, EntryKind::Character);
        assert_eq!(e.name, "서윤");
        assert_eq!(e.aliases, ["윤이"]);
        assert_eq!(
            e.fields[0],
            EntryField {
                key: "나이".into(),
                value: "17".into()
            }
        );
        assert!(
            e.fields
                .iter()
                .any(|f| f.key == "Created" && f.value == "October 27, 2026 3:00 PM")
        );
        let sec = |t: &str| {
            e.sections
                .iter()
                .find(|s| s.title == t)
                .unwrap()
                .body
                .clone()
        };
        assert_eq!(sec("말투"), "짧게 끊어 말한다.\n\n존댓말.");
        assert_eq!(sec("비밀"), "불빛을 센다.");
        assert_eq!(sec("메모"), "바닷가 마을 출신.\n\n메모 하나.");
        assert_eq!(sec("성격"), "");
        let titles: Vec<&str> = e.sections.iter().map(|s| s.title.as_str()).collect();
        assert_eq!(
            titles,
            ["한 줄 소개", "성격", "말투", "호칭", "반응", "비밀", "메모"]
        );

        // No title: the file name (without Notion's id); a sentence with a colon is not a property.
        let r = import_markdown(
            "그가 말했다. 이렇게: 안녕\n",
            "Byeori Island 0123456789abcdef0123456789ABCDEF",
            EntryKind::Place,
            Language::En,
        );
        assert_eq!(r.name, "Byeori Island");
        assert_eq!(r.fields, 0);
        assert_eq!(r.sections, 1);
        let e = parse_entry(&r.text).unwrap();
        assert_eq!(e.sections.last().unwrap().title, "Notes");
        assert_eq!(e.sections.last().unwrap().body, "그가 말했다. 이렇게: 안녕");
        // An id-like suffix of the wrong length stays.
        assert_eq!(strip_notion_id("이름 0123"), "이름 0123");
        assert_eq!(strip_notion_id("이름"), "이름");
    }
}

/// (added: bible) The manuscript rules (title, excerpt, counts, export, platform body) skip an
/// entry's front matter and nothing else.
#[cfg(test)]
mod manuscript_rules {
    use crate::{
        ExportOptions, counts, excerpt_of, export_sheets, platform_body, render_sheet, title_of,
    };

    const ENTRY: &str =
        "---\n종류: 인물\n별칭: 윤이\n나이: 17\n---\n# 서윤\n\n## 한 줄 소개\n불빛을 세는 아이.\n";
    const BODY: &str = "# 서윤\n\n## 한 줄 소개\n불빛을 세는 아이.\n";

    #[test]
    fn entries_skip_their_front_matter() {
        assert_eq!(title_of(ENTRY), "서윤");
        assert_eq!(excerpt_of(ENTRY), "불빛을 세는 아이.");
        assert_eq!(counts(ENTRY), counts(BODY));
        assert_eq!(platform_body(ENTRY), platform_body(BODY));
        let o = ExportOptions::default();
        assert_eq!(render_sheet(ENTRY, &o), render_sheet(BODY, &o));
        let md = ExportOptions {
            markdown: true,
            ..o
        };
        assert_eq!(export_sheets([ENTRY], &md), export_sheets([BODY], &md));
        assert!(!export_sheets([ENTRY], &md).contains("종류"));
    }

    #[test]
    fn a_sheet_starting_with_a_scene_break_is_unchanged() {
        // Same results as the rules gave before front matter existed.
        let t = "---\n그가 말했다: 안녕\n---\n끝.";
        assert_eq!(title_of(t), "---");
        assert_eq!(excerpt_of(t), "끝."); // scene breaks are skipped, the title is "---"
        let c = counts(t);
        assert_eq!(c.chars, "---그가 말했다: 안녕---끝.".chars().count() as u32);
        assert_eq!(c.paragraphs, 2);
        assert_eq!(
            render_sheet(t, &ExportOptions::default()),
            "* * *\n\n그가 말했다: 안녕\n\n* * *\n\n끝."
        );
        assert_eq!(platform_body(t), "그가 말했다: 안녕\n\n* * *\n\n끝.");
        let md = ExportOptions {
            markdown: true,
            ..Default::default()
        };
        assert_eq!(export_sheets([t], &md), t);
        // An unknown kind is not an entry either.
        let t = "---\n종류: 괴물\n---\n# 이름";
        assert_eq!(title_of(t), "---");
        assert_eq!(counts(t).paragraphs, 1);
    }
}
