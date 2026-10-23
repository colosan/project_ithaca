//! Damaged sheets (added: qa1): a sheet whose blocks no longer read or verify shows its last good
//! text and refuses writes (`Corrupt`) until the writer recovers it — from a backup, or by keeping
//! the last good text. Nothing is erased: broken files move to `<project>/damaged/`.

use std::path::Path;

use ithaca_ledger::Kind;

use crate::error::{Result, StoreError};
use crate::format::PROJECTS_DIR;
use crate::fsutil::{copy_durable, sync_dir};
use crate::project::{self, Project, changes_dir};
use crate::{SheetSummary, Store, invalid};

impl Store {
    /// Live and trashed sheets of a project that are damaged, in the outline's order.
    pub fn damaged_sheets(&self, project: &str) -> Result<Vec<SheetSummary>> {
        let p = self.project(project)?;
        let mut out: Vec<SheetSummary> = p
            .damage
            .keys()
            .filter(|s| p.toc.sheets.contains_key(*s))
            .map(|s| Self::sheet_summary(p, s))
            .collect::<Result<_>>()?;
        out.sort_by(|a, b| {
            (a.trashed.is_some(), &a.folder, a.order).cmp(&(
                b.trashed.is_some(),
                &b.folder,
                b.order,
            ))
        });
        Ok(out)
    }

    /// Recovers a damaged sheet from the backups (newest first, every kind):
    /// 1. A broken block file whose exact copy (same hash, verifies) is in a backup is put back —
    ///    the history is whole again and nothing new is written.
    /// 2. Otherwise the newest backup that holds an intact version of the sheet gives its text:
    ///    the broken files move to `damaged/`, the last good text (if it differs from what's left)
    ///    and then the backup's text are written as new blocks. Older versions stay in history.
    ///
    /// Not damaged → InvalidInput; no backup has it intact → NotFound.
    pub fn recover_sheet_from_backup(
        &mut self,
        project: &str,
        sheet: &str,
    ) -> Result<SheetSummary> {
        self.writable()?;
        let p = self.check_sheet(project, sheet)?;
        let files = p
            .damage
            .get(sheet)
            .cloned()
            .ok_or_else(|| invalid("that sheet is not damaged"))?;
        let backups: Vec<String> = self.backups().into_iter().map(|b| b.path).collect();
        let in_backup = |b: &str| Path::new(b).join(PROJECTS_DIR).join(project);

        // 1. Exact copies.
        let mut repaired = false;
        for f in &files {
            if project::read_block(&p.dir, f).is_ok() {
                continue; // a block that is fine itself, only cut off by another
            }
            let good = backups
                .iter()
                .map(|b| in_backup(b))
                .find(|d| project::read_block(d, f).is_ok());
            if let Some(src) = good {
                p.set_aside(std::slice::from_ref(f))?;
                copy_durable(&changes_dir(&src).join(f), &changes_dir(&p.dir).join(f))?;
                sync_dir(&changes_dir(&p.dir))?;
                repaired = true;
            }
        }
        if repaired {
            self.reload(project)?;
            if !self.project(project)?.damage.contains_key(sheet) {
                return self.sheet_summary_of(project, sheet);
            }
        }

        // 2. The newest intact version in a backup.
        let text = backups
            .iter()
            .find_map(|b| {
                let bp = Project::load(project, &in_backup(b), false).ok()??;
                if bp.damage.contains_key(sheet) {
                    return None;
                }
                bp.chains.get(sheet).map(|c| c.text.clone())
            })
            .ok_or(StoreError::NotFound)?;
        self.resolve_damage(project, sheet, Some(text))
    }

    /// Makes a damaged sheet editable again with its last good text: the broken files move to
    /// `damaged/` and the text is written as a new block if it differs from what's left.
    pub fn keep_last_good_text(&mut self, project: &str, sheet: &str) -> Result<SheetSummary> {
        self.writable()?;
        if !self.check_sheet(project, sheet)?.damage.contains_key(sheet) {
            return Err(invalid("that sheet is not damaged"));
        }
        self.resolve_damage(project, sheet, None)
    }

    fn resolve_damage(
        &mut self,
        project: &str,
        sheet: &str,
        replacement: Option<String>,
    ) -> Result<SheetSummary> {
        let p = self.project(project)?;
        let last_good = p.chains.get(sheet).map(|c| c.text.clone());
        let files = p.damage.get(sheet).cloned().unwrap_or_default();
        p.set_aside(&files)?;
        self.reload(project)?;
        if let Some(d) = self.project(project)?.damage.get(sheet)
            && !d.is_empty()
        {
            return Err(StoreError::Corrupt(format!(
                "sheet still damaged after setting {} files aside",
                files.len()
            )));
        }
        // What's left is the verifiable prefix (or nothing); the sheet takes writes again.
        self.project_mut(project)?.damage.remove(sheet);
        for text in [last_good, replacement].into_iter().flatten() {
            let now = self.now();
            self.append(project, sheet, &text, Kind::Edit, now)?;
        }
        self.sheet_summary_of(project, sheet)
    }

    /// Loads a project again from its files (after files were moved around).
    fn reload(&mut self, project: &str) -> Result<()> {
        let dir = self.project(project)?.dir.clone();
        let p = Project::load(project, &dir, !self.read_only())?
            .ok_or_else(|| StoreError::Corrupt("the project no longer loads".into()))?;
        self.projects.insert(project.to_string(), p);
        Ok(())
    }
}
