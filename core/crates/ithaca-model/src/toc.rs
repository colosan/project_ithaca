//! A project's table of contents (ADR-0002 §2): everything about a project except sheet text.
//! Stored as the chain of the reserved sheet id [`Toc::SHEET_ID`]; see core/FORMAT.md.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::{Goal, Language};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Toc {
    pub title: String,
    pub language: Language,
    #[serde(default)]
    pub goal: Option<Goal>,
    pub created: i64,
    /// Soft delete: kept 30 days, then the project folder is removed.
    #[serde(default)]
    pub deleted: Option<i64>,
    /// In the writer's order.
    pub folders: Vec<FolderEntry>,
    /// Every sheet that still has content, live or trashed.
    pub sheets: BTreeMap<String, SheetEntry>,
    /// Sheets deleted for good (tombstones, so a replica that still has them knows).
    #[serde(default)]
    pub removed: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FolderEntry {
    pub id: String,
    pub name: String,
    /// Deleted folders stay while the trash still holds their sheets, so restore can bring them back.
    #[serde(default)]
    pub deleted: Option<i64>,
    /// Serial order. Trashed sheets keep their slot so a restore puts them back where they were.
    pub sheets: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SheetEntry {
    pub created: i64,
    #[serde(default)]
    pub trashed: Option<i64>,
}

impl Toc {
    /// The reserved chain id of the table of contents. Sheet ids are never this.
    pub const SHEET_ID: &'static str = "toc";

    /// Canonical text form stored in the chain (pretty JSON: one field per line keeps deltas small).
    pub fn to_text(&self) -> String {
        serde_json::to_string_pretty(self).expect("toc serializes")
    }

    pub fn from_text(s: &str) -> Result<Toc, serde_json::Error> {
        serde_json::from_str(s)
    }

    pub fn folder(&self, id: &str) -> Option<&FolderEntry> {
        self.folders.iter().find(|f| f.id == id)
    }

    pub fn folder_mut(&mut self, id: &str) -> Option<&mut FolderEntry> {
        self.folders.iter_mut().find(|f| f.id == id)
    }

    /// The folder index and slot of a sheet.
    pub fn locate(&self, sheet: &str) -> Option<(usize, usize)> {
        self.folders
            .iter()
            .enumerate()
            .find_map(|(fi, f)| f.sheets.iter().position(|s| s == sheet).map(|si| (fi, si)))
    }

    pub fn is_trashed(&self, sheet: &str) -> bool {
        self.sheets.get(sheet).is_some_and(|s| s.trashed.is_some())
    }

    /// Live sheets of a folder in serial order.
    pub fn live_sheets<'a>(
        &'a self,
        folder: &'a FolderEntry,
    ) -> impl Iterator<Item = &'a String> + 'a {
        folder
            .sheets
            .iter()
            .filter(|s| self.sheets.get(*s).is_some_and(|e| e.trashed.is_none()))
    }

    /// Drops deleted folders whose last trashed sheet is gone.
    pub fn drop_empty_deleted_folders(&mut self) {
        self.folders
            .retain(|f| f.deleted.is_none() || !f.sheets.is_empty());
    }

    /// Removes a sheet everywhere and leaves a tombstone.
    pub fn remove_sheet(&mut self, sheet: &str) {
        for f in &mut self.folders {
            f.sheets.retain(|s| s != sheet);
        }
        self.sheets.remove(sheet);
        self.removed.insert(sheet.to_string());
        self.drop_empty_deleted_folders();
    }
}
