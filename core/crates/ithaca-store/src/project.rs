//! One project folder: its chains (sheets + table of contents), loaded from blocks and the
//! rebuildable cache. See core/FORMAT.md §Project folder and §Cache.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use ithaca_ledger::block::is_hash_name;
use ithaca_ledger::{Block, Heads, LedgerError, Meta, rebuild, reconstruct, salvage};
use ithaca_model::{Counts, Toc, counts};
use serde::{Deserialize, Serialize};

use crate::error::{Result, StoreError};
use crate::fsutil::{is_temp, list, write_atomic};

pub const CHANGES_DIR: &str = "changes";
pub const CACHE_DIR: &str = "cache";
/// Block files taken out of `changes/` when a damaged sheet is recovered (added: qa1). Kept, never read.
pub const DAMAGED_DIR: &str = "damaged";
/// 2 (added: safety): `head` and `textHash` bind the cached text to the chain head. Version-1
/// caches are ignored and rebuilt from blocks.
const CACHE_VERSION: u32 = 2;

/// One chain in memory: every block's metadata, the heads, and the head text.
#[derive(Debug, Clone, Default)]
pub struct Chain {
    pub metas: BTreeMap<String, Meta>,
    pub heads: Heads,
    pub text: String,
    pub counts: Counts,
}

impl Chain {
    fn new(metas: BTreeMap<String, Meta>, heads: Heads, text: String) -> Chain {
        let counts = counts(&text);
        Chain {
            metas,
            heads,
            text,
            counts,
        }
    }

    pub fn head(&self) -> Option<&Meta> {
        self.heads.winner.as_ref().and_then(|h| self.metas.get(h))
    }

    pub fn branched(&self) -> bool {
        !self.heads.branches.is_empty()
    }

    /// Records a block that extends the winning head.
    pub fn push(&mut self, meta: Meta, text: String) {
        let hash = meta.hash.clone();
        if meta.parents.first() == self.heads.winner.as_ref() {
            self.heads.winner = Some(hash.clone());
        } else {
            self.heads.branches.push(hash.clone());
        }
        self.metas.insert(hash, meta);
        self.counts = counts(&text);
        self.text = text;
    }
}

/// The derived per-chain cache file. Deleting it loses nothing. It is not flushed to disk: a cache
/// that fails to parse or to verify is simply rebuilt from blocks.
#[derive(Serialize, Deserialize)]
struct ChainCache {
    v: u32,
    sheet: String,
    metas: Vec<Meta>,
    winner: Option<String>,
    branches: Vec<String>,
    text: String,
    /// The winning head the text belongs to (same as `winner`; checked on load).
    head: Option<String>,
    /// blake3 (hex) of `text`.
    #[serde(rename = "textHash")]
    text_hash: String,
}

fn text_hash(text: &str) -> String {
    blake3::hash(text.as_bytes()).to_hex().to_string()
}

impl ChainCache {
    /// The cache is internally consistent: its text is the text it was written with, for the head
    /// it names, and that head is one of its blocks. A cache that fails this is rebuilt.
    fn consistent(&self) -> bool {
        self.head == self.winner
            && self
                .head
                .as_ref()
                .is_none_or(|h| self.metas.iter().any(|m| &m.hash == h))
            && self.text_hash == text_hash(&self.text)
    }
}

#[derive(Debug, Clone)]
pub struct Project {
    pub id: String,
    pub dir: PathBuf,
    pub toc: Toc,
    pub chains: HashMap<String, Chain>,
    /// (added: qa1) Chains that lost blocks: chain id → the block files behind the damage (files
    /// that don't read or don't match their hash, and blocks that no longer verify because of
    /// them). A damaged chain shows its last good text and takes no new blocks until recovered.
    /// A sheet the table of contents names but that has no block left is damaged with no files.
    pub damage: BTreeMap<String, Vec<String>>,
    /// (added: qa4) How many of a damaged chain's `damage` files are themselves broken (don't read
    /// or don't match their hash); the rest only depend on them.
    pub damage_direct: BTreeMap<String, usize>,
    /// Block files that don't read and whose chain can't be told.
    pub unattributed: Vec<String>,
}

