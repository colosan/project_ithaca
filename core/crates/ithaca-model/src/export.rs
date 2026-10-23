//! Paste-ready text for serial platforms (app-web/src/Export.tsx, design/screens/export).

use crate::text::{
    is_heading, is_js_space, js_trim, js_trim_start, normalize_newlines, strip_emphasis,
    strip_heading_mark,
};

/// The plain spelling every scene break is normalized to.
pub const SCENE_MARK: &str = "* * *";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExportOptions {
    /// A blank line between paragraphs.
    pub blank_line: bool,
    /// First-line indent with an ideographic space (U+3000).
    pub indent: bool,
    /// Remove Markdown marks (headings, list/quote markers, emphasis).
    pub strip_markdown: bool,
    /// Keep the first line (the title).
    pub include_title: bool,
    /// Markdown file: bodies as written, separated by `---`. The other options are ignored.
    pub markdown: bool,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            blank_line: true,
            indent: false,
            strip_markdown: true,
            include_title: true,
            markdown: false,
        }
    }
}

/// Export.tsx `SCENE_BREAK`: three or more of one mark family (`*＊`, `-－`, `_＿`), spaces allowed.
pub(crate) fn is_export_scene_break(line: &str) -> bool {
    let family = |c: char| match c {
        '*' | '＊' => Some(0),
        '-' | '－' => Some(1),
        '_' | '＿' => Some(2),
        _ => None,
    };
    let mut fam = None;
    let mut n = 0;
    for c in js_trim(line).chars() {
        if is_js_space(c) {
            continue;
        }
        match (family(c), fam) {
            (None, _) => return false,
            (Some(f), None) => fam = Some(f),
            (Some(f), Some(g)) if f != g => return false,
            _ => {}
        }
        n += 1;
    }
    n >= 3
}

/// Removes `^[-*>]\s+` once.
pub(crate) fn strip_list_mark(s: &str) -> &str {
    match s.strip_prefix(['-', '*', '>']) {
        Some(r) if r.starts_with(is_js_space) => r.trim_start_matches(is_js_space),
        _ => s,
    }
}

/// One sheet with the paste rules.
pub fn render_sheet(body: &str, o: &ExportOptions) -> String {
    // (changed: qa4) `\r\n` / `\r` count as line breaks.
    let body = normalize_newlines(body);
    let mut lines: Vec<&str> = body.split('\n').collect();
    if !o.include_title
        && let Some(i) = lines.iter().position(|l| !js_trim(l).is_empty())
    {
        lines.drain(..=i);
    }
    let sep = if o.blank_line { "\n\n" } else { "\n" };
    lines
        .into_iter()
        .filter(|l| !js_trim(l).is_empty())
        .map(|l| {
            // A scene break is content, not Markdown: keep it, in one plain spelling, and never indent it.
            if is_export_scene_break(l) {
                return SCENE_MARK.to_string();
            }
            let s = if o.strip_markdown {
                strip_emphasis(strip_list_mark(strip_heading_mark(l)), false)
            } else {
                l.to_string()
            };
            if o.indent && !is_heading(l) {
                format!("\u{3000}{}", js_trim_start(&s))
            } else {
                s
            }
        })
        .collect::<Vec<_>>()
        .join(sep)
}

/// Several sheets in reading order: three line breaks between sheets, or `---` for a Markdown file.
pub fn export_sheets<'a>(bodies: impl IntoIterator<Item = &'a str>, o: &ExportOptions) -> String {
    if o.markdown {
        bodies
            .into_iter()
            .map(|b| js_trim(&normalize_newlines(b)).to_string())
            .collect::<Vec<_>>()
            .join("\n\n---\n\n")
    } else {
        bodies
            .into_iter()
            .map(|b| render_sheet(b, o))
            .collect::<Vec<_>>()
            .join("\n\n\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BODY: &str = "# 1화 · 시작\n\n그날 밤, **비가** 왔다.\n- 목록 같은 줄\n\n＊＊＊\n\n> 인용된 _말_\n---\n끝.";

    #[test]
    fn default_rules() {
        let out = render_sheet(BODY, &ExportOptions::default());
        assert_eq!(
            out,
            "1화 · 시작\n\n그날 밤, 비가 왔다.\n\n목록 같은 줄\n\n* * *\n\n인용된 말\n\n* * *\n\n끝."
        );
    }

    #[test]
    fn indent_no_blank_line_no_title() {
        let o = ExportOptions {
            blank_line: false,
            indent: true,
            include_title: false,
            ..Default::default()
        };
        let out = render_sheet(BODY, &o);
        assert_eq!(
            out,
            "\u{3000}그날 밤, 비가 왔다.\n\u{3000}목록 같은 줄\n* * *\n\u{3000}인용된 말\n* * *\n\u{3000}끝."
        );
    }

    #[test]
    fn headings_are_not_indented_and_marks_kept_when_not_stripping() {
        let o = ExportOptions {
            indent: true,
            strip_markdown: false,
            ..Default::default()
        };
        let out = render_sheet("# 제목\n  **굵게**", &o);
        assert_eq!(out, "# 제목\n\n\u{3000}**굵게**");
    }

    #[test]
    fn several_sheets_and_markdown() {
        let o = ExportOptions::default();
        assert_eq!(
            export_sheets(["# A\n하나", "# B\n둘"], &o),
            "A\n\n하나\n\n\nB\n\n둘"
        );
        let md = ExportOptions {
            markdown: true,
            ..o
        };
        assert_eq!(
            export_sheets(["\n# A\n하나\n", "# B"], &md),
            "# A\n하나\n\n---\n\n# B"
        );
    }

    #[test]
    fn mixed_width_scene_breaks() {
        assert!(is_export_scene_break("*＊*"));
        assert!(is_export_scene_break("- － -"));
        assert!(!is_export_scene_break("*-*"));
        assert!(!is_export_scene_break("**"));
    }
}
