# Core ↔ app contract (ithaca-ffi)

The only surface Swift (and later Kotlin) calls (ADR-0001). UniFFI proc-macros; names below are Rust,
UniFFI exposes them camelCased in Swift. Times are Unix milliseconds (i64). Ids are opaque strings.
Change this file and `ithaca-ffi` together; the Mac UI codes against this. On-disk format: `FORMAT.md`.

## Opening

```rust
#[derive(uniffi::Object)] pub struct Library;   // thread-safe; calls are serialized internally

fn core_version() -> String;                      // free function

impl Library {
    /// Opens (creating if missing) the library folder. Runs format migrations, backing up first (ADR-0008).
    /// A library newer than this core opens read-only (`info().read_only == true`); every write then
    /// returns `CoreError::ReadOnly` and nothing on disk is touched.
    /// On a writable open, projects deleted and sheets trashed more than 30 days ago are purged.
    #[uniffi::constructor] fn open(path: String, device_id: String) -> Result<Arc<Library>, CoreError>;
    fn info(&self) -> LibraryInfo;
    // LibraryInfo { format: u32, core_version: String, read_only: bool, migrated_from: Option<u32>, backup_path: Option<String>,
    //               locked_by_other: bool /* (added: safety) */, problems: Vec<String> /* (added: safety) */ }
}
```

### Open safety (added: safety)

- **One writer per library.** A writable open holds an exclusive advisory lock on `<library>/.lock`
  until the `Library` is dropped (or the process dies). A second open — another app instance, a
  second build — gets `info().locked_by_other == true` and `read_only == true`; every write returns
  `ReadOnly`. It is a snapshot of the moment it opened and does not see the other instance's later
  writes: drop it and open again once the other instance has quit.
- **`read_only` has more causes now**: newer format (as before), `locked_by_other`, `library.json`
  missing or unreadable next to a `projects/` folder (nothing is initialised over it), a migration
  that failed (the library is put back from its pre-migration backup) or could not back up first.
  Each cause except "newer format" adds a line to `problems`.
- **`problems`**: human-readable English lines for the app to show (e.g. a banner/sheet on launch,
  Settings → 백업). Empty when all is well. Opening reports: projects skipped because their folder
  is unreadable or their table of contents is corrupt (they are left untouched on disk and load again
  once fixed), purges that failed, why the library is read-only. Later calls may append (a failed
  backup pruning, a project skipped by a backup) — call `info()` again after `backup_now`.
- **Retention clock guard**: purging uses `min(now, newest block in the library + 2 days)` as "now".
  After a clock jump forward — or simply a long break — nothing is purged until something has been
  written; the next open after that purges as usual.

## Projects, folders, sheets

```rust
fn projects(&self) -> Vec<ProjectSummary>;                  // live projects, creation order (`created` ascending)
// ProjectSummary { id, title, language: Language, goal: Option<Goal>, created, modified, deleted: Option<i64>,
//                  sheets: u32 /* live sheets */, counts: Counts /* sum over live sheets */ }
// Goal { count: u32, basis: GoalBasis }   GoalBasis { WithSpaces, WithoutSpaces, Words }
// `modified` = time of the newest block in the project (any sheet or the table of contents).

/// `folders` must not be empty (InvalidInput). Like the web app, one empty sheet is created in the first folder.
fn create_project(&self, title: String, language: Language, folders: Vec<String>) -> Result<ProjectSummary, CoreError>;
fn update_project(&self, id: String, patch: ProjectPatch) -> Result<ProjectSummary, CoreError>;
// ProjectPatch { title: Option<String>, language: Option<Language>, goal: Option<Goal> }  — all default to nil.
// `goal: Some(Goal { count: 0, .. })` clears the goal.
fn delete_project(&self, id: String) -> Result<(), CoreError>;   // soft: kept 30 days, purged on a later open
fn restore_project(&self, id: String) -> Result<(), CoreError>;
fn deleted_projects(&self) -> Vec<ProjectSummary>;               // most recently deleted first

fn outline(&self, project: String) -> Result<Outline, CoreError>;  // works for deleted projects too
// Outline { project: ProjectSummary, folders: Vec<FolderInfo>, trash: Vec<SheetSummary> /* newest trashed first */ }
// FolderInfo { id, name, order, sheets: Vec<SheetSummary> }      // live folders; live sheets in serial order
// SheetSummary { id, folder, order, title, excerpt, counts: Counts, created, modified, trashed: Option<i64>, branched: bool,
//                episode: Option<EpisodeInfo> /* (added round 2) default nil; nil = not an episode */ }
// Counts { chars, chars_no_space, words, paragraphs }            // graphemes; Markdown marks excluded from words
// `order` = position among the folder's live sheets (for a trashed sheet: its kept slot).
// `branched` = an offline fork left a branch copy (ADR-0002 §4); the text shown is the winner's.

fn create_folder(&self, project: String, name: String) -> Result<FolderInfo, CoreError>;      // appended at the end
fn rename_folder(&self, project: String, folder: String, name: String) -> Result<(), CoreError>;
/// Sheets → trash, stamped with the folder's delete time. The last live folder can't be deleted (InvalidInput).
fn delete_folder(&self, project: String, folder: String) -> Result<(), CoreError>;
/// Brings back the folder and exactly the sheets its delete trashed (sheets trashed earlier stay in the trash).
fn restore_folder(&self, project: String, folder: String) -> Result<(), CoreError>;

fn create_sheet(&self, project: String, folder: String, text: String) -> Result<SheetSummary, CoreError>; // appended at the end
fn sheet_text(&self, project: String, sheet: String) -> Result<String, CoreError>;
/// Records a new block only when the text changed. The app calls this on idle (~1.5 s), on sheet switch and on quit.
/// On a branched sheet the block extends the winner (resolving branches has no API yet).
fn save_sheet(&self, project: String, sheet: String, text: String) -> Result<SheetSummary, CoreError>;
/// Reorder or move a live sheet: before `before` (a live sheet of `folder`, else NotFound) or at the end.
/// A trashed sheet can't be moved (InvalidInput).
fn move_sheet(&self, project: String, sheet: String, folder: String, before: Option<String>) -> Result<(), CoreError>;
fn trash_sheet(&self, project: String, sheet: String) -> Result<(), CoreError>;
fn restore_sheet(&self, project: String, sheet: String) -> Result<(), CoreError>;     // back to its old slot; revives a deleted folder
fn delete_sheet_forever(&self, project: String, sheet: String) -> Result<(), CoreError>; // live or trashed; its blocks are removed
fn empty_trash(&self, project: String) -> Result<(), CoreError>;
```

