//! A chain's shape: which blocks are valid, which is the head, which heads are branch copies.

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::LedgerError;
use crate::block::{Actor, Block, Body, Kind};
use crate::delta::{self, Stats};

/// Everything about a block except its body — small enough to keep for every block in memory and
/// in the derived cache.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Meta {
    pub hash: String,
    pub parents: Vec<String>,
    pub epoch: u64,
    pub device: String,
    pub actor: Actor,
    pub kind: Kind,
    pub at: i64,
    /// Deltas since the last snapshot on the first-parent line (0 for a snapshot).
    pub depth: u32,
    pub added: u32,
    pub removed: u32,
}

impl Meta {
    pub fn of(b: &Block, depth: u32, stats: Stats) -> Meta {
        Meta {
            hash: b.hash.clone(),
            parents: b.parents.clone(),
            epoch: b.epoch,
            device: b.device.clone(),
            actor: b.actor,
            kind: b.kind,
            at: b.at,
            depth,
            added: stats.added,
            removed: stats.removed,
        }
    }
}

/// ADR-0002 §4: of two blocks with the same parent, the higher epoch wins; on a tie the greater
/// device id (byte order); on a tie again (same device — never written by this core) the greater hash.
/// `Greater` means `a` wins.
pub fn fork_order(a: &Meta, b: &Meta) -> Ordering {
    a.epoch
        .cmp(&b.epoch)
        .then_with(|| a.device.cmp(&b.device))
        .then_with(|| a.hash.cmp(&b.hash))
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Heads {
    /// The block whose text is the sheet's text. `None` only for an empty chain.
    pub winner: Option<String>,
    /// Losing heads: branch copies, kept until a merge block resolves them.
    pub branches: Vec<String>,
}

fn first_parent_path<'a>(metas: &'a BTreeMap<String, Meta>, head: &str) -> Vec<&'a Meta> {
    let mut path = Vec::new();
    let mut cur = metas.get(head);
    let mut seen = HashSet::new();
    while let Some(m) = cur {
        if !seen.insert(&m.hash) {
            break;
        }
        path.push(m);
        cur = m.parents.first().and_then(|p| metas.get(p));
    }
    path.reverse();
    path
}

/// Compares two heads by the blocks right after the point where their first-parent lines part.
fn head_order(metas: &BTreeMap<String, Meta>, a: &str, b: &str) -> Ordering {
    let (pa, pb) = (first_parent_path(metas, a), first_parent_path(metas, b));
    for (x, y) in pa.iter().zip(&pb) {
        if x.hash != y.hash {
            return fork_order(x, y);
        }
    }
    pa.len().cmp(&pb.len())
}

/// Heads are blocks nobody names as a parent. With more than one, the sheet is branched.
pub fn select_heads(metas: &BTreeMap<String, Meta>) -> Heads {
    let parents: HashSet<&str> = metas
        .values()
        .flat_map(|m| m.parents.iter().map(String::as_str))
        .collect();
    let mut heads: Vec<&str> = metas
        .keys()
        .map(String::as_str)
        .filter(|h| !parents.contains(h))
        .collect();
    heads.sort_by(|a, b| head_order(metas, b, a)); // winner first
    let mut it = heads.into_iter().map(str::to_string);
    Heads {
        winner: it.next(),
        branches: it.collect(),
    }
}

/// The text after `block`, given the text after its first parent.
fn text_after(block: &Block, parent_text: Option<&str>) -> Result<(String, Stats), LedgerError> {
    match (&block.body, parent_text) {
        (Body::Snapshot(t), Some(p)) => {
            let (_, stats) = delta::apply(p, &delta::diff(p, t))?;
            Ok((t.clone(), stats))
        }
        (Body::Snapshot(t), None) => {
            let (_, stats) = delta::apply("", &delta::diff("", t))?;
            Ok((t.clone(), stats))
        }
        (Body::Delta(ops), Some(p)) => delta::apply(p, ops),
        (Body::Same, Some(p)) => Ok((p.to_string(), Stats::default())),
        (_, None) => Err(LedgerError::BadDelta("a delta needs a parent".into())),
    }
}

