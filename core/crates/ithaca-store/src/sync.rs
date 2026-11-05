//! Sync through a shared file store (added: sync, ADR-0013). Block files never change and are named by
//! their hash (ADR-0002), so two libraries agree by exchanging the files the other lacks. The store
//! itself — a GitHub repository today — is the app's business: the core only says which files it
//! has, what to send and fetch against a listing, and takes fetched files in.
//!
//! A file's path in the shared store is `projects/<project>/<chain>/<hash>` (the chain in the path
//! lets a store be pruned of a permanently deleted sheet without reading its files).

use std::collections::{BTreeMap, BTreeSet};
use std::fs;

use ithaca_ledger::block::is_hash_name;
use ithaca_ledger::{Actor, Block, Body, Kind};
use ithaca_model::Toc;

use crate::error::{Result, StoreError};
use crate::format::PROJECTS_DIR;
use crate::project::{self, Project, write_block, write_cache};
use crate::{Store, invalid};

/// The device name of merge blocks the sync writes: every device writes the same block for the
/// same fork, so two devices resolving it at once don't fork again.
pub const MERGE_DEVICE: &str = "sync";

/// What to do against a listing of the shared store.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncPlan {
    /// Here, not there: send these.
    pub upload: Vec<String>,
    /// There, not here: fetch these and hand them to [`Store::sync_ingest`].
    pub download: Vec<String>,
    /// There, but deleted here for good since the last sync (or a sheet's tombstone says so).
    pub delete_remote: Vec<String>,
}

/// One fetched file.
#[derive(Debug, Clone)]
pub struct SyncFile {
    pub path: String,
    pub bytes: Vec<u8>,
}

/// A sheet (or a project's table of contents, chain `toc`) whose text changed by an ingest.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct SyncChange {
    pub project: String,
    pub sheet: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncIngest {
    /// Files written (new to this library).
    pub added: u32,
    /// Paths left out, with why: malformed, not matching their hash, or of a deleted sheet.
    pub skipped: Vec<String>,
    /// Chains whose winning text changed, sorted.
    pub changed: Vec<SyncChange>,
    /// Projects that weren't here before.
    pub new_projects: Vec<String>,
}

struct Parsed<'a> {
    project: &'a str,
    chain: &'a str,
    hash: &'a str,
}

fn is_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn parse(path: &str) -> Option<Parsed<'_>> {
    let mut it = path.split('/');
    let (root, project, chain, hash) = (it.next()?, it.next()?, it.next()?, it.next()?);
    (root == PROJECTS_DIR
        && it.next().is_none()
        && is_id(project)
        && is_id(chain)
        && is_hash_name(hash))
    .then_some(Parsed {
        project,
        chain,
        hash,
    })
}

fn path_of(project: &str, chain: &str, hash: &str) -> String {
    format!("{PROJECTS_DIR}/{project}/{chain}/{hash}")
}

impl Store {
    /// Every block file of the library as a shared-store path (deleted projects included until
    /// they are purged), sorted. Broken files of a damaged sheet are not offered.
    pub fn sync_files(&self) -> Vec<String> {
        let mut v: Vec<String> = self
            .projects
            .values()
            .flat_map(|p| {
                p.chains.iter().flat_map(move |(chain, c)| {
                    c.metas.keys().map(move |h| path_of(&p.id, chain, h))
                })
            })
            .collect();
        v.sort();
        v
    }

    /// Compares this library with a listing of the shared store. `base` is the listing after the
    /// last sync (empty the first time): a file in it that one side no longer has was deleted for
    /// good on that side, so it is deleted on the other rather than brought back. Paths that are
    /// not block files are ignored.
    pub fn sync_plan(&self, remote: &[String], base: &[String]) -> SyncPlan {
        let local: BTreeSet<String> = self.sync_files().into_iter().collect();
        let remote: BTreeSet<&str> = remote
            .iter()
            .map(String::as_str)
            .filter(|p| parse(p).is_some())
            .collect();
        let base: BTreeSet<&str> = base.iter().map(String::as_str).collect();
        let mut plan = SyncPlan::default();
        for p in &local {
            if !remote.contains(p.as_str()) && !base.contains(p.as_str()) {
                plan.upload.push(p.clone());
            }
        }
        for p in &remote {
            if local.contains(*p) {
                continue;
            }
            let f = parse(p).expect("filtered");
            let tombstoned = self
                .projects
                .get(f.project)
                .is_some_and(|pr| pr.toc.removed.contains(f.chain));
            if tombstoned || base.contains(p) {
                plan.delete_remote.push(p.to_string());
            } else {
                plan.download.push(p.to_string());
            }
        }
        plan
    }