## Episodes (added round 2)

```rust
// EpisodeInfo { number: Option<u32> = nil, status: EpisodeStatus /* no default */, publish_at: Option<i64> = nil,
//               platform: Option<String> = nil /* free text, e.g. "문피아" */ }
// EpisodeStatus { Draft /* 초고 */, Revising /* 퇴고 */, Scheduled /* 예약 */, Published /* 발행 */ }
/// Sets (`Some`) or clears (`None`) a sheet's episode metadata; trashed sheets too. One toc block.
fn set_episode(&self, project: String, sheet: String, info: Option<EpisodeInfo>) -> Result<SheetSummary, CoreError>;
/// 비축분: live sheets of a live folder whose status is not Published. A sheet with no episode
/// metadata counts as not published. Unknown/deleted folder → NotFound.
fn stock(&self, project: String, folder: String) -> Result<u32, CoreError>;
/// Numbers the folder's live sheets **that have episode metadata** 1..n in serial order (status, date and
/// platform untouched; one toc block); returns n. Sheets without metadata (prologue, 공지, notes) are
/// skipped and use no number — to leave a sheet out of numbering, `set_episode(.., None)`.
/// Trashed sheets keep their old number. The app gives new sheets of a serial folder `Draft` metadata.
fn renumber_episodes(&self, project: String, folder: String) -> Result<u32, CoreError>;
```

## Backups (added round 2)

```rust
// BackupInfo { path: String /* absolute folder */, at: i64, bytes: u64, kind: BackupKind, projects: u32 }
// BackupKind { Auto, PreMigration, Manual }
/// Automatic backup → `<library parent>/Backups/auto-<UTC yyyy-mm-dd-HHMM>[-n]/`, then retention:
/// autos kept = newest of each of the last 7 days that have one + newest of each of the last 4 weeks
/// (Monday-based, UTC). Manual and pre-migration backups are never removed. Read-only library → ReadOnly.
/// Copies every block and library.json (seconds for a typical library; call off the main thread).
/// (added: safety) Every copied file is flushed to disk; the folder is listed only once its manifest
/// says complete. A failed pruning after a good backup still returns the backup and adds a line to
/// `info().problems`; an unreadable project is skipped (also noted there) rather than failing the backup.
fn backup_now(&self) -> Result<BackupInfo, CoreError>;
/// Same copy as `manual-<stamp>`; never pruned (Settings → 백업 → "지금 백업").
fn backup_manual(&self) -> Result<BackupInfo, CoreError>;
/// Newest first: auto + manual (from backups_dir), pre-migration (from `<library>/Backups`).
/// (added: safety) Pre-migration copies are listed only with a complete manifest; `at`/`bytes`/
/// `projects` come from it. Half-written copies of any kind are never listed.
fn backups(&self) -> Vec<BackupInfo>;
/// No Auto backup in the last 24 h (false on a read-only library). Call on launch / idle, then backup_now.
fn backup_due(&self) -> bool;
fn backups_dir(&self) -> String;   // `<library parent>/Backups`, for "Show in Finder"
/// The live projects of a backup (any library-shaped folder of this library's format, e.g. a `path`
/// from `backups()`) become NEW projects with new ids; nothing is overwritten. Projects deleted at
/// backup time, trashed sheets and deleted folders are skipped. Kept: title (as is — the app may
/// rename), language, goal, folder names/order, sheet text, created/modified, episode metadata.
/// History is not copied (it stays in the backup). Not a backup, another format, or the library
/// itself → InvalidInput. Returns the new projects in creation order.
/// (added: safety) All or nothing: if one project fails, the copies already made are removed again.
fn restore_backup_as_copies(&self, path: String) -> Result<Vec<ProjectSummary>, CoreError>;
```