/// The chain a block file that doesn't parse probably belongs to: its `"sheet"` field, read as
/// leniently as possible (the damage may be anywhere else in the file).
fn guess_chain(dir: &Path, name: &str) -> Option<String> {
    let bytes = fs::read(changes_dir(dir).join(name)).ok()?;
    if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes)
        && let Some(s) = v.get("sheet").and_then(|s| s.as_str())
    {
        return Some(s.to_string());
    }
    let text = String::from_utf8_lossy(&bytes);
    let start = text.find("\"sheet\":\"")? + "\"sheet\":\"".len();
    let len = text[start..].find('"')?;
    Some(text[start..start + len].to_string())
}

/// Cache file name for a chain id; ids that aren't plain get hashed so they stay valid file names.
fn cache_name(sheet: &str) -> String {
    if !sheet.is_empty()
        && sheet.len() <= 64
        && sheet
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        format!("{sheet}.json")
    } else {
        format!("{}.json", &blake3::hash(sheet.as_bytes()).to_hex()[..32])
    }
}

pub fn changes_dir(dir: &Path) -> PathBuf {
    dir.join(CHANGES_DIR)
}

pub fn read_block(dir: &Path, hash: &str) -> std::result::Result<Block, LedgerError> {
    let block = match fs::read(changes_dir(dir).join(hash)) {
        Ok(bytes) => Block::parse(&bytes)?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(LedgerError::Missing(hash.to_string()));
        }
        Err(e) => return Err(LedgerError::Malformed(e.to_string())),
    };
    if block.hash != hash {
        return Err(LedgerError::HashMismatch {
            stated: hash.to_string(),
            actual: block.hash,
        });
    }
    Ok(block)
}

/// Writes a block file (temp + fsync + rename). An existing file with the same name is the same block.
pub fn write_block(dir: &Path, block: &Block) -> Result<()> {
    let path = changes_dir(dir).join(&block.hash);
    if path.exists() {
        return Ok(());
    }
    fs::create_dir_all(changes_dir(dir))?;
    Ok(write_atomic(&path, &block.to_bytes(), true)?)
}

pub fn write_cache(dir: &Path, sheet: &str, chain: &Chain) {
    let cache = ChainCache {
        v: CACHE_VERSION,
        sheet: sheet.to_string(),
        metas: chain.metas.values().cloned().collect(),
        winner: chain.heads.winner.clone(),
        branches: chain.heads.branches.clone(),
        text: chain.text.clone(),
        head: chain.heads.winner.clone(),
        text_hash: text_hash(&chain.text),
    };
    let cache_dir = dir.join(CACHE_DIR);
    // The cache is an optimisation: a failed write only makes the next open slower.
    if fs::create_dir_all(&cache_dir).is_ok() {
        let _ = write_atomic(
            &cache_dir.join(cache_name(sheet)),
            &serde_json::to_vec(&cache).unwrap_or_default(),
            false,
        );
    }
}

pub fn remove_cache(dir: &Path, sheet: &str) {
    let _ = fs::remove_file(dir.join(CACHE_DIR).join(cache_name(sheet)));
}

fn read_caches(dir: &Path) -> Vec<ChainCache> {
    let cache_dir = dir.join(CACHE_DIR);
    list(&cache_dir)
        .unwrap_or_default()
        .into_iter()
        .filter(|n| n.ends_with(".json") && !is_temp(n))
        .filter_map(|n| fs::read(cache_dir.join(n)).ok())
        .filter_map(|b| serde_json::from_slice::<ChainCache>(&b).ok())
        .filter(|c| c.v == CACHE_VERSION)
        .collect()
}