/// The result of reading a whole chain from its blocks.
#[derive(Debug, Clone, Default)]
pub struct Rebuilt {
    pub metas: BTreeMap<String, Meta>,
    pub heads: Heads,
    pub head_text: String,
    /// Blocks left out, with the reason (missing parent, bad delta).
    pub invalid: Vec<(String, LedgerError)>,
}

/// Validates a chain and finds its head. A block is valid when all its parents are valid and its body
/// applies to its first parent's text; anything downstream of an invalid block is left out too.
pub fn rebuild(blocks: impl IntoIterator<Item = Block>) -> Rebuilt {
    let blocks: HashMap<String, Block> = blocks.into_iter().map(|b| (b.hash.clone(), b)).collect();
    let (mut out, mut texts) = rebuild_texts(&blocks);
    out.head_text = out
        .heads
        .winner
        .as_ref()
        .and_then(|w| texts.remove(w))
        .unwrap_or_default();
    out
}

/// What [`salvage`] found in a chain with invalid blocks.
#[derive(Debug, Clone, Default)]
pub struct Salvaged {
    /// The valid blocks plus every block that verifies from a snapshot cut off by the damage.
    /// Metas keep their real parents.
    pub metas: BTreeMap<String, Meta>,
    /// The newest (by `at`) head among them: the last good text.
    pub head: Option<String>,
    pub text: String,
    /// The winner of the strictly valid part (the longest verifiable prefix), which new blocks
    /// may extend once the damage is dealt with.
    pub valid_head: Option<String>,
    pub valid_text: String,
}

/// For a chain with invalid blocks: the last good text. Strict validity ([`rebuild`]) keeps only the
/// blocks before the damage. A snapshot written after the damage is self-contained, though, so
/// it — and the deltas that follow it — still verify; the newer of the two lines is the last good
/// text. Nothing here is written anywhere.
pub fn salvage(blocks: impl IntoIterator<Item = Block>) -> Salvaged {
    let mut blocks: HashMap<String, Block> =
        blocks.into_iter().map(|b| (b.hash.clone(), b)).collect();
    let (strict, mut strict_texts) = rebuild_texts(&blocks);
    let valid_text = strict
        .heads
        .winner
        .as_ref()
        .and_then(|w| strict_texts.remove(w))
        .unwrap_or_default();
    // Cut the snapshots among the invalid blocks loose from their (broken) parents.
    let mut cut: HashMap<String, Vec<String>> = HashMap::new();
    for (h, _) in &strict.invalid {
        if let Some(b) = blocks.get_mut(h)
            && matches!(b.body, Body::Snapshot(_))
            && !b.parents.is_empty()
        {
            cut.insert(h.clone(), std::mem::take(&mut b.parents));
        }
    }
    let (mut loose, mut texts) = rebuild_texts(&blocks);
    for (h, parents) in cut {
        if let Some(m) = loose.metas.get_mut(&h) {
            m.parents = parents;
        }
    }
    let head = loose
        .metas
        .values()
        .filter(|m| texts.contains_key(&m.hash))
        .filter(|m| {
            // A head of the loosened chain: nobody valid builds on it.
            !loose
                .metas
                .values()
                .any(|c| c.parents.first() == Some(&m.hash))
        })
        .max_by(|a, b| a.at.cmp(&b.at).then_with(|| fork_order(a, b)))
        .map(|m| m.hash.clone());
    let text = head
        .as_ref()
        .and_then(|h| texts.remove(h))
        .unwrap_or_default();
    Salvaged {
        metas: loose.metas,
        head,
        text,
        valid_head: strict.heads.winner,
        valid_text,
    }
}

