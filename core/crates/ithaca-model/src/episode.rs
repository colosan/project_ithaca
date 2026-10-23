//! Serial-episode metadata a writer keeps per sheet (design/PRODUCT.md "회차 정보", research §1.3).
//! Ithaca never uploads anywhere; this only records what was, or will be, published where.

use serde::{Deserialize, Serialize};

/// Where an episode stands. `비축분` (stock) = episodes not yet `Published`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum EpisodeStatus {
    /// `초고`
    #[default]
    Draft,
    /// `퇴고`
    Revising,
    /// `예약` — handed to a platform with a publish time.
    Scheduled,
    /// `발행`
    Published,
}

/// Stored in the table of contents next to the sheet (FORMAT.md §toc, `"episode"`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct EpisodeInfo {
    /// The writer's episode number. `None` = an episode without a number yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub number: Option<u32>,
    #[serde(default)]
    pub status: EpisodeStatus,
    /// Unix ms: when it was (or is scheduled to be) published.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub publish_at: Option<i64>,
    /// Free text, e.g. "문피아". Not an enum: platforms come and go.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
}
