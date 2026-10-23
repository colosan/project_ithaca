//! The block: one immutable entry in a sheet's chain. See core/FORMAT.md §Block.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::LedgerError;
use crate::delta::Op;

/// Block encoding version this core writes and reads.
pub const BLOCK_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Actor {
    Me,
    Claude,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Edit,
    Lease,
    Merge,
    Meta,
}

/// What the block does to the text of its first parent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Body {
    /// The whole text.
    Snapshot(String),
    /// Edits relative to the first parent's text.
    Delta(Vec<Op>),
    /// Text unchanged (lease blocks).
    Same,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Block {
    pub v: u32,
    pub hash: String,
    pub parents: Vec<String>,
    pub sheet: String,
    pub epoch: u64,
    pub device: String,
    pub actor: Actor,
    pub kind: Kind,
    pub at: i64,
    pub body: Body,
}

/// Compact JSON with object keys sorted by their UTF-8 bytes, independent of serde_json features.
pub fn canonical_json(v: &Value) -> String {
    let mut out = String::new();
    write_canonical(v, &mut out);
    out
}

fn write_canonical(v: &Value, out: &mut String) {
    match v {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(k.clone()).to_string());
                out.push(':');
                write_canonical(&map[k], out);
            }
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (i, x) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(x, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

impl Block {
    /// Builds a block and computes its hash.
    #[allow(clippy::too_many_arguments)]
    pub fn seal(
        parents: Vec<String>,
        sheet: impl Into<String>,
        epoch: u64,
        device: impl Into<String>,
        actor: Actor,
        kind: Kind,
        at: i64,
        body: Body,
    ) -> Block {
        let mut b = Block {
            v: BLOCK_VERSION,
            hash: String::new(),
            parents,
            sheet: sheet.into(),
            epoch,
            device: device.into(),
            actor,
            kind,
            at,
            body,
        };
        b.hash = b.compute_hash();
        b
    }

    /// The canonical encoding of everything except `hash` — what the hash covers.
    pub fn signing_bytes(&self) -> Vec<u8> {
        let mut v = serde_json::to_value(self).expect("block serializes");
        v.as_object_mut()
            .expect("block is an object")
            .remove("hash");
        canonical_json(&v).into_bytes()
    }

    /// blake3 of the signing bytes, lowercase hex.
    pub fn compute_hash(&self) -> String {
        blake3::hash(&self.signing_bytes()).to_hex().to_string()
    }

    /// The file content: canonical JSON including `hash`, then a newline.
    pub fn to_bytes(&self) -> Vec<u8> {
        let v = serde_json::to_value(self).expect("block serializes");
        let mut s = canonical_json(&v);
        s.push('\n');
        s.into_bytes()
    }

    /// Parses and checks the hash.
    pub fn parse(bytes: &[u8]) -> Result<Block, LedgerError> {
        let v: Value =
            serde_json::from_slice(bytes).map_err(|e| LedgerError::Malformed(e.to_string()))?;
        let ver = v
            .get("v")
            .and_then(Value::as_u64)
            .ok_or_else(|| LedgerError::Malformed("no version".into()))?;
        if ver != u64::from(BLOCK_VERSION) {
            return Err(LedgerError::Malformed(format!(
                "unsupported block version {ver}"
            )));
        }
        let b: Block =
            serde_json::from_value(v).map_err(|e| LedgerError::Malformed(e.to_string()))?;
        let actual = b.compute_hash();
        if actual != b.hash {
            return Err(LedgerError::HashMismatch {
                stated: b.hash,
                actual,
            });
        }
        Ok(b)
    }

    pub fn first_parent(&self) -> Option<&str> {
        self.parents.first().map(String::as_str)
    }
}

/// True for a 64-character lowercase hex name — the only names a block file can have.
pub fn is_hash_name(name: &str) -> bool {
    name.len() == 64
        && name
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Block {
        Block::seal(
            vec![],
            "s1",
            1,
            "dev-a",
            Actor::Me,
            Kind::Edit,
            1_700_000_000_000,
            Body::Snapshot("안녕".into()),
        )
    }

    #[test]
    fn roundtrip_and_hash() {
        let b = sample();
        assert!(is_hash_name(&b.hash));
        let back = Block::parse(&b.to_bytes()).unwrap();
        assert_eq!(back, b);
    }

    #[test]
    fn canonical_is_sorted_and_compact() {
        let s = String::from_utf8(sample().signing_bytes()).unwrap();
        assert_eq!(
            s,
            r#"{"actor":"me","at":1700000000000,"body":{"snapshot":"안녕"},"device":"dev-a","epoch":1,"kind":"edit","parents":[],"sheet":"s1","v":1}"#
        );
    }

    #[test]
    fn tamper_is_detected() {
        let b = sample();
        let bytes = String::from_utf8(b.to_bytes())
            .unwrap()
            .replace("안녕", "안녕!");
        assert!(matches!(
            Block::parse(bytes.as_bytes()),
            Err(LedgerError::HashMismatch { .. })
        ));
    }

    #[test]
    fn newer_block_version_is_not_read() {
        let bytes = String::from_utf8(sample().to_bytes())
            .unwrap()
            .replace("\"v\":1", "\"v\":2");
        assert!(matches!(
            Block::parse(bytes.as_bytes()),
            Err(LedgerError::Malformed(_))
        ));
    }
}
