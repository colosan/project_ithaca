# Ithaca library format — version 1

The files a library holds on disk (ADR-0002, ADR-0008 §4–5). This is a stable contract: anything
written in format 1 must open in every later core, through a migration if need be.

## Layout

```
<library>/                         default: ~/Library/Application Support/Ithaca/Library/
  .lock                            empty; exclusive flock of the open writer (§Lock)
  library.json                     { "format": 1, "created": <ms> }
  mcp.json                         Claude connector settings (§mcp.json, added: r3); optional
  projects/<project-id>/
    changes/<hash>                 immutable block files — the only source of truth
    cache/<chain-id>.json          derived; deleting it loses nothing
    damaged/<hash>[-n]             broken block files set aside by a recovery (added: qa1); never read
  Backups/pre-migration-<from>-<to>-<YYYY-MM-DD>[-n]/   full copies made before a migration
  Backups/failed-migration-<from>-<to>-<YYYY-MM-DD>[-n]/  what a failed migration left (kept, never read)
<library parent>/Backups/          automatic and manual backups (§Backups)
  auto-<YYYY-MM-DD-HHMM>[-n]/      local time (UTC before core qa1); order by the manifest's `at`
  manual-<YYYY-MM-DD-HHMM>[-n]/
```

- Ids (project, folder, sheet) are UUID v4 in 32-char lowercase hex. `toc` is reserved (below).
- `library.json` may carry extra fields; a core keeps fields it does not know.
- A missing `library.json` in an empty or missing folder creates a new library. A missing or unreadable
  `library.json` next to a `projects/` folder is never re-initialised: the library opens **read-only**
  (projects readable, nothing written, not even `.lock`) with a problem message.

## Lock

A writable open takes an exclusive advisory `flock` on `<library>/.lock` (created empty if missing,
never deleted) and holds it while open; the OS releases it on close or crash. An open that finds it
held is read-only and writes nothing. Only the lock holder removes `.tmp-` files, writes caches,
purges or migrates. A read-only open for a newer format (or a missing `library.json`, above) does not
touch the lock. On a filesystem without `flock` the open proceeds unlocked and says so.

A **read-only open** (`open_read_only`, added: r3; used by `ithaca-mcp` beside the app) never takes or
creates the lock and writes nothing at all. It reads whatever blocks exist when it opens: block and
cache files are written atomically (temp file + rename), and a sheet's blocks are written before the
`toc` block that names them, so it never sees half a block or a sheet the toc names without blocks. A
cache older than the blocks is detected (not every listed block covered) and the chain is rebuilt in
memory. It is a snapshot: later writes need a fresh open.

## mcp.json (added: r3)

Written by the app (atomically), read by `ithaca-mcp` on every request. Not part of the format number;
missing = off.

```json
{ "enabled": true, "projects": ["<project id>", …], "permission": "read" }
```

- Missing, unparsable, or `enabled: false` → Claude sees nothing. Only listed, live (not deleted)
  projects are visible. `permission` is `read` (the only value today); an unknown value reads as `read`.
- Unknown fields are kept when the app rewrites it. Backups copy it like any library file; restoring
  a backup as copies gives new project ids, which are not shared until the writer picks them.

## Opening projects

A project folder that cannot be read, or whose `toc` chain does not parse, is skipped: the rest of the
library opens, the skipped folder is not written to (no cache, no cleanup), and the open reports it.
A folder with block files but no `toc` chain at all is reported too (its blocks are kept).

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

**Writing**: write to `changes/.tmp-<name>-<pid>-<n>`, fsync, rename to `changes/<hash>`, fsync the
folder. Files are never modified. Files whose name starts with `.tmp-` are incomplete writes: ignored
on open and removed by a writable open (the lock holder only). Block files are only ever removed by a permanent delete (after its tombstone, below) or
by purging a deleted project.

## Chains, heads and branches

Each sheet is its own chain; so is the table of contents. A block is **valid** when all its parents are
valid and its body applies to its first parent's text. Invalid blocks (and everything after them) are
left out of the text and reported by `verify`.

