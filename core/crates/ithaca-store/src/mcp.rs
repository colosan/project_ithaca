//! `<library>/mcp.json`: what the Claude connector (`ithaca-mcp`) may see (added: r3).
//!
//! The app writes it from Settings → Claude; the server reads it on every request, so a change
//! applies to the next tool call without restarting Claude. Missing, unreadable or `enabled:
//! false` all mean "Claude sees nothing" (core/FORMAT.md §mcp.json).

use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::{Result, StoreError};
use crate::fsutil::write_atomic;

pub const MCP_FILE: &str = "mcp.json";

/// What Claude may do with the exposed projects. Only `Read` exists today (design/PRODUCT.md:
/// read-only by default); `Edit` will add write tools recorded as `actor: claude`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum McpPermission {
    #[default]
    Read,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct McpSettings {
    #[serde(default)]
    pub enabled: bool,
    /// Project ids the writer chose to show Claude. Others are invisible to every tool.
    #[serde(default)]
    pub projects: Vec<String>,
    /// An unknown value (a newer app's) reads as `Read`, never as more.
    #[serde(default, deserialize_with = "lenient_permission")]
    pub permission: McpPermission,
    /// Fields a newer app may add; kept when rewritten.
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

fn lenient_permission<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<McpPermission, D::Error> {
    let v = Value::deserialize(d)?;
    Ok(serde_json::from_value(v).unwrap_or_default())
}

impl McpSettings {
    /// `Ok(None)` when the file is missing. A file that doesn't parse is `Corrupt`.
    pub fn read(root: &Path) -> Result<Option<McpSettings>> {
        match fs::read(root.join(MCP_FILE)) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|e| StoreError::Corrupt(format!("{MCP_FILE}: {e}"))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Written atomically (temp file, flush, rename), so the server never reads half a file.
    pub fn write(&self, root: &Path) -> Result<()> {
        let mut bytes = serde_json::to_vec_pretty(self).expect("mcp settings serialize");
        bytes.push(b'\n');
        Ok(write_atomic(&root.join(MCP_FILE), &bytes, true)?)
    }

    /// Whether `project` is visible to Claude.
    pub fn exposes(&self, project: &str) -> bool {
        self.enabled && self.projects.iter().any(|p| p == project)
    }
}

impl crate::Store {
    /// (added: r3) The connector settings; defaults (off, nothing shown) when the file is missing
    /// or unreadable, so the app can always show and rewrite them.
    pub fn mcp_settings(&self) -> McpSettings {
        McpSettings::read(self.root())
            .ok()
            .flatten()
            .unwrap_or_default()
    }

    /// (added: r3) Rewrites `mcp.json` atomically, keeping fields this core does not know. Project
    /// ids are kept in the order given, without duplicates; unknown ids are kept too (a project
    /// restored later keeps its choice). Read-only library → ReadOnly.
    pub fn set_mcp_settings(&mut self, enabled: bool, projects: &[String]) -> Result<McpSettings> {
        if self.read_only() {
            return Err(StoreError::ReadOnly);
        }
        let mut s = self.mcp_settings();
        s.enabled = enabled;
        s.projects.clear();
        for p in projects {
            if !s.projects.contains(p) {
                s.projects.push(p.clone());
            }
        }
        s.write(self.root())?;
        Ok(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_unknown_and_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(McpSettings::read(dir.path()).unwrap(), None);
        fs::write(
            dir.path().join(MCP_FILE),
            r#"{"enabled":true,"projects":["a"],"permission":"edit","newer":1}"#,
        )
        .unwrap();
        let s = McpSettings::read(dir.path()).unwrap().unwrap();
        assert_eq!(s.permission, McpPermission::Read);
        assert!(s.exposes("a") && !s.exposes("b"));
        s.write(dir.path()).unwrap();
        let back = McpSettings::read(dir.path()).unwrap().unwrap();
        assert_eq!(back.extra.get("newer"), Some(&Value::from(1)));
        fs::write(dir.path().join(MCP_FILE), "{").unwrap();
        assert!(matches!(
            McpSettings::read(dir.path()),
            Err(StoreError::Corrupt(_))
        ));
    }
}
