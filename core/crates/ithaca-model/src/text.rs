//! Manuscript text rules: title, excerpt, counts. A port of app-web/src/text.ts so the web and
//! native apps show the same numbers for the same text (ADR-0005 length units).

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

/// Lengths of a text as people see them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Counts {
    /// Grapheme clusters, line breaks excluded (other whitespace included).
    pub chars: u32,
    /// Grapheme clusters, all whitespace excluded.
    pub chars_no_space: u32,
    /// Words (UAX #29) after removing Markdown marks.
    pub words: u32,
    /// Non-blank lines that are neither headings nor scene breaks.
    pub paragraphs: u32,
}

impl std::ops::Add for Counts {
    type Output = Counts;
    fn add(self, o: Counts) -> Counts {
        Counts {
            chars: self.chars + o.chars,
            chars_no_space: self.chars_no_space + o.chars_no_space,
            words: self.words + o.words,
            paragraphs: self.paragraphs + o.paragraphs,
        }
    }
}

/// JavaScript's `\s` (WhiteSpace + LineTerminator), so trimming matches the web app exactly.
pub fn is_js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{0B}' | '\u{0C}' | '\r' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202F}'
                | '\u{205F}'
                | '\u{3000}'
                | '\u{FEFF}'
    )
}

/// `\r\n` and lone `\r` → `\n` (added: qa4). Borrows when there is no `\r`.
pub fn normalize_newlines(s: &str) -> std::borrow::Cow<'_, str> {
    if s.contains('\r') {
        s.replace("\r\n", "\n").replace('\r', "\n").into()
    } else {
        s.into()
    }
}

/// `String.prototype.trim`.
pub fn js_trim(s: &str) -> &str {
    s.trim_matches(is_js_space)
}

/// `String.prototype.trimStart`.
pub fn js_trim_start(s: &str) -> &str {
    s.trim_start_matches(is_js_space)
}

fn grapheme_len(s: &str) -> u32 {
    s.graphemes(true).count() as u32
}

/// A scene break line such as `* * *`, `---` or `＊＊＊` (text.ts `isSceneBreak`): three or more of one mark.
pub fn is_scene_break(line: &str) -> bool {
    let mut marks = js_trim(line).chars().filter(|c| !is_js_space(*c));
    let Some(first) = marks.next() else {
        return false;
    };
    if !matches!(first, '-' | '*' | '_' | '＊') {
        return false;
    }
    let mut n = 1;
    for c in marks {
        if c != first {
            return false;
        }
        n += 1;
    }
    n >= 3
}

/// `/^#+\s/` — a Markdown heading line.
pub fn is_heading(line: &str) -> bool {
    let rest = line.trim_start_matches('#');
    rest.len() < line.len() && rest.chars().next().is_some_and(is_js_space)
}

/// Removes `^#+\s*` (one leading heading mark and the space after it).
pub fn strip_heading_mark(line: &str) -> &str {
    let rest = line.trim_start_matches('#');
    if rest.len() == line.len() {
        line
    } else {
        rest.trim_start_matches(is_js_space)
    }
}

const EMPHASIS: [&str; 6] = ["**", "__", "*", "_", "~~", "`"];

/// Replaces `(\*\*|__|\*|_|~~|`)(.+?)\1` by its content within one line. With `strict`, the content
/// must start and end with a non-space character (text.ts adds `(?=\S)` / `(?<=\S)`).
pub fn strip_emphasis(line: &str, strict: bool) -> String {
    let mut out = String::with_capacity(line.len());
    let mut i = 0;
    'outer: while i < line.len() {
        let rest = &line[i..];
        for m in EMPHASIS {
            if !rest.starts_with(m) {
                continue;
            }
            let c0 = i + m.len();
            let Some(first) = line[c0..].chars().next() else {
                continue;
            };
            if strict && is_js_space(first) {
                continue;
            }
            // Lazy: the first closing mark after at least one content character.
            let mut j = c0 + first.len_utf8();
            while j < line.len() {
                if line[j..].starts_with(m) {
                    let before = line[..j].chars().next_back().unwrap_or(' ');
                    if !strict || !is_js_space(before) {
                        out.push_str(&line[c0..j]);
                        i = j + m.len();
                        continue 'outer;
                    }
                }
                j += line[j..].chars().next().map_or(1, char::len_utf8);
            }
        }
        let c = rest.chars().next().unwrap_or(' ');
        out.push(c);
        i += c.len_utf8();
    }
    out
}