impl Project {
    /// Loads a project folder. Returns `None` for a folder without a readable table of contents
    /// (e.g. a create that crashed before its first block). `writable` (the caller holds the
    /// library lock) allows cache writes and cleanup, done only once the project loaded.
    pub fn load(id: &str, dir: &Path, writable: bool) -> Result<Option<Project>> {
        let changes = changes_dir(dir);
        let mut names: HashSet<String> = HashSet::new();
        let mut temps = Vec::new();
        for name in list(&changes)? {
            if is_temp(&name) {
                temps.push(name);
            } else if is_hash_name(&name) {
                names.insert(name);
            }
        }

        // Trust a cache only if every block it lists is still there.
        let mut chains: HashMap<String, Chain> = HashMap::new();
        let mut covered: HashSet<String> = HashSet::new();
        let mut dirty: HashMap<String, Vec<String>> = HashMap::new();
        for c in read_caches(dir) {
            let hashes: Vec<String> = c.metas.iter().map(|m| m.hash.clone()).collect();
            covered.extend(hashes.iter().cloned());
            if c.consistent()
                && hashes.iter().all(|h| names.contains(h))
                && !chains.contains_key(&c.sheet)
            {
                let metas = c.metas.into_iter().map(|m| (m.hash.clone(), m)).collect();
                chains.insert(
                    c.sheet,
                    Chain::new(
                        metas,
                        Heads {
                            winner: c.winner,
                            branches: c.branches,
                        },
                        c.text,
                    ),
                );
            } else {
                dirty
                    .entry(c.sheet)
                    .or_default()
                    .extend(hashes.into_iter().filter(|h| names.contains(h)));
            }
        }
        // Blocks no cache knows about: read them to learn their chain.
        let mut fresh: HashMap<String, Vec<Block>> = HashMap::new();
        // Files that don't read or don't verify, with the chain they seem to belong to.
        let mut bad: Vec<(String, Option<String>)> = Vec::new();
        for name in names.iter().filter(|n| !covered.contains(*n)) {
            match read_block(dir, name) {
                Ok(b) => fresh.entry(b.sheet.clone()).or_default().push(b),
                Err(_) => bad.push((name.clone(), guess_chain(dir, name))),
            }
        }
        let mut unattributed = Vec::new();
        let mut by_chain: HashMap<String, Vec<String>> = HashMap::new();
        for (name, chain) in bad {
            match chain {
                Some(c) => by_chain.entry(c).or_default().push(name),
                None => unattributed.push(name),
            }
        }
        // A chain with new or broken blocks no cache knows is rebuilt from all its blocks.
        for sheet in fresh.keys().chain(by_chain.keys()) {
            if let Some(chain) = chains.remove(sheet) {
                dirty
                    .entry(sheet.clone())
                    .or_default()
                    .extend(chain.metas.into_keys());
            }
        }
        // Every rebuilt chain's blocks are read below, so their hashes are verified (Block::parse).
        let mut rebuilt_ids = BTreeSet::new();
        let mut damage: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let mut damage_direct: BTreeMap<String, usize> = BTreeMap::new();
        for sheet in dirty
            .keys()
            .chain(fresh.keys())
            .chain(by_chain.keys())
            .cloned()
            .collect::<BTreeSet<_>>()
        {
            let mut blocks: Vec<Block> = fresh.remove(&sheet).unwrap_or_default();
            let mut broken = by_chain.remove(&sheet).unwrap_or_default();
            for h in dirty.remove(&sheet).unwrap_or_default() {
                match read_block(dir, &h) {
                    Ok(b) => blocks.push(b),
                    Err(_) => broken.push(h),
                }
            }
            let r = rebuild(blocks.clone());
            if broken.is_empty() && r.invalid.is_empty() {
                if r.metas.is_empty() {
                    continue;
                }
                chains.insert(sheet.clone(), Chain::new(r.metas, r.heads, r.head_text));
                rebuilt_ids.insert(sheet);
                continue;
            }
            // Damaged: show the last good text, remember what is broken, never cache it (so
            // every open finds the damage again until it is recovered).
            let direct: BTreeSet<String> = broken.iter().cloned().collect();
            broken.extend(r.invalid.into_iter().map(|(h, _)| h));
            broken.sort();
            broken.dedup();
            damage_direct.insert(sheet.clone(), direct.len());
            let s = salvage(blocks);
            if !s.metas.is_empty() {
                let heads = Heads {
                    winner: s.head.clone(),
                    branches: vec![],
                };
                chains.insert(sheet.clone(), Chain::new(s.metas, heads, s.text));
            }
            damage.insert(sheet, broken);
        }
        let Some(toc_chain) = chains.get(Toc::SHEET_ID) else {
            return Ok(None);
        };
        let toc = Toc::from_text(&toc_chain.text)
            .map_err(|e| StoreError::Corrupt(format!("table of contents of {id}: {e}")))?;
        // A sheet the table of contents names has at least one block (blocks are written first):
        // none at all means its files are gone or unreadable.
        for sheet in toc.sheets.keys() {
            if !chains.contains_key(sheet) {
                damage.entry(sheet.clone()).or_default();
            }
        }
        // Damage guessed for a chain the project doesn't know is not a sheet's.
        damage.retain(|c, files| {
            let known = c == Toc::SHEET_ID || toc.sheets.contains_key(c) || chains.contains_key(c);
            if !known {
                unattributed.append(files);
            }
            known
        });
        // Only a project that loaded is written to (caches, cleanup); one that failed stays as it is.
        if writable {
            for sheet in &rebuilt_ids {
                write_cache(dir, sheet, &chains[sheet]);
            }
            for sheet in damage.keys() {
                remove_cache(dir, sheet);
            }
        }
        unattributed.sort();
        let mut project = Project {
            id: id.to_string(),
            dir: dir.to_path_buf(),
            toc,
            chains,
            damage,
            damage_direct,
            unattributed,
        };
        if writable {
            // Writes that never finished: never part of the library. `writable` means this open
            // holds the library lock, so no other process can be writing them right now.
            for name in temps {
                let _ = fs::remove_file(changes.join(&name));
            }
            // A permanent delete that stopped between its tombstone and removing the files.
            let leftovers: Vec<String> = project
                .toc
                .removed
                .iter()
                .filter(|s| project.chains.contains_key(*s))
                .cloned()
                .collect();
            for s in leftovers {
                project.remove_chain_files(&s);
            }
        }
        Ok(Some(project))
    }