**Damage** (added: qa1): a chain with a block file that doesn't read or verify, with invalid blocks, or a
sheet the `toc` names that has no block at all is *damaged*. Its text is the last good one — the newer
(by `at`) of the valid head and the newest head reachable from a snapshot that comes after the damage
(such a snapshot is self-contained, so it and its deltas still verify). No block is written on a
damaged chain and its cache is not written (so every open finds the damage again). A file whose
JSON doesn't parse is attributed by its `"sheet"` field read leniently. Recovery moves the broken
files (and the blocks cut off by them) to `<project>/damaged/` and either puts the exact block back
from a backup or writes the recovered text as a new block on the valid head.

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
  "goal": { "count": 5500, "basis": "withSpaces" },   // or null; basis: withSpaces | withoutSpaces | words | munpia | novelpia
  "created": 1790000000000,
  "deleted": null,                                       // ms when soft-deleted
  "folders": [ { "id": "…", "name": "연재", "deleted": null, "sheets": ["<sheet id>", …] } ],
  "sheets": { "<sheet id>": { "created": 1790000000000, "trashed": null,
                "episode": { "number": 3, "status": "published", "publishAt": 1790000000000, "platform": "문피아" } } },
  "removed": ["<sheet id>"]                              // tombstones of permanently deleted sheets
}
```

- `episode` (optional, added in core 0.1 round 2 within format 1): absent = not an episode. Inside it every
  field is optional and left out when empty; `status` is `draft | revising | scheduled | published`
  (default `draft`). Tables of contents written before it existed load unchanged.
  (added: r3) `"excluded": true` marks a prologue / 외전 / 공지 (left out when false). Older cores ignore it
  and keep it (unknown fields are kept).
- `goal.basis` (added: r3) may also be `munpia | novelpia`. **A core older than r3 (app ≤ 0.2.0) cannot
  parse such a goal and skips that project on open** (reported, nothing written; it loads again in a
  newer app). Accepted: apps only move forward via updates; see ADR-0009.
- **Unknown fields are kept.** A core keeps fields it does not know at the top level, in folder entries and
  in sheet entries, and writes them back when it rewrites the table of contents, so adding an optional
  field never needs a format bump and an older core never drops a newer core's data.
- Folder order and serial order are array order. Trashed sheets keep their slot so a restore puts them back.
- Deleting a folder stamps it and its live sheets with the same time; the folder entry disappears once no
  sheet refers to it.
- A project directory without a valid `toc` chain is not a project (e.g. a create that crashed). Sheet
  blocks are written before the `toc` block that names them, so a crash leaves only invisible orphans.
- Retention: projects with `deleted` and sheets with `trashed` older than 30 days are purged on open.
  "Now" for this is `min(clock, newest block time in the library + 2 days)`, so a clock that jumped
  forward purges nothing early; purging resumes once something has been written. A purge that fails
  is reported and retried on the next open.
- A sheet's `created` lives in the toc; its `modified` is the `at` of its head block.

## Cache (derived)

`cache/<chain-id>.json` = `{ "v": 2, "sheet", "metas": [every block without its body, plus depth and
added/removed], "winner", "branches", "text", "head", "textHash" }` (chain ids that are not plain
`[A-Za-z0-9_-]` use the first 32 hex of their blake3). `head` repeats the winning head; `textHash` is
the blake3 hex of `text`. On open a cache is trusted only if it parses, is version 2, `head == winner`,
`head` is one of its `metas`, `textHash` matches `text`, and every block it lists is still in
`changes/`; anything else (including version-1 caches) is rebuilt from blocks, as are blocks no cache
lists. Caches are written atomically but not fsynced: they are disposable. Delete `cache/` any time.

## Backups

A backup is a library-shaped folder, so it can be opened or restored like a library:

```
auto-2026-10-24-0915/
  backup.json        { "v": 1, "kind": "auto" | "manual" | "pre-migration", "at": <ms>, "bytes": <n>,
                       "format": 1, "projects": <n>, "complete": true,
                       "textSheets": <n> }   // sheets with text (added: qa1; absent = unknown)
  library.json       copied as is
  projects/<id>/changes/<hash>   every block file; no cache/, no .tmp- files
```

- Written as `<parent>/Backups/.tmp-<name>-<pid>/`, every file and folder fsynced, `backup.json`
  written last (fsynced), then renamed into place and the parent folder fsynced. A folder is listed only
  if its `backup.json` reads and says `complete` (a manifest without the field — written before it
  existed, also only at the end — counts as complete). Leftover `.tmp-auto-*`/`.tmp-manual-*` folders
  untouched for an hour are removed by the next backup (younger ones may be a sibling library's
  backup in progress). Blocks are immutable and writes are serialized, so the copy is consistent.
- A project whose folder cannot be read is left out of the backup (and reported), not fatal.
- `bytes` = sum of copied files (manifest excluded).
- Retention runs after each automatic backup and deletes only `auto-*` folders with a manifest:
  keep the newest auto of each of the last 7 local days that have one, and of each of the last 4
  Monday-based local weeks that have one.
- (added: qa1) No automatic backup is made of a library without any sheet that has text. `manual-*` and `pre-migration-*` are never deleted.
- Restoring never writes into a backup and never overwrites: projects come back as copies with new ids.

## Versions and migrations (ADR-0008 §5)

- `library.json.format` is the format of the whole library. This core writes and reads format **1**.
- Lower (only while holding the lock; otherwise read-only): before anything else, the whole library
  (except `Backups/` and `.lock`) is copied to `Backups/.tmp-pre-migration-…`, fsynced, given a
  complete `backup.json` (`kind: "pre-migration"`, `format` = the old format), and renamed to
  `Backups/pre-migration-<from>-<to>-<UTC date>/`. Only then does each step `n → n+1` run in order,
  `format` updated after each step. A missing step fails the open before anything is touched (only
  `.lock` may have been created). If the backup fails, nothing is changed and the library opens
  read-only. If a step fails, the library's files are moved aside to
  `Backups/failed-migration-<from>-<to>-<date>/`, the backup is copied back, and the library opens
  read-only at the old format with a problem message. Pre-migration folders without a complete
  manifest are not listed.
- Higher: the library opens **read-only**. Nothing is written, not even caches or cleanup; every write
  returns `ReadOnly`. Blocks with an unknown `v` are skipped.
- Every migration is tested against the frozen fixture of the previous format (`core/fixtures/library-v1`).
  The machinery is proven by a test-only v1 → v2 step (`crates/ithaca-store/tests/migration.rs`).
