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
    // LibraryInfo { format: u32, core_version: String, read_only: bool, migrated_from: Option<u32>, backup_path: Option<String> }
}
```

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
// SheetSummary { id, folder, order, title, excerpt, counts: Counts, created, modified, trashed: Option<i64>, branched: bool }
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
/// `sheets` in the order given; an empty list means every live sheet of the project in reading order.
fn export_text(&self, project: String, sheets: Vec<String>, options: ExportOptions) -> Result<String, CoreError>;
// ExportOptions { blank_line = true, indent = false, strip_markdown = true, include_title = true, markdown = false }
// — same rules as app-web Export: sheets joined by "\n\n\n"; `markdown` = bodies as written joined by "\n\n---\n\n".
```

## Types

`Language { Ko, En }` · `GoalBasis { WithSpaces, WithoutSpaces, Words }` · `Actor { Me, Claude }` ·
`BlockKind { Edit, Lease, Merge, Meta }` · `IssueKind` (above) ·
`CoreError { NotFound, ReadOnly, InvalidInput{message}, Io{message}, Corrupt{message} }` (uniffi::Error).
Offsets crossing into Swift are UTF-16 code units.