/// [`rebuild`] without picking the head text: every valid block's text, by hash.
fn rebuild_texts(blocks: &HashMap<String, Block>) -> (Rebuilt, HashMap<String, String>) {
    let mut out = Rebuilt::default();
    let mut texts: HashMap<String, String> = HashMap::new();
    // Kahn's algorithm over parent edges; blocks whose parents never resolve are invalid.
    let mut waiting: HashMap<&str, usize> = HashMap::new();
    let mut children: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut ready: Vec<&str> = Vec::new();
    for b in blocks.values() {
        let n = b.parents.len();
        for p in &b.parents {
            children.entry(p.as_str()).or_default().push(&b.hash);
        }
        if n == 0 {
            ready.push(&b.hash);
        } else {
            waiting.insert(&b.hash, n);
        }
    }
    ready.sort_unstable(); // deterministic
    while let Some(h) = ready.pop() {
        let b = &blocks[h];
        let parent = b.first_parent();
        let parent_text = parent.and_then(|p| texts.get(p)).map(String::as_str);
        match text_after(b, parent_text) {
            Ok((text, stats)) => {
                let depth = match (&b.body, parent.and_then(|p| out.metas.get(p))) {
                    (Body::Snapshot(_), _) | (_, None) => 0,
                    (_, Some(pm)) => pm.depth + 1,
                };
                out.metas.insert(h.to_string(), Meta::of(b, depth, stats));
                texts.insert(h.to_string(), text);
                for c in children.get(h).into_iter().flatten() {
                    if let Some(n) = waiting.get_mut(c) {
                        *n -= 1;
                        if *n == 0 {
                            waiting.remove(c);
                            ready.push(c);
                        }
                    }
                }
            }
            Err(e) => out.invalid.push((h.to_string(), e)),
        }
    }
    for h in waiting.keys() {
        let missing = blocks[*h]
            .parents
            .iter()
            .find(|p| !out.metas.contains_key(*p))
            .cloned()
            .unwrap_or_default();
        out.invalid
            .push((h.to_string(), LedgerError::Missing(missing)));
    }
    out.invalid.sort_by(|a, b| a.0.cmp(&b.0));
    out.heads = select_heads(&out.metas);
    (out, texts)
}

