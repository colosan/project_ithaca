# Core dependencies

Permissive licenses only (AGENTS.md). Direct dependencies of the workspace; check transitive ones with
`cargo metadata` before adding anything (none are GPL/AGPL today; `r-efi`, a UEFI-only dependency of
getrandom, is used under its MIT/Apache option).

| Crate | Version | License | Used by | Why |
|---|---|---|---|---|
| uniffi | 0.32 | MPL-2.0 (used unmodified) | ithaca-ffi | Swift/Kotlin bindings (ADR-0001) |
| serde, serde_json | 1 | MIT OR Apache-2.0 | all | block, toc, cache and library.json encoding |
| thiserror | 2 | MIT OR Apache-2.0 | store, ffi | error types |
| blake3 | 1.8 | CC0-1.0 OR Apache-2.0 (OR Apache-2.0 WITH LLVM-exception) | ledger, store | block hashes (ADR-0002) |
| similar | 2.7 | Apache-2.0 | ledger | character diff for block deltas |
| unicode-segmentation | 1.13 | MIT OR Apache-2.0 | model, ledger | grapheme and word counts (ADR-0005) |
| uuid (v4) | 1.29 | MIT OR Apache-2.0 | store | project, folder and sheet ids |
| encoding_rs | 0.8 | (Apache-2.0 OR MIT) AND BSD-3-Clause (the BSD part covers WHATWG-derived index data) | store | CP949 / EUC-KR and UTF-16 decoding for `import_text_folder` (txt-import); new transitive: simdutf8, scopeguard, multiversion_no_op (proc-macro), core_detect (lockfile only), all MIT OR Apache-2.0 |
| libc *(unix only)* | 0.2 | MIT OR Apache-2.0 | store | `localtime_r` for local-time backup names (qa1); was already transitive |
| serde_json *(ithaca-mcp)* | 1 | MIT OR Apache-2.0 | ithaca-mcp | JSON-RPC / MCP messages; no MCP SDK is used (ADR-0009), so the server adds **no new crate** |
| zip *(default features off; `deflate-flate2-zlib-rs`)* | 9.0 | MIT | model | .docx container for `export_docx` (added: docx). New transitive: flate2, crc32fast, indexmap, hashbrown, equivalent, typed-path, bitflags (MIT OR Apache-2.0); zlib-rs (Zlib); memchr (Unlicense OR MIT); nix, cfg_aliases (MIT). No document library: the WordprocessingML is written by hand |
| unicode-normalization | 0.1.26 | (MIT OR Apache-2.0) AND Unicode-3.0 (the Unicode part covers the generated normalization tables) | store | NFC for file and folder names in `import_text_folder` (added: qa4; macOS hands out decomposed Hangul). New transitive: tinyvec (Zlib OR Apache-2.0 OR MIT), no default features |
| tempfile *(dev only)* | 3.27 | MIT OR Apache-2.0 | tests | temporary library folders |

No crate is used for the library lock: `std::fs::File::try_lock` (stable since Rust 1.89; `flock` on
macOS and Linux) does it, so the safety work added no dependency.

Notable transitive: arrayvec, cfg-if, getrandom, libc (MIT OR Apache-2.0); constant_time_eq
(CC0-1.0 OR MIT-0 OR Apache-2.0); zmij (MIT, via serde_json); cc (build-time, MIT OR Apache-2.0).
