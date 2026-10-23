//! Lengths as Korean serial platforms count them (docs/research/2026-10-24-serial-writers-and-platforms.md §1.1).
//!
//! Every rule counts the text exactly as given. To count what will be pasted into a platform, pass the
//! exported text (`export_text`, Markdown marks stripped), not the raw sheet.
//! Counts are grapheme clusters, like [`crate::counts`], so 👨‍👩‍👧 and decomposed `한` are one each.

use unicode_segmentation::UnicodeSegmentation;

use crate::GoalBasis;
use crate::export::{ExportOptions, render_sheet};
use crate::text::{counts, is_js_space};

/// Characters per Munpia "쪽" (page).
pub const MUNPIA_PAGE_CHARS: u32 = 470;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CountRule {
    /// Ithaca `공백 포함`: every grapheme except line breaks (= `Counts::chars`).
    WithSpaces,
    /// Ithaca `공백 제외`: every grapheme except whitespace and line breaks (= `Counts::chars_no_space`).
    WithoutSpaces,
    /// Words after removing Markdown marks (= `Counts::words`).
    Words,
    /// `문피아`: `공백 포함`, line breaks (`엔터`) not counted. Pages: [`munpia_pages`].
    Munpia,
    /// `노벨피아`: no whitespace, line breaks, tabs, `.` `,` `'` `"` `!` `?` (and `…`).
    Novelpia,
    /// `조아라`: size in UTF-8 bytes, line breaks included.
    BytesUtf8,
}

fn graphemes(s: &str) -> u32 {
    s.graphemes(true).count() as u32
}

/// `노벨피아` FAQ "글자수 기준은 무엇인가요?" (2021-07-22, https://novelpia.com/faq/all/view_383218/):
/// `띄어쓰기` · `점`(.) · `따옴표`(") · `쉼표`(') · `개행` · `탭` · `느낌표` · `물음표` · `공백문자를 세지 않음`.
/// The FAQ labels `'` as `쉼표`, so both `,` and `'` are left out. `…` is left out too because the
/// research (§1.2) reads the rule as "`...` and `…` both count 0" — unverified on the platform.
/// Curly quotes (“ ” ‘ ’) are counted: the FAQ names only the ASCII marks. [`미확인`]
fn novelpia_skips(c: char) -> bool {
    is_js_space(c) || matches!(c, '.' | ',' | '\'' | '"' | '!' | '?' | '…')
}

/// The length of `text` under `rule`.
pub fn count_for(text: &str, rule: CountRule) -> u32 {
    match rule {
        CountRule::WithSpaces => counts(text).chars,
        CountRule::WithoutSpaces => counts(text).chars_no_space,
        CountRule::Words => counts(text).words,
        // 〔`공식`〕 `문피아 공지` 2026-02-23 "내서재 글자수 확인" (https://nhelp.munpia.com/notices/1773):
        // `공백 포함`, and the `쪽수` excludes `엔터`. Collapsing runs of spaces/line breaks to one character
        // is reported only by a third-party counter (pyozi) and is not applied. [`미확인`]
        CountRule::Munpia => {
            let no_breaks: String = text.chars().filter(|c| !matches!(c, '\n' | '\r')).collect();
            graphemes(&no_breaks)
        }
        CountRule::Novelpia => {
            let kept: String = text.chars().filter(|c| !novelpia_skips(*c)).collect();
            graphemes(&kept)
        }
        // `조아라` counts size, not characters (`유료 최소` 10KB; 〔`커뮤니티`〕 `디시` 2026-06-15). UTF-8 fits the
        // reported conversion: 3,000 Hangul × 3 B + ~1,150 spaces × 1 B ≈ 10 KB ≈ "공백 포함 약 4,150자".
        CountRule::BytesUtf8 => text.len() as u32,
    }
}

/// `문피아 쪽수`: ⌈(`공백 포함`, `엔터 제외`) / 470⌉ (same notice as [`CountRule::Munpia`]). Empty text is 0 pages.
pub fn munpia_pages(text: &str) -> u32 {
    count_for(text, CountRule::Munpia).div_ceil(MUNPIA_PAGE_CHARS)
}

/// What goes into a platform's body field (added: r3): the sheet exported with the default paste
/// rules (Markdown stripped, blank line between paragraphs, no indent) but **without its title
/// line**, since every platform takes the title in a separate field.
pub fn platform_body(sheet_text: &str) -> String {
    render_sheet(
        sheet_text,
        &ExportOptions {
            include_title: false,
            ..Default::default()
        },
    )
}

