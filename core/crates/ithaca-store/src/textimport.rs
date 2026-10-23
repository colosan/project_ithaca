//! Import of a folder of plain-text manuscripts (Hangul Office / Notepad / Scrivener exports). (added: txt-import)
//!
//! Rules (also in core/API.md):
//! - `.txt` / `.md` / `.markdown` files become sheets. Files directly in the folder go into a first
//!   folder named after the language default ("연재" / "Episodes"); each subfolder becomes a folder,
//!   and anything nested deeper is flattened into its top-level subfolder. Subfolders with no
//!   importable file are left out.
//! - Hidden entries (name starting with `.`, so `.DS_Store` too) and symlinks are ignored silently.
//!   Files over 5 MB, unreadable files and files with other extensions are skipped and reported.
//! - Names are NFC-normalized (macOS hands out decomposed Hangul) before sorting and as titles,
//!   folder names and the project title (changed: qa4).
//! - Order: natural sort by name ([`natural_cmp`]); nested files by their path inside the subfolder.
//!   (changed: qa4) Within a folder, prologues (`프롤로그` / `서장` / prologue in the file name) go
//!   first, then the rest, then side stories and notices (`외전` / `번외` / `특별편` / `공지` / `후기` /
//!   side story), then epilogues (`에필로그` / epilogue) last; see [`Place`]. In the first folder
//!   those are `excluded` episodes with no number; the rest are numbered 1..n.
//! - (changed: qa4) A subfolder that can't be read is skipped and reported ("path (reason)").
//! - Encoding: BOM (UTF-8, UTF-16 LE/BE) wins; else valid UTF-8; else CP949 (EUC-KR superset).
//!   Line endings become `\n`; trailing NULs are dropped.
//! - Title: a sheet's title is its first non-empty line. When that line is longer than 60 characters
//!   (a paragraph, not a title) or the file has no text, `# <file stem>` is put before the text.
//! - Language: as given, else Korean when Hangul is at least 20% of the letters (no letters: Korean).

use std::cmp::Ordering;
use std::fs;
use std::path::{Path, PathBuf};

use ithaca_model::{EpisodeInfo, FolderEntry, Language, Toc};
use unicode_normalization::UnicodeNormalization;

use crate::NewSheet;
use crate::error::{Result, StoreError};

pub const MAX_FILE_BYTES: u64 = 5 * 1024 * 1024;
const TITLE_MAX_CHARS: usize = 60;
const EXTENSIONS: [&str; 3] = ["txt", "md", "markdown"];

pub struct TextProject {
    pub toc: Toc,
    pub sheets: Vec<NewSheet>,
    /// Relative paths with the reason, e.g. "huge.txt (larger than 5 MB)".
    pub skipped: Vec<String>,
}

/// Compares names the way people number episodes: runs of ASCII digits compare by value
/// ("2화" < "10화", "제2화" < "제10화", "02" = "2" by value), other text case-insensitively.
/// Ties fall back to fewer leading zeros first, then the plain string, so the order is total.
pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (ca, cb) = (chunks(a), chunks(b));
    for (x, y) in ca.iter().zip(&cb) {
        let o = match (x, y) {
            (Chunk::Num(x), Chunk::Num(y)) => {
                let (tx, ty) = (x.trim_start_matches('0'), y.trim_start_matches('0'));
                tx.len().cmp(&ty.len()).then_with(|| tx.cmp(ty))
            }
            (Chunk::Num(_), Chunk::Text(_)) => Ordering::Less,
            (Chunk::Text(_), Chunk::Num(_)) => Ordering::Greater,
            (Chunk::Text(x), Chunk::Text(y)) => x.to_lowercase().cmp(&y.to_lowercase()),
        };
        if o != Ordering::Equal {
            return o;
        }
    }
    ca.len()
        .cmp(&cb.len())
        .then_with(|| leading_zeros(&ca).cmp(&leading_zeros(&cb)))
        .then_with(|| a.cmp(b))
}

enum Chunk<'a> {
    Num(&'a str),
    Text(&'a str),
}

fn chunks(s: &str) -> Vec<Chunk<'_>> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut digit = None;
    for (i, c) in s.char_indices() {
        let d = c.is_ascii_digit();
        if digit.is_some_and(|p| p != d) {
            out.push(chunk(&s[start..i], !d));
            start = i;
        }
        digit = Some(d);
    }
    if let Some(d) = digit {
        out.push(chunk(&s[start..], d));
    }
    out
}

fn chunk(s: &str, digits: bool) -> Chunk<'_> {
    if digits {
        Chunk::Num(s)
    } else {
        Chunk::Text(s)
    }
}

