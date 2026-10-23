#![allow(dead_code)]
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use ithaca_store::{Clock, OpenOptions, Store};

pub const T0: i64 = 1_792_800_000_000; // 2026-10-24

pub struct TestClock(pub Arc<AtomicI64>);

impl TestClock {
    pub fn new(t: i64) -> (TestClock, Clock) {
        let a = Arc::new(AtomicI64::new(t));
        let b = a.clone();
        // Every reading moves time forward 1 s, like real saves do.
        (
            TestClock(a),
            Arc::new(move || b.fetch_add(1000, Ordering::SeqCst)),
        )
    }
    pub fn advance(&self, ms: i64) {
        self.0.fetch_add(ms, Ordering::SeqCst);
    }
}

pub fn opts(clock: Clock) -> OpenOptions {
    OpenOptions {
        clock,
        ..Default::default()
    }
}

pub fn open(path: &Path) -> (TestClock, Store) {
    let (tc, clock) = TestClock::new(T0);
    (tc, Store::open_with(path, "mac-test", opts(clock)).unwrap())
}

pub fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures")
}

/// Every file under a folder with its size, for "nothing was written" checks.
pub fn snapshot_tree(root: &Path) -> Vec<(PathBuf, u64)> {
    let mut out = Vec::new();
    fn walk(dir: &Path, root: &Path, out: &mut Vec<(PathBuf, u64)>) {
        for e in std::fs::read_dir(dir).unwrap() {
            let e = e.unwrap();
            let p = e.path();
            if p.is_dir() {
                walk(&p, root, out);
            } else {
                out.push((
                    p.strip_prefix(root).unwrap().to_path_buf(),
                    e.metadata().unwrap().len(),
                ));
            }
        }
    }
    walk(root, root, &mut out);
    out.sort();
    out
}

pub fn changes(store: &Store, project: &str) -> PathBuf {
    store.root().join("projects").join(project).join("changes")
}
