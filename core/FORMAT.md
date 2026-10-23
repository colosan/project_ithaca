# Ithaca library format — version 1

The files a library holds on disk (ADR-0002, ADR-0008 §4–5). This is a stable contract: anything
written in format 1 must open in every later core, through a migration if need be.

## Layout

```
<library>/                         default: ~/Library/Application Support/Ithaca/Library/
  library.json                     { "format": 1, "created": <ms> }
  projects/<project-id>/
    changes/<hash>                 immutable block files — the only source of truth
    cache/<chain-id>.json          derived; deleting it loses nothing
  Backups/pre-migration-<from>-<to>-<YYYY-MM-DD>[-n]/   full copies made before a migration
```

- Ids (project, folder, sheet) are UUID v4 in 32-char lowercase hex. `toc` is reserved (below).
- `library.json` may carry extra fields; a core keeps fields it does not know.
- A missing `library.json` in an empty or missing folder creates a new library. A missing `library.json`
  next to a `projects/` folder is an error (`Corrupt`), never silently re-initialised.

## Blocks

One block per file, named by its hash. Content is canonical JSON (below) plus a trailing newline:

```json
{"actor":"me","at":1790000017000,"body":{"delta":[12,"새 문장. "]},"device":"<device-id>",
 "epoch":1,"hash":"<64 hex>","kind":"edit","parents":["<64 hex>"],"sheet":"<chain id>","v":1}
```

| Field | Meaning |
|---|---|
| `v` | Block encoding version, `1`. A block with another version is not read (reported by `verify`). |
| `hash` | blake3 (256-bit, lowercase hex) of the canonical encoding of the block **without** `hash`. Equals the file name. |
| `parents` | `[]` for the first block of a chain, `[parent]` normally, `[main, copy]` for a merge. The first parent is the one the body applies to. |
| `sheet` | Chain id: a sheet id, or `toc` for the project's table of contents. |
| `epoch` | Lease epoch (ADR-0002). Starts at 1, inherited from the parent; lease blocks will raise it. |
| `device` | Device id of the writer (one per install, ADR-0008 §6). |
| `actor` | `me` or `claude`. |
| `kind` | `edit` (sheet text), `meta` (table of contents), `lease`, `merge`. |
| `at` | Unix ms when written (imports use the original modification time). |
| `body` | `{"snapshot": "<full text>"}`, `{"delta": [ops]}` or `"same"` (text unchanged, for lease blocks). |

**Canonical encoding**: JSON, no whitespace, object keys sorted by their UTF-8 bytes (recursively),
strings escaped as serde_json does (only `"`, `\` and control characters escaped; non-ASCII literal),
integers in plain decimal. No floats appear.

**Delta ops** apply to the first parent's text and count Unicode scalar values: a positive integer keeps
that many characters, a negative integer deletes that many, a string inserts itself. Characters left
after the last op are kept. Zero and empty strings are invalid.

**Snapshot vs delta**: the first block of a chain is a snapshot. Later blocks are deltas, except a snapshot
is written when the delta chain since the last snapshot would reach 32 blocks (`SNAPSHOT_EVERY`) or when
the encoded delta is not smaller than the encoded text. Reading any version therefore touches at most 32
files. Merge blocks should be snapshots.

**Writing**: write to `changes/.tmp-<name>-<pid>-<n>`, fsync, rename to `changes/<hash>`. Files are never
modified. Files whose name starts with `.tmp-` are incomplete writes: ignored on open and removed by a
writable open. Block files are only ever removed by a permanent delete (after its tombstone, below) or
by purging a deleted project.

## Chains, heads and branches

Each sheet is its own chain; so is the table of contents. A block is **valid** when all its parents are
valid and its body applies to its first parent's text. Invalid blocks (and everything after them) are
left out of the text and reported by `verify`.

**Heads** are valid blocks no other valid block names as a parent. With one head the chain is linear.
With several (offline fork), the winner is decided deterministically (ADR-0002 §4): follow each head's
first-parent line back to where they part and compare the first blocks after the fork point — higher
`epoch` wins, then the greater `device` (byte order), then the greater `hash`. The other heads are
**branch copies**: kept, shown as `branched`, resolved later by a `merge` block naming both.

## Table of contents (`toc` chain)

The text of the `toc` chain is the project's table of contents as pretty-printed JSON (one field per
line keeps deltas small), stored with the same snapshot/delta rules as sheets, `kind: "meta"`:

```json
{
  "title": "등대지기의 딸", "language": "ko",
  "goal": { "count": 5500, "basis": "withSpaces" },   // or null; basis: withSpaces | withoutSpaces | words
  "created": 1790000000000,
  "deleted": null,                                       // ms when soft-deleted
  "folders": [ { "id": "…", "name": "연재", "deleted": null, "sheets": ["<sheet id>", …] } ],
  "sheets": { "<sheet id>": { "created": 1790000000000, "trashed": null } },
  "removed": ["<sheet id>"]                              // tombstones of permanently deleted sheets
}
```

- Folder order and serial order are array order. Trashed sheets keep their slot so a restore puts them back.
- Deleting a folder stamps it and its live sheets with the same time; the folder entry disappears once no
  sheet refers to it.
- A project directory without a valid `toc` chain is not a project (e.g. a create that crashed). Sheet
  blocks are written before the `toc` block that names them, so a crash leaves only invisible orphans.
- Retention: projects with `deleted` and sheets with `trashed` older than 30 days are purged on open.
- A sheet's `created` lives in the toc; its `modified` is the `at` of its head block.

## Cache (derived)

`cache/<chain-id>.json` = `{ "v": 1, "sheet", "metas": [every block without its body, plus depth and
added/removed], "winner", "branches", "text" }` (chain ids that are not plain `[A-Za-z0-9_-]` use the
first 32 hex of their blake3). On open a cache is trusted only if every block it lists is still in
`changes/`; blocks no cache lists are read and their chains rebuilt from blocks. Delete `cache/` any time.

## Versions and migrations (ADR-0008 §5)

- `library.json.format` is the format of the whole library. This core writes and reads format **1**.
- Lower: before anything else, the whole library (except `Backups/`) is copied to
  `Backups/pre-migration-<from>-<to>-<UTC date>/`, then each step `n → n+1` runs in order and
  `format` is updated after each step. A missing step fails the open before anything is touched.
- Higher: the library opens **read-only**. Nothing is written, not even caches or cleanup; every write
  returns `ReadOnly`. Blocks with an unknown `v` are skipped.
- Every migration is tested against the frozen fixture of the previous format (`core/fixtures/library-v1`).
  The machinery is proven by a test-only v1 → v2 step (`crates/ithaca-store/tests/migration.rs`).