    /// Text after any block of a chain.
    pub fn text_at(&self, hash: &str) -> std::result::Result<String, LedgerError> {
        reconstruct(hash, |h| read_block(&self.dir, h))
    }

    /// Removes a chain's block files and cache (permanent delete; the toc tombstone is written first).
    pub fn remove_chain_files(&mut self, sheet: &str) {
        if let Some(chain) = self.chains.remove(sheet) {
            for h in chain.metas.keys() {
                let _ = fs::remove_file(changes_dir(&self.dir).join(h));
            }
        }
        for h in self.damage.remove(sheet).unwrap_or_default() {
            let _ = fs::remove_file(changes_dir(&self.dir).join(h));
        }
        remove_cache(&self.dir, sheet);
    }

    /// Moves block files out of `changes/` into `damaged/` (kept, never read again).
    pub fn set_aside(&self, files: &[String]) -> Result<()> {
        let dst = self.dir.join(DAMAGED_DIR);
        fs::create_dir_all(&dst)?;
        for f in files {
            let src = changes_dir(&self.dir).join(f);
            if !src.exists() {
                continue;
            }
            let mut to = dst.join(f);
            let mut n = 2;
            while to.exists() {
                to = dst.join(format!("{f}-{n}"));
                n += 1;
            }
            fs::rename(&src, &to)?;
        }
        crate::fsutil::sync_dir(&changes_dir(&self.dir))?;
        crate::fsutil::sync_dir(&dst)?;
        Ok(())
    }
}