## Platform counts (added round 2)

Free functions. Count the text **as given** — pass `export_text` output (Markdown stripped) to count
what will be pasted. Grapheme clusters, like `Counts`. Sources: docs/research/2026-10-24-serial-writers-and-platforms.md §1.1.

```rust
fn count_for(text: String, rule: CountRule) -> u32;
fn munpia_pages(text: String) -> u32;   // ⌈count_for(Munpia) / 470⌉; empty → 0
// CountRule {
//   WithSpaces     // = Counts.chars (every grapheme except "\n")
//   WithoutSpaces  // = Counts.chars_no_space
//   Words          // = Counts.words
//   Munpia         // 공백 포함, line breaks ("\n", "\r") not counted. Runs of spaces are NOT collapsed (unverified claim).
//   Novelpia       // no whitespace / line breaks / tabs and no . , ' " ! ? … ; curly quotes “”‘’ still count [미확인]
//   BytesUtf8      // 조아라: UTF-8 bytes, line breaks included (한글 3 B)
// }
```

## History (ADR-0002)

```rust
fn history(&self, project: String, sheet: String) -> Result<Vec<HistoryEntry>, CoreError>;
// HistoryEntry { hash, at, device, actor: Actor, kind: BlockKind, added: u32, removed: u32 }
// newest first (by `at`); every block of the sheet, branch copies included. added/removed are graphemes.
fn text_at(&self, project: String, sheet: String, hash: String) -> Result<String, CoreError>;
fn restore_version(&self, project: String, sheet: String, hash: String) -> Result<SheetSummary, CoreError>; // new block, nothing erased
fn verify(&self, project: String) -> Result<IntegrityReport, CoreError>; // re-reads every block file
// IntegrityReport { ok: bool, blocks: u32, chains: u32, issues: Vec<IntegrityIssue> }
// IntegrityIssue { file: String /* name in changes/ */, sheet: Option<String>, kind: IssueKind, detail: String }
// IssueKind { Unreadable, HashMismatch, MissingParent, BadDelta, UnexpectedFile }
```

## Search, import, export

```rust
/// Case-insensitive plain text, non-overlapping, at most 500 hits. Live sheets only; with `project: None`
/// only live projects. Order: project creation, folder order, serial order, position.
fn search(&self, query: String, project: Option<String>) -> Vec<SearchHit>;
// SearchHit { project, sheet, title, offset: u32 (UTF-16, for NSTextView), length: u32 (UTF-16),
//             snippet_before, snippet_match, snippet_after }   // snippets stay on the match's line
/// Web version backup (app-web JSON, ADR-0007) → new projects with new ids; nothing overwritten.
/// Deleted projects/folders and trashed sheets are skipped; titles are kept as is; sheet created/modified
/// times are kept (`modified` is the time of the sheet's block). Not a web backup → InvalidInput.
fn import_web_backup(&self, json: String) -> Result<ImportReport, CoreError>;    // ImportReport { projects, folders, sheets }
// (added: safety) All or nothing: on an error no imported project remains, so a retry never duplicates.
/// `sheets` in the order given; an empty list means every live sheet of the project in reading order.
fn export_text(&self, project: String, sheets: Vec<String>, options: ExportOptions) -> Result<String, CoreError>;
// ExportOptions { blank_line = true, indent = false, strip_markdown = true, include_title = true, markdown = false }
// — same rules as app-web Export: sheets joined by "\n\n\n"; `markdown` = bodies as written joined by "\n\n---\n\n".
```

## Types

`Language { Ko, En }` · `GoalBasis { WithSpaces, WithoutSpaces, Words }` · `Actor { Me, Claude }` ·
`EpisodeStatus` · `BackupKind` · `CountRule` (added round 2, above) ·
`BlockKind { Edit, Lease, Merge, Meta }` · `IssueKind` (above) ·
`CoreError { NotFound, ReadOnly, InvalidInput{message}, Io{message}, Corrupt{message} }` (uniffi::Error).
Offsets crossing into Swift are UTF-16 code units.
