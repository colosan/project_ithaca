# core/ — Rust workspace

Rust core for Ithaca (ADR-0001, ADR-0008). Contract with the apps: [`API.md`](API.md).
On-disk format: [`FORMAT.md`](FORMAT.md). Dependencies and licenses: [`DEPENDENCIES.md`](DEPENDENCIES.md).

```
crates/ithaca-model    text rules (counts, title, excerpt, export), table of contents — no IO
crates/ithaca-ledger   blocks, canonical hash, deltas, heads and branch decision — no IO
crates/ithaca-store    library folder: blocks on disk, cache, formats, migrations, import
crates/ithaca-ffi      UniFFI surface (API.md)
fixtures/              frozen format-1 library and a web-app backup, used by tests
```

```sh
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings && cargo fmt --check
```

Planned later (ADR-0001): ithaca-sync, ithaca-mcp, bins/ithaca-relay.
