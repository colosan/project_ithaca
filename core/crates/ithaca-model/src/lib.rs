//! Ithaca data model (ADR-0001). Plain data and text rules, no IO.

pub mod episode;
pub mod export;
pub mod platform;
pub mod text;
pub mod toc;

use serde::{Deserialize, Serialize};

pub use episode::{EpisodeInfo, EpisodeStatus};
pub use export::{ExportOptions, export_sheets, render_sheet};
pub use platform::{CountRule, MUNPIA_PAGE_CHARS, count_for, munpia_pages};
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
}

/// Per-episode length goal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Goal {
    pub count: u32,
    pub basis: GoalBasis,
}

/// Trash and deleted projects are kept this long before they are dropped for good.
pub const RETENTION_MS: i64 = 30 * 86_400_000;