fn leading_zeros(cs: &[Chunk]) -> usize {
    cs.iter()
        .map(|c| match c {
            Chunk::Num(n) => n.len() - n.trim_start_matches('0').len(),
            Chunk::Text(_) => 0,
        })
        .sum()
}

/// NFC of a file name (lossy for names that are not UTF-8).
pub fn nfc(name: &std::ffi::OsStr) -> String {
    name.to_string_lossy().nfc().collect()
}

/// Where a file goes among its folder's files, by its name (added: qa4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Place {
    Prologue,
    Episode,
    /// Side stories, notices, afterwords.
    Extra,
    Epilogue,
}

impl Place {
    /// From an NFC file stem. A side story's own prologue or epilogue is still a side story.
    pub fn of(stem: &str) -> Place {
        let s = stem.to_lowercase();
        let has = |words: &[&str]| words.iter().any(|w| s.contains(w));
        if has(&[
            "외전",
            "번외",
            "특별편",
            "공지",
            "후기",
            "side story",
            "side-story",
            "sidestory",
        ]) {
            Place::Extra
        } else if has(&["에필로그", "epilogue"]) {
            Place::Epilogue
        } else if has(&["프롤로그", "서장", "prologue"]) {
            Place::Prologue
        } else {
            Place::Episode
        }
    }
}

fn place_of(rel: &Path) -> Place {
    Place::of(&rel.file_stem().map(nfc).unwrap_or_default())
}

fn path_cmp(a: &Path, b: &Path) -> Ordering {
    let name = |c: std::path::Component| nfc(c.as_os_str());
    let (mut x, mut y) = (a.components().map(name), b.components().map(name));
    loop {
        match (x.next(), y.next()) {
            (Some(p), Some(q)) => match natural_cmp(&p, &q) {
                Ordering::Equal => {}
                o => return o,
            },
            (p, q) => return p.is_some().cmp(&q.is_some()),
        }
    }
}

/// Bytes of a text file → text: BOM, else UTF-8, else CP949. `\r\n` and `\r` → `\n`; trailing
/// NULs dropped.
pub fn decode(bytes: &[u8]) -> String {
    let text = match encoding_rs::Encoding::for_bom(bytes) {
        Some((enc, bom)) => enc.decode_without_bom_handling(&bytes[bom..]).0,
        None => match std::str::from_utf8(bytes) {
            Ok(s) => s.into(),
            // encoding_rs's EUC-KR is the WHATWG one, i.e. Windows code page 949 (UHC).
            Err(_) => encoding_rs::EUC_KR.decode_without_bom_handling(bytes).0,
        },
    };
    text.replace("\r\n", "\n")
        .replace('\r', "\n")
        .trim_end_matches('\0')
        .to_string()
}

/// The first non-empty line (the title) in NFC; the rest of the text as written (added: qa4).
fn nfc_title(text: String) -> String {
    let start = text.len() - text.trim_start().len();
    let end = text[start..].find('\n').map_or(text.len(), |i| start + i);
    let title: String = text[start..end].nfc().collect();
    if title == text[start..end] {
        return text;
    }
    format!("{}{title}{}", &text[..start], &text[end..])
}

/// Puts `# <stem>` before `text` when its first non-empty line is not usable as a title.
pub fn with_title(text: String, stem: &str) -> String {
    let first = text.lines().map(str::trim).find(|l| !l.is_empty());
    match first {
        Some(l) if l.chars().count() <= TITLE_MAX_CHARS => text,
        Some(_) => format!("# {stem}\n\n{text}"),
        None => format!("# {stem}\n"),
    }
}

/// Korean when Hangul makes up at least 20% of the letters; no letters at all → Korean.
pub fn detect_language<'a>(texts: impl IntoIterator<Item = &'a str>) -> Language {
    let (mut hangul, mut letters) = (0usize, 0usize);
    for t in texts {
        for c in t.chars().filter(|c| c.is_alphabetic()) {
            letters += 1;
            if matches!(c, '\u{AC00}'..='\u{D7A3}' | '\u{1100}'..='\u{11FF}' | '\u{3130}'..='\u{318F}')
            {
                hangul += 1;
            }
        }
    }
    if letters == 0 || hangul * 5 >= letters {
        Language::Ko
    } else {
        Language::En
    }
}

fn hidden(name: &str) -> bool {
    name.starts_with('.')
}

fn mtime_ms(meta: &fs::Metadata) -> Option<i64> {
    let t = meta.modified().ok()?;
    let d = t.duration_since(std::time::UNIX_EPOCH).ok()?;
    i64::try_from(d.as_millis()).ok()
}

