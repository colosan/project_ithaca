//! Hash chain ledger (ADR-0002). Pure: no files, no network.
//!
//! - [`block`]: the immutable block, its canonical encoding and hash.
//! - [`delta`]: text deltas between consecutive blocks.
//! - [`chain`]: validity, heads and the deterministic branch decision.

pub mod block;
pub mod chain;
pub mod delta;

pub use block::{Actor, BLOCK_VERSION, Block, Body, Kind};
pub use chain::{
    Heads, Meta, Rebuilt, Salvaged, fork_order, rebuild, reconstruct, reconstruct_known, salvage,
    select_heads,
};
pub use delta::Op;
pub use delta::Stats;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LedgerError {
    /// Not a block this core can read (bad JSON, unknown version, …).
    Malformed(String),
    /// The content does not hash to its `hash`.
    HashMismatch { stated: String, actual: String },
    /// A delta does not fit the text it applies to.
    BadDelta(String),
    /// A block needed to rebuild the text is missing.
    Missing(String),
}

impl std::fmt::Display for LedgerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LedgerError::Malformed(m) => write!(f, "malformed block: {m}"),
            LedgerError::HashMismatch { stated, actual } => {
                write!(f, "hash mismatch: stated {stated}, content {actual}")
            }
            LedgerError::BadDelta(m) => write!(f, "bad delta: {m}"),
            LedgerError::Missing(h) => write!(f, "missing block {h}"),
        }
    }
}

impl std::error::Error for LedgerError {}
