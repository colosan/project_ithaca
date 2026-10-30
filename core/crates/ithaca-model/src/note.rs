//! `작가의 말` (added: note): a sheet's `## 작가의 말` heading line and everything after it.
//! It is posted in the platform's own field, so it is not manuscript: titles, excerpts, counts, the
//! platform body and exports leave it out ([`crate::bible::body_of`]). Search still finds it.

use crate::export::{ExportOptions, render_sheet};
use crate::text::{is_heading, js_trim, strip_heading_mark};

/// Heading titles that open the note (any level, spaces around ignored).
pub const NOTE_TITLES: [&str; 2] = ["작가의 말", "작가의말"];

/// Whether `line` is the note's heading.
pub fn is_note_heading(line: &str) -> bool {
    let line = line.trim_end_matches('\r');
    is_heading(line)
        && line.chars().take_while(|c| *c == '#').count() <= 6
        && NOTE_TITLES.contains(&js_trim(strip_heading_mark(line)))
}

/// Byte offset of the first note heading line at or after `from` (a line start), else `text.len()`.
pub fn note_start(text: &str, from: usize) -> usize {
    let mut pos = from;
    while pos < text.len() {
        let end = text[pos..].find('\n').map_or(text.len(), |i| pos + i);
        if is_note_heading(&text[pos..end]) {
            return pos;
        }
        pos = end + 1;
    }
    text.len()
}

/// The note as written (after its heading line), `None` when the sheet has no note heading.
pub fn author_note_text(text: &str) -> Option<&str> {
    let start = note_start(text, crate::bible::body_offset(text));
    (start < text.len()).then(|| {
        text[start..]
            .find('\n')
            .map_or("", |i| &text[start + i + 1..])
    })
}

/// The note as pasted into a platform's `작가의 말` field: the default paste rules (Markdown
/// stripped, a blank line between paragraphs). `None` without a note heading; `""` when it is empty.
pub fn author_note(text: &str) -> Option<String> {
    author_note_text(text).map(|n| render_sheet(n, &ExportOptions::default()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{counts, platform_body, title_of};

    const EP: &str =
        "# 3화\n\n그는 **웃었다**.\n\n## 작가의 말\n오늘도 *감사*합니다.\n\n다음 화는 금요일.\n";

    #[test]
    fn note_is_not_manuscript() {
        assert_eq!(platform_body(EP), "그는 웃었다.");
        assert_eq!(
            counts(EP).chars,
            counts("# 3화\n\n그는 **웃었다**.\n\n").chars
        );
        assert_eq!(title_of(EP), "3화");
        assert_eq!(
            author_note(EP).as_deref(),
            Some("오늘도 감사합니다.\n\n다음 화는 금요일.")
        );
    }

    #[test]
    fn heading_forms() {
        assert!(is_note_heading("## 작가의 말"));
        assert!(is_note_heading("# 작가의말  "));
        assert!(is_note_heading("### 작가의 말\r"));
        assert!(!is_note_heading("작가의 말"));
        assert!(!is_note_heading("## 작가의 말씀"));
        assert_eq!(author_note("본문만\n"), None);
        assert_eq!(author_note("본문\n## 작가의 말").as_deref(), Some(""));
        // Only the first note heading counts; a second one is part of the note.
        assert_eq!(
            author_note_text("a\n## 작가의 말\nb\n## 작가의 말\nc"),
            Some("b\n## 작가의 말\nc")
        );
    }

    #[test]
    fn entry_front_matter_is_skipped() {
        let t = "---\n종류: 인물\n---\n# 서윤\n\n## 작가의 말\n메모";
        assert_eq!(author_note_text(t), Some("메모"));
        assert_eq!(crate::bible::body_of(t), "# 서윤\n\n");
    }
}