/// Removes `^[ \t]*(#{1,6}|[-*+>]|\d+\.)[ \t]+` from one line.
fn strip_line_mark(line: &str) -> &str {
    let s = line.trim_start_matches([' ', '\t']);
    let after = if let Some(r) = s.strip_prefix(['-', '*', '+', '>']) {
        Some(r)
    } else if s.starts_with('#') {
        let n = s.len() - s.trim_start_matches('#').len();
        (n <= 6).then(|| &s[n..])
    } else {
        let digits = s.len() - s.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        if digits > 0 {
            s[digits..].strip_prefix('.')
        } else {
            None
        }
    };
    match after {
        Some(r) if r.starts_with([' ', '\t']) => r.trim_start_matches([' ', '\t']),
        _ => line,
    }
}

/// Markdown marks that aren't part of the prose (text.ts `stripMarks`).
pub fn strip_marks(s: &str) -> String {
    s.split('\n')
        .map(|l| strip_emphasis(strip_line_mark(l), true))
        .collect::<Vec<_>>()
        .join("\n")
}

/// First non-empty line without a leading Markdown heading mark.
pub fn title_of(body: &str) -> String {
    let line = body
        .split('\n')
        .find(|l| !js_trim(l).is_empty())
        .unwrap_or("");
    js_trim(strip_heading_mark(line)).to_string()
}

/// The line after the title, for the sheet list.
pub fn excerpt_of(body: &str) -> String {
    let line = body
        .split('\n')
        .filter(|l| !js_trim(l).is_empty() && !is_scene_break(l))
        .nth(1)
        .unwrap_or("");
    js_trim(&strip_marks(line)).to_string()
}

/// Characters, words and paragraphs, exactly as the web app counts them.
pub fn counts(body: &str) -> Counts {
    let no_newlines: String = body.chars().filter(|c| *c != '\n').collect();
    let no_space: String = body.chars().filter(|c| !is_js_space(*c)).collect();
    let words = strip_marks(body).unicode_words().count() as u32;
    let paragraphs = body
        .split('\n')
        .filter(|l| !js_trim(l).is_empty() && !is_heading(l) && !is_scene_break(l))
        .count() as u32;
    Counts {
        chars: grapheme_len(&no_newlines),
        chars_no_space: grapheme_len(&no_space),
        words,
        paragraphs,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn korean_counts() {
        let c = counts("# 1화\n\n그날 밤, 비가 왔다.\n그는 우산이 없었다.");
        assert_eq!(
            c.chars,
            "# 1화그날 밤, 비가 왔다.그는 우산이 없었다."
                .chars()
                .count() as u32
        );
        assert_eq!(
            c.chars_no_space,
            "#1화그날밤,비가왔다.그는우산이없었다.".chars().count() as u32
        );
        assert_eq!(c.words, 8); // `1화 그날 밤 비가 왔다 그는 우산이 없었다`
        assert_eq!(c.paragraphs, 2); // heading excluded
    }

    #[test]
    fn emoji_zwj_and_combining_marks_are_one_char() {
        // Family emoji (ZWJ sequence), flag, and e + combining acute.
        let c = counts("👨‍👩‍👧 🇰🇷 e\u{301}");
        assert_eq!(c.chars, 5);
        assert_eq!(c.chars_no_space, 3);
        // Decomposed Hangul (jamo) is one grapheme per syllable.
        assert_eq!(counts("\u{1100}\u{1161}\u{11A8}").chars, 1);
    }

    #[test]
    fn words_ignore_markdown_marks() {
        let c = counts("## Chapter One\n- **bold** move\n> a _quiet_ `code`\n1. last");
        assert_eq!(c.words, 8);
        assert_eq!(c.paragraphs, 3);
        assert_eq!(counts("It's a 2-step plan.").words, 5);
    }

    #[test]
    fn scene_breaks_are_not_paragraphs() {
        assert!(is_scene_break("* * *"));
        assert!(is_scene_break("  ---  "));
        assert!(is_scene_break("＊＊＊"));
        assert!(!is_scene_break("**"));
        assert!(!is_scene_break("*-*"));
        assert_eq!(counts("하나\n\n* * *\n\n둘").paragraphs, 2);
    }

    #[test]
    fn title_and_excerpt() {
        let body = "\n# 3화 · 귀향\n\n* * *\n바다는 **조용했다**.\n둘째 줄";
        assert_eq!(title_of(body), "3화 · 귀향");
        assert_eq!(excerpt_of(body), "바다는 조용했다.");
        assert_eq!(title_of(""), "");
        assert_eq!(excerpt_of("only"), "");
    }

    #[test]
    fn emphasis_rules() {
        assert_eq!(strip_emphasis("a **b** c", true), "a b c");
        // JS tries the single `*` next: its content "* b *" starts and ends with a non-space.
        assert_eq!(strip_emphasis("a ** b ** c", true), "a * b * c");
        assert_eq!(strip_emphasis("a ** b ** c", false), "a  b  c");
        assert_eq!(strip_emphasis("**open", false), "**open");
        assert_eq!(strip_emphasis("~~x~~ and `y`", false), "x and y");
    }
}
