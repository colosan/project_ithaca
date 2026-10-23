//! Text deltas. Positions count Unicode scalar values (Rust `char`s), so a delta never splits UTF-8.
//!
//! Encoding (FORMAT.md §Delta): a JSON array where a positive integer keeps that many characters,
//! a negative integer deletes that many, and a string inserts itself. Characters left after the last
//! op are kept.

use std::time::{Duration, Instant};

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use similar::{Algorithm, DiffOp, capture_diff_slices_deadline};
use unicode_segmentation::UnicodeSegmentation;

use crate::LedgerError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    Retain(usize),
    Delete(usize),
    Insert(String),
}

impl Serialize for Op {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            Op::Retain(n) => s.serialize_i64(*n as i64),
            Op::Delete(n) => s.serialize_i64(-(*n as i64)),
            Op::Insert(t) => s.serialize_str(t),
        }
    }
}

impl<'de> Deserialize<'de> for Op {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Raw {
            N(i64),
            S(String),
        }
        match Raw::deserialize(d)? {
            Raw::N(n) if n > 0 => Ok(Op::Retain(n as usize)),
            Raw::N(n) if n < 0 => Ok(Op::Delete(n.unsigned_abs() as usize)),
            Raw::N(_) => Err(serde::de::Error::custom("zero-length op")),
            Raw::S(t) if !t.is_empty() => Ok(Op::Insert(t)),
            Raw::S(_) => Err(serde::de::Error::custom("empty insert")),
        }
    }
}

/// Time budget for the character diff of the changed middle; past it the diff gets coarser, never wrong.
const DIFF_BUDGET: Duration = Duration::from_millis(30);

fn push(ops: &mut Vec<Op>, op: Op) {
    match (ops.last_mut(), op) {
        (Some(Op::Retain(a)), Op::Retain(b)) => *a += b,
        (Some(Op::Delete(a)), Op::Delete(b)) => *a += b,
        (Some(Op::Insert(a)), Op::Insert(b)) => a.push_str(&b),
        (_, Op::Retain(0) | Op::Delete(0)) => {}
        (_, Op::Insert(b)) if b.is_empty() => {}
        (_, op) => ops.push(op),
    }
}

/// Ops that turn `old` into `new`. Common prefix and suffix are trimmed first (a typing session
/// changes one place), then the middle is diffed per character.
pub fn diff(old: &str, new: &str) -> Vec<Op> {
    let a: Vec<char> = old.chars().collect();
    let b: Vec<char> = new.chars().collect();
    let prefix = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let suffix = a[prefix..]
        .iter()
        .rev()
        .zip(b[prefix..].iter().rev())
        .take_while(|(x, y)| x == y)
        .count();
    let (am, bm) = (&a[prefix..a.len() - suffix], &b[prefix..b.len() - suffix]);
    let mut ops = Vec::new();
    push(&mut ops, Op::Retain(prefix));
    if am.is_empty() || bm.is_empty() {
        push(&mut ops, Op::Delete(am.len()));
        push(&mut ops, Op::Insert(bm.iter().collect()));
    } else {
        let deadline = Instant::now() + DIFF_BUDGET;
        for d in capture_diff_slices_deadline(Algorithm::Myers, am, bm, Some(deadline)) {
            match d {
                DiffOp::Equal { len, .. } => push(&mut ops, Op::Retain(len)),
                DiffOp::Delete { old_len, .. } => push(&mut ops, Op::Delete(old_len)),
                DiffOp::Insert {
                    new_index, new_len, ..
                } => push(
                    &mut ops,
                    Op::Insert(bm[new_index..new_index + new_len].iter().collect()),
                ),
                DiffOp::Replace {
                    old_len,
                    new_index,
                    new_len,
                    ..
                } => {
                    push(&mut ops, Op::Delete(old_len));
                    push(
                        &mut ops,
                        Op::Insert(bm[new_index..new_index + new_len].iter().collect()),
                    );
                }
            }
        }
    }
    // The trailing retain is implied.
    if let Some(Op::Retain(_)) = ops.last() {
        ops.pop();
    }
    ops
}

/// What a delta did, in grapheme clusters (what history shows as +added / −removed).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    pub added: u32,
    pub removed: u32,
}

/// Applies ops to `old`.
pub fn apply(old: &str, ops: &[Op]) -> Result<(String, Stats), LedgerError> {
    let mut out = String::with_capacity(old.len());
    let mut stats = Stats::default();
    let mut rest = old;
    let take = |rest: &mut &str, n: usize| -> Result<String, LedgerError> {
        let end = rest.char_indices().nth(n).map_or(rest.len(), |(i, _)| i);
        if rest[..end].chars().count() != n {
            return Err(LedgerError::BadDelta(format!(
                "op runs past the end by {}",
                n - rest[..end].chars().count()
            )));
        }
        let (head, tail) = rest.split_at(end);
        *rest = tail;
        Ok(head.to_string())
    };
    for op in ops {
        match op {
            Op::Retain(n) => out.push_str(&take(&mut rest, *n)?),
            Op::Delete(n) => stats.removed += take(&mut rest, *n)?.graphemes(true).count() as u32,
            Op::Insert(t) => {
                out.push_str(t);
                stats.added += t.graphemes(true).count() as u32;
            }
        }
    }
    out.push_str(rest);
    Ok((out, stats))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(a: &str, b: &str) -> Vec<Op> {
        let ops = diff(a, b);
        assert_eq!(apply(a, &ops).unwrap().0, b, "{a:?} -> {b:?} via {ops:?}");
        ops
    }

    #[test]
    fn typing_is_one_insert() {
        let ops = roundtrip("그날 밤, 비가 왔다.", "그날 밤, 차가운 비가 왔다.");
        assert_eq!(ops, vec![Op::Retain(6), Op::Insert("차가운 ".into())]);
    }

    #[test]
    fn many_shapes_roundtrip() {
        let cases = [
            ("", ""),
            ("", "새 글"),
            ("지울 글", ""),
            ("abc", "abc"),
            ("👨‍👩‍👧 family", "👨‍👩 family"),
            ("e\u{301}tude", "étude"),
            ("one two three four", "one 2 three 4 five"),
            ("줄 하나\n줄 둘\n줄 셋", "줄 둘\n줄 하나\n줄 셋\n줄 넷"),
        ];
        for (a, b) in cases {
            roundtrip(a, b);
        }
    }

    #[test]
    fn stats_count_graphemes() {
        let ops = diff("가나다", "가👨‍👩‍👧다");
        let (_, s) = apply("가나다", &ops).unwrap();
        assert_eq!((s.added, s.removed), (1, 1));
    }

    #[test]
    fn encoding() {
        let ops = vec![Op::Retain(3), Op::Delete(2), Op::Insert("x".into())];
        let s = serde_json::to_string(&ops).unwrap();
        assert_eq!(s, r#"[3,-2,"x"]"#);
        assert_eq!(serde_json::from_str::<Vec<Op>>(&s).unwrap(), ops);
        assert!(serde_json::from_str::<Vec<Op>>("[0]").is_err());
    }

    #[test]
    fn overrun_is_an_error() {
        assert!(apply("ab", &[Op::Retain(3)]).is_err());
        assert!(apply("ab", &[Op::Delete(3)]).is_err());
    }
}