/// Every non-hidden file under `dir` (recursively, no symlinks), as paths relative to the import
/// root. A folder or entry that can't be read goes to `skipped` and the walk goes on.
fn walk(dir: &Path, rel: &Path, out: &mut Vec<PathBuf>, skipped: &mut Vec<String>) {
    let can_not = |skipped: &mut Vec<String>, r: &Path, e: std::io::Error| {
        skipped.push(format!("{} (can't read: {e})", shown(r)));
    };
    let entries = match fs::read_dir(dir) {
        Ok(es) => es,
        Err(e) => return can_not(skipped, rel, e),
    };
    for e in entries {
        let e = match e {
            Ok(e) => e,
            Err(err) => {
                can_not(skipped, rel, err);
                continue;
            }
        };
        let name = e.file_name();
        if hidden(&name.to_string_lossy()) {
            continue;
        }
        let r = rel.join(&name);
        match e.file_type() {
            Ok(ft) if ft.is_dir() => walk(&e.path(), &r, out, skipped),
            Ok(ft) if ft.is_file() => out.push(r),
            Ok(_) => {}
            Err(err) => can_not(skipped, &r, err),
        }
    }
}

/// A relative path as reported: NFC components joined by `/`.
fn shown(rel: &Path) -> String {
    rel.components()
        .map(|c| nfc(c.as_os_str()))
        .collect::<Vec<_>>()
        .join("/")
}