    /// The bytes of one of [`Store::sync_files`].
    pub fn sync_read(&self, path: &str) -> Result<Vec<u8>> {
        let f = parse(path).ok_or_else(|| invalid(format!("not a sync path: {path}")))?;
        let p = self.project(f.project)?;
        if !p
            .chains
            .get(f.chain)
            .is_some_and(|c| c.metas.contains_key(f.hash))
        {
            return Err(StoreError::NotFound);
        }
        Ok(fs::read(project::changes_dir(&p.dir).join(f.hash))?)
    }

    /// Takes in fetched files: each is checked (its hash, its chain) and written like any block,
    /// then the projects they belong to are read again. A table of contents that two devices
    /// changed apart is merged at once ([`Toc::merge_from`]); a sheet that forked keeps its branch
    /// copy as usual (ADR-0002). Nothing here deletes anything.
    pub fn sync_ingest(&mut self, files: Vec<SyncFile>) -> Result<SyncIngest> {
        self.writable()?;
        let mut out = SyncIngest::default();
        let mut touched: BTreeSet<String> = BTreeSet::new();
        for file in &files {
            let Some(f) = parse(&file.path) else {
                out.skipped
                    .push(format!("{} (not a block path)", file.path));
                continue;
            };
            let block = match Block::parse(&file.bytes) {
                Ok(b) if b.hash == f.hash && b.sheet == f.chain => b,
                Ok(_) => {
                    out.skipped
                        .push(format!("{} (does not match its path)", file.path));
                    continue;
                }
                Err(e) => {
                    out.skipped.push(format!("{} ({e})", file.path));
                    continue;
                }
            };
            let dir = self.root.join(PROJECTS_DIR).join(f.project);
            if let Some(p) = self.projects.get(f.project) {
                if p.toc.removed.contains(f.chain) {
                    out.skipped.push(format!("{} (deleted sheet)", file.path));
                    continue;
                }
                if p.chains
                    .get(f.chain)
                    .is_some_and(|c| c.metas.contains_key(f.hash))
                {
                    continue;
                }
            }
            write_block(&dir, &block)?;
            out.added += 1;
            touched.insert(f.project.to_string());
        }
        for id in touched {
            let before: BTreeMap<String, Option<String>> = self
                .projects
                .get(&id)
                .map(|p| {
                    p.chains
                        .iter()
                        .map(|(c, ch)| (c.clone(), ch.heads.winner.clone()))
                        .collect()
                })
                .unwrap_or_default();
            let known = self.projects.contains_key(&id);
            let dir = self.root.join(PROJECTS_DIR).join(&id);
            // A new project whose table of contents hasn't arrived yet stays invisible until it has.
            let Some(mut p) = Project::load(&id, &dir, true)? else {
                continue;
            };
            self.merge_toc(&mut p)?;
            for (chain, c) in &p.chains {
                if before.get(chain).cloned().flatten() != c.heads.winner {
                    out.changed.push(SyncChange {
                        project: id.clone(),
                        sheet: chain.clone(),
                    });
                }
            }
            if !known {
                out.new_projects.push(id.clone());
            }
            self.projects.insert(id, p);
        }
        out.changed.sort();
        Ok(out)
    }

    /// Resolves every branch of a project's table of contents with a merge block (snapshot of the
    /// merged table of contents, parents `[winner, branch]`). The block is the same on every
    /// device: device [`MERGE_DEVICE`], the later parent's time and epoch.
    fn merge_toc(&self, p: &mut Project) -> Result<()> {
        loop {
            let Some(chain) = p.chains.get(Toc::SHEET_ID) else {
                return Ok(());
            };
            let (Some(winner), Some(branch)) =
                (chain.head().cloned(), chain.heads.branches.first().cloned())
            else {
                return Ok(());
            };
            let other = chain
                .metas
                .get(&branch)
                .cloned()
                .ok_or(StoreError::NotFound)?;
            let theirs = p
                .text_at(&branch)
                .map_err(|e| StoreError::Corrupt(e.to_string()))?;
            let theirs = Toc::from_text(&theirs).map_err(|e| StoreError::Corrupt(e.to_string()))?;
            let mut toc = p.toc.clone();
            toc.merge_from(&theirs);
            let text = toc.to_text();
            let block = Block::seal(
                vec![winner.hash.clone(), branch.clone()],
                Toc::SHEET_ID,
                winner.epoch.max(other.epoch),
                MERGE_DEVICE,
                Actor::Me,
                Kind::Merge,
                winner.at.max(other.at),
                Body::Snapshot(text.clone()),
            );
            write_block(&p.dir, &block)?;
            let chain = p.chains.get_mut(Toc::SHEET_ID).expect("toc chain");
            let stats = ithaca_ledger::delta::apply("", &ithaca_ledger::delta::diff("", &text))
                .map(|r| r.1)
                .unwrap_or_default();
            chain.heads.branches.retain(|h| h != &branch);
            chain.push(ithaca_ledger::Meta::of(&block, 0, stats), text);
            write_cache(&p.dir, Toc::SHEET_ID, chain);
            p.toc = toc;
        }
    }
}