/// A sheet's length under a goal basis (added: r3). `WithSpaces` / `WithoutSpaces` / `Words` count
/// the sheet as written (= its `Counts`); `Munpia` / `Novelpia` count [`platform_body`].
pub fn goal_count(sheet_text: &str, basis: GoalBasis) -> u32 {
    match basis {
        GoalBasis::WithSpaces => counts(sheet_text).chars,
        GoalBasis::WithoutSpaces => counts(sheet_text).chars_no_space,
        GoalBasis::Words => counts(sheet_text).words,
        GoalBasis::Munpia => count_for(&platform_body(sheet_text), CountRule::Munpia),
        GoalBasis::Novelpia => count_for(&platform_body(sheet_text), CountRule::Novelpia),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EP: &str = "\"괜찮아?\" 그가 물었다.\n\n'아니.' 나는 대답했다... 정말, 아니었다!\n\t끝…";

    #[test]
    fn ithaca_rules_match_counts() {
        let c = counts(EP);
        assert_eq!(count_for(EP, CountRule::WithSpaces), c.chars);
        assert_eq!(count_for(EP, CountRule::WithoutSpaces), c.chars_no_space);
        assert_eq!(count_for(EP, CountRule::Words), c.words);
    }

    #[test]
    fn munpia_counts_spaces_not_line_breaks() {
        // `가` ␠ `나 다 라` — Windows line breaks (\r\n) count 0 too.
        assert_eq!(count_for("가 나\n다\r\n라", CountRule::Munpia), 5);
        assert_eq!(count_for(EP, CountRule::Munpia), counts(EP).chars);
        assert_eq!(count_for("👨‍👩‍👧 e\u{301}", CountRule::Munpia), 3);
    }

    #[test]
    fn munpia_pages_round_up() {
        assert_eq!(munpia_pages(""), 0);
        assert_eq!(munpia_pages("가"), 1);
        assert_eq!(munpia_pages(&"가".repeat(470)), 1);
        assert_eq!(munpia_pages(&"가".repeat(471)), 2);
        // Line breaks don't make pages.
        assert_eq!(munpia_pages(&"가\n".repeat(470)), 1);
        // Typical episode: `공백 포함` 5,`000자` → `11쪽`.
        assert_eq!(munpia_pages(&"가".repeat(5000)), 11);
    }

    #[test]
    fn novelpia_drops_whitespace_and_marks() {
        // Kept: `괜찮아 그가 물었다 아니 나는 대답했다 정말 아니었다 끝`
        let kept = "괜찮아그가물었다아니나는대답했다정말아니었다끝";
        assert_eq!(
            count_for(EP, CountRule::Novelpia),
            kept.chars().count() as u32
        );
        // `...` and `…` are both 0 here, 3 and 1 at Munpia.
        assert_eq!(count_for("...", CountRule::Novelpia), 0);
        assert_eq!(count_for("…", CountRule::Novelpia), 0);
        assert_eq!(count_for("...", CountRule::Munpia), 3);
        // Curly quotes and other marks still count.
        assert_eq!(count_for("“가”~", CountRule::Novelpia), 4);
        // Lower than `공백 제외` by exactly the marks.
        let marks = EP.chars().filter(|c| ".,'\"!?…".contains(*c)).count() as u32;
        assert_eq!(
            count_for(EP, CountRule::Novelpia),
            count_for(EP, CountRule::WithoutSpaces) - marks
        );
    }

    #[test]
    fn goal_counts_use_the_platform_body() {
        let sheet = "# 1화\n\n**\"가!\"** 나 다.\n\n라";
        // Body without the title and Markdown: `"가!" 나 다.` + `라`, joined by a blank line.
        assert_eq!(platform_body(sheet), "\"가!\" 나 다.\n\n라");
        assert_eq!(goal_count(sheet, GoalBasis::Munpia), 10);
        assert_eq!(goal_count(sheet, GoalBasis::Novelpia), 4);
        assert_eq!(
            goal_count(sheet, GoalBasis::WithSpaces),
            counts(sheet).chars
        );
        assert_eq!(goal_count(sheet, GoalBasis::Words), counts(sheet).words);
    }

    #[test]
    fn joara_size_is_utf8_bytes() {
        assert_eq!(count_for("가 a\n", CountRule::BytesUtf8), 3 + 1 + 1 + 1);
        assert_eq!(count_for("😀", CountRule::BytesUtf8), 4);
        // 3,000 Hangul + 1,150 spaces ≈ 10 KB (research §1.1).
        let s = "가".repeat(3000) + &" ".repeat(1150);
        assert_eq!(count_for(&s, CountRule::BytesUtf8), 10_150);
    }
}