pub fn read(
    root: &Path,
    title: Option<&str>,
    language: Option<Language>,
    now: i64,
) -> Result<TextProject> {
    let meta = fs::metadata(root)
        .map_err(|e| StoreError::InvalidInput(format!("can't open the folder: {e}")))?;
    if !meta.is_dir() {
        return Err(StoreError::InvalidInput("not a folder".into()));
    }
    let mut skipped = Vec::new();
    // (top-level folder name or None for the root, files relative to `root`)
    let mut groups: Vec<(Option<String>, Vec<PathBuf>)> = vec![(None, Vec::new())];
    let mut top: Vec<(String, std::ffi::OsString)> = Vec::new();
    let entries = fs::read_dir(root)
        .map_err(|e| StoreError::InvalidInput(format!("can't open the folder: {e}")))?;
    for e in entries {
        let e = match e {
            Ok(e) => e,
            Err(err) => {
                skipped.push(format!(". (can't read an entry: {err})"));
                continue;
            }
        };
        let raw = e.file_name();
        if hidden(&raw.to_string_lossy()) {
            continue;
        }
        match e.file_type() {
            Ok(ft) if ft.is_dir() => top.push((nfc(&raw), raw)),
            Ok(ft) if ft.is_file() => groups[0].1.push(PathBuf::from(&raw)),
            Ok(_) => {}
            Err(err) => skipped.push(format!("{} (can't read: {err})", nfc(&raw))),
        }
    }
    top.sort_by(|a, b| natural_cmp(&a.0, &b.0));
    for (name, raw) in top {
        let mut files = Vec::new();
        walk(&root.join(&raw), Path::new(&raw), &mut files, &mut skipped);
        groups.push((Some(name), files));
    }

    struct Read {
        folder: usize,
        place: Place,
        text: String,
        time: i64,
    }
    let mut folder_names: Vec<Option<String>> = Vec::new();
    let mut reads: Vec<Read> = Vec::new();
    for (name, mut files) in groups {
        files.sort_by(|a, b| place_of(a).cmp(&place_of(b)).then_with(|| path_cmp(a, b)));
        let folder = folder_names.len();
        let mut any = false;
        for rel in files {
            let shown = shown(&rel);
            let ext = rel
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            if !EXTENSIONS.contains(&ext.as_str()) {
                skipped.push(format!("{shown} (not .txt or .md)"));
                continue;
            }
            let path = root.join(&rel);
            let meta = match fs::metadata(&path) {
                Ok(m) => m,
                Err(e) => {
                    skipped.push(format!("{shown} (can't read: {e})"));
                    continue;
                }
            };
            if meta.len() > MAX_FILE_BYTES {
                skipped.push(format!("{shown} (larger than 5 MB)"));
                continue;
            }
            let bytes = match fs::read(&path) {
                Ok(b) => b,
                Err(e) => {
                    skipped.push(format!("{shown} (can't read: {e})"));
                    continue;
                }
            };
            let stem = rel.file_stem().map(nfc).unwrap_or_default();
            reads.push(Read {
                folder,
                place: Place::of(&stem),
                text: with_title(nfc_title(decode(&bytes)), &stem),
                time: mtime_ms(&meta).unwrap_or(now),
            });
            any = true;
        }
        if any {
            folder_names.push(name);
        }
    }
    if reads.is_empty() {
        return Err(StoreError::InvalidInput(
            "no .txt or .md files in this folder".into(),
        ));
    }

    let language =
        language.unwrap_or_else(|| detect_language(reads.iter().map(|r| r.text.as_str())));
    let serial = match language {
        Language::Ko => "연재",
        Language::En => "Episodes",
    };
    let title = title
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| root.file_name().map(nfc).unwrap_or_default());
    let toc = Toc {
        title,
        language,
        created: now,
        folders: folder_names
            .into_iter()
            .map(|n| {
                FolderEntry::new(
                    uuid::Uuid::new_v4().simple().to_string(),
                    n.unwrap_or_else(|| serial.to_string()),
                )
            })
            .collect(),
        ..Default::default()
    };
    let mut n = 0;
    let sheets = reads
        .into_iter()
        .map(|r| NewSheet {
            folder: r.folder,
            text: r.text,
            created: r.time,
            modified: r.time,
            // Like the web import: the first folder is the serial, episodes 1..n, Draft;
            // prologues, side stories and epilogues there are excluded and unnumbered (qa4).
            episode: (r.folder == 0).then(|| {
                if r.place == Place::Episode {
                    n += 1;
                    EpisodeInfo {
                        number: Some(n),
                        ..Default::default()
                    }
                } else {
                    EpisodeInfo {
                        excluded: true,
                        ..Default::default()
                    }
                }
            }),
        })
        .collect();
    Ok(TextProject {
        toc,
        sheets,
        skipped,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted(mut v: Vec<&str>) -> Vec<&str> {
        v.sort_by(|a, b| natural_cmp(a, b));
        v
    }

    #[test]
    fn natural_order() {
        assert_eq!(
            sorted(vec!["10화.txt", "2화.txt", "1화.txt"]),
            ["1화.txt", "2화.txt", "10화.txt"]
        );
        assert_eq!(
            sorted(vec!["제10화", "제2화", "제1화 프롤로그"]),
            ["제1화 프롤로그", "제2화", "제10화"]
        );
        // Zero padding compares by value; on a tie the unpadded one goes first.
        assert_eq!(
            sorted(vec!["010", "9", "002", "2", "1"]),
            ["1", "2", "002", "9", "010"]
        );
        assert_eq!(
            sorted(vec!["Chapter 10", "chapter 9", "Chapter 1"]),
            ["Chapter 1", "chapter 9", "Chapter 10"]
        );
        // Numbers before text, shorter before longer, Korean prefixes as text.
        assert_eq!(
            sorted(vec!["외전 1", "프롤로그", "1화", "에필로그", "1화 (수정)"]),
            ["1화", "1화 (수정)", "에필로그", "외전 1", "프롤로그"]
        );
        assert_eq!(natural_cmp("a", "a"), Ordering::Equal);
        assert_eq!(natural_cmp("", "1"), Ordering::Less);
        // Huge numbers don't overflow.
        assert_eq!(
            natural_cmp("99999999999999999999999", "100000000000000000000000"),
            Ordering::Less
        );
    }

    #[test]
    fn decodes_and_normalizes() {
        assert_eq!(decode(b"\xEF\xBB\xBFa\r\nb\rc\0\0"), "a\nb\nc");
        assert_eq!(decode("가나".as_bytes()), "가나");
        let le: Vec<u8> = [0xFF, 0xFE]
            .into_iter()
            .chain("가\r\n".encode_utf16().flat_map(u16::to_le_bytes))
            .collect();
        assert_eq!(decode(&le), "가\n");
        let be: Vec<u8> = [0xFE, 0xFF]
            .into_iter()
            .chain("가".encode_utf16().flat_map(u16::to_be_bytes))
            .collect();
        assert_eq!(decode(&be), "가");
        let (cp949, _, bad) = encoding_rs::EUC_KR.encode("똠방각하 1화");
        assert!(!bad);
        assert_eq!(decode(&cp949), "똠방각하 1화");
    }

    #[test]
    fn titles() {
        assert_eq!(with_title("1화\n\n본문".into(), "x"), "1화\n\n본문");
        assert_eq!(with_title("\n\n  1화\n".into(), "x"), "\n\n  1화\n");
        let long = "가".repeat(61);
        assert_eq!(with_title(long.clone(), "3화"), format!("# 3화\n\n{long}"));
        assert_eq!(with_title("가".repeat(60), "x"), "가".repeat(60));
        assert_eq!(with_title(String::new(), "빈 화"), "# 빈 화\n");
        assert_eq!(with_title(" \n".into(), "빈 화"), "# 빈 화\n");
    }

    #[test]
    fn language() {
        assert_eq!(detect_language(["그는 말했다. OK"]), Language::Ko);
        assert_eq!(detect_language(["The road was long. 길"]), Language::En);
        assert_eq!(detect_language(["1234 ..."]), Language::Ko);
    }
}
