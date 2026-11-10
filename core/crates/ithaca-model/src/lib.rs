//! Ithaca data model (ADR-0001). Plain data and text rules, no IO.

pub mod bible;
pub mod docx;
pub mod episode;
pub mod export;
pub mod note;
pub mod platform;
pub mod text;
pub mod toc;

use serde::{Deserialize, Serialize};

pub use bible::{
    EntryField, EntryKind, EntrySection, ParsedEntry, body_of, entry_kind, entry_template,
    parse_entry,
};
pub use docx::{DocxOptions, export_docx};
pub use episode::{EpisodeInfo, EpisodeStatus};
pub use export::{ExportOptions, export_sheets, render_sheet};
pub use note::author_note;
pub use platform::{
    CountRule, MUNPIA_PAGE_CHARS, count_for, goal_count, munpia_pages, platform_body,
};
pub use text::{Counts, counts, excerpt_of, title_of};
pub use toc::{Extra, FolderEntry, SheetEntry, Toc};

/// Manuscript language. Decides the length unit (ADR-0005): characters for Korean, words for English.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Language {
    #[default]
    Ko,
    En,
}

/// What a project's goal counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GoalBasis {
    WithSpaces,
    WithoutSpaces,
    Words,
    /// (added: r3) `문피아` count ([`CountRule::Munpia`]) of the paste-ready body.
    Munpia,
    /// (added: r3) `노벨피아` count ([`CountRule::Novelpia`]) of the paste-ready body.
    Novelpia,
    /// (added: 0.11.1) `조아라`: size of the paste-ready body in UTF-8 bytes ([`CountRule::BytesUtf8`]);
    /// the app shows it in KB (1,024 bytes).
    Joara,
    /// (added: 0.11.1) `카카오페이지`: `공백 포함` of the paste-ready body, line breaks left out (the
    /// [`CountRule::Munpia`] rule; the platform publishes no rule of its own).
    Kakaopage,
    /// (added: 0.11.1) `네이버 시리즈`: as [`GoalBasis::Kakaopage`].
    NaverSeries,
}

/// Per-episode length goal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Goal {
    pub count: u32,
    pub basis: GoalBasis,
}

/// Trash and deleted projects are kept this long before they are dropped for good.
pub const RETENTION_MS: i64 = 30 * 86_400_000;