/// The text after block `hash`, loading blocks back along the first-parent line to the nearest snapshot.
pub fn reconstruct(
    hash: &str,
    mut load: impl FnMut(&str) -> Result<Block, LedgerError>,
) -> Result<String, LedgerError> {
    let mut stack = Vec::new();
    let mut cur = hash.to_string();
    let base = loop {
        let b = load(&cur)?;
        match &b.body {
            Body::Snapshot(t) => break t.clone(),
            _ => {
                let p = b
                    .first_parent()
                    .ok_or_else(|| LedgerError::BadDelta("a delta needs a parent".into()))?
                    .to_string();
                stack.push(b);
                cur = p;
            }
        }
    };
    let mut text = base;
    while let Some(b) = stack.pop() {
        text = text_after(&b, Some(&text))?.0;
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block::{Actor, Kind};

    fn edit(parent: Option<&Block>, epoch: u64, device: &str, at: i64, body: Body) -> Block {
        Block::seal(
            parent.map(|p| vec![p.hash.clone()]).unwrap_or_default(),
            "s",
            epoch,
            device,
            Actor::Me,
            Kind::Edit,
            at,
            body,
        )
    }

    fn delta(from: &str, to: &str) -> Body {
        Body::Delta(delta::diff(from, to))
    }

    #[test]
    fn linear_chain_head_and_text() {
        let a = edit(None, 1, "d1", 1, Body::Snapshot("하나".into()));
        let b = edit(Some(&a), 1, "d1", 2, delta("하나", "하나 둘"));
        let c = edit(Some(&b), 1, "d1", 3, delta("하나 둘", "하나 둘 셋"));
        let r = rebuild([c.clone(), a.clone(), b.clone()]);
        assert_eq!(r.heads.winner.as_deref(), Some(c.hash.as_str()));
        assert!(r.heads.branches.is_empty());
        assert_eq!(r.head_text, "하나 둘 셋");
        assert_eq!(r.metas[&c.hash].depth, 2);
        assert_eq!((r.metas[&c.hash].added, r.metas[&c.hash].removed), (2, 0));
        let all: HashMap<_, _> = [a, b.clone(), c]
            .into_iter()
            .map(|x| (x.hash.clone(), x))
            .collect();
        let load = |h: &str| all.get(h).cloned().ok_or(LedgerError::Missing(h.into()));
        assert_eq!(reconstruct(&b.hash, load).unwrap(), "하나 둘");
    }

    #[test]
    fn higher_epoch_wins_a_fork() {
        let a = edit(None, 1, "d1", 1, Body::Snapshot("base".into()));
        let low = edit(Some(&a), 1, "zzz", 5, delta("base", "base low"));
        let high = edit(Some(&a), 2, "aaa", 2, delta("base", "base high"));
        let after_low = edit(Some(&low), 1, "zzz", 9, delta("base low", "base low more"));
        let r = rebuild([a, low, high.clone(), after_low.clone()]);
        assert_eq!(r.heads.winner, Some(high.hash));
        assert_eq!(r.heads.branches, vec![after_low.hash]); // the loser is kept, with its later edits
        assert_eq!(r.head_text, "base high");
    }

    #[test]
    fn same_epoch_falls_back_to_device_id() {
        let a = edit(None, 3, "d0", 1, Body::Snapshot("x".into()));
        let from_a = edit(Some(&a), 3, "device-a", 7, delta("x", "xa"));
        let from_b = edit(Some(&a), 3, "device-b", 2, delta("x", "xb"));
        // Order of arrival does not matter.
        for blocks in [
            vec![a.clone(), from_a.clone(), from_b.clone()],
            vec![from_b.clone(), a.clone(), from_a.clone()],
        ] {
            let r = rebuild(blocks);
            assert_eq!(r.heads.winner.as_deref(), Some(from_b.hash.as_str()));
            assert_eq!(r.heads.branches, vec![from_a.hash.clone()]);
        }
    }

    #[test]
    fn merge_resolves_a_branch() {
        let a = edit(None, 1, "d1", 1, Body::Snapshot("x".into()));
        let l = edit(Some(&a), 1, "d1", 2, delta("x", "xl"));
        let r_ = edit(Some(&a), 1, "d2", 2, delta("x", "xr"));
        let m = Block::seal(
            vec![r_.hash.clone(), l.hash.clone()],
            "s",
            2,
            "d2",
            Actor::Me,
            Kind::Merge,
            3,
            Body::Snapshot("xlr".into()),
        );
        let r = rebuild([a, l, r_, m.clone()]);
        assert_eq!(r.heads.winner, Some(m.hash));
        assert!(r.heads.branches.is_empty());
        assert_eq!(r.head_text, "xlr");
    }

    #[test]
    fn salvage_finds_the_newest_text_that_verifies() {
        let a = edit(None, 1, "d1", 1, Body::Snapshot("abc".into()));
        let b = edit(Some(&a), 1, "d1", 2, delta("abc", "abcd"));
        let c = edit(Some(&b), 1, "d1", 3, Body::Snapshot("abcde".into()));
        let d = edit(Some(&c), 1, "d1", 4, delta("abcde", "abcdef"));
        // `b` is lost: strictly only `a` is valid, but the snapshot `c` and its delta `d` verify.
        let s = salvage([a.clone(), c.clone(), d.clone()]);
        assert_eq!(s.valid_head, Some(a.hash.clone()));
        assert_eq!(s.valid_text, "abc");
        assert_eq!(s.head, Some(d.hash.clone()));
        assert_eq!(s.text, "abcdef");
        assert_eq!(s.metas[&c.hash].parents, vec![b.hash.clone()]);
        // Without a later snapshot, the prefix is all there is.
        let s = salvage([a.clone(), d]);
        assert_eq!((s.head, s.text.as_str()), (Some(a.hash), "abc"));
    }

    #[test]
    fn missing_parent_and_bad_delta_are_left_out() {
        let a = edit(None, 1, "d1", 1, Body::Snapshot("abc".into()));
        let b = edit(Some(&a), 1, "d1", 2, delta("abc", "abcd"));
        let c = edit(Some(&b), 1, "d1", 3, delta("abcd", "abcde"));
        let r = rebuild([a.clone(), c.clone()]);
        assert_eq!(r.heads.winner, Some(a.hash.clone()));
        assert!(matches!(&r.invalid[..], [(h, LedgerError::Missing(_))] if *h == c.hash));
        let bad = edit(
            Some(&a),
            1,
            "d1",
            2,
            Body::Delta(vec![delta::Op::Retain(10)]),
        );
        let r = rebuild([a.clone(), bad.clone()]);
        assert_eq!(r.heads.winner, Some(a.hash));
        assert_eq!(r.invalid.len(), 1);
    }
}
