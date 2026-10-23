# Ithaca

**The open-source home for serial fiction.** Local-first, no subscription, and your AI can read your story bible.

**연재 작가를 위한 오픈소스 글쓰기 앱.** 서버도 구독도 없이, 내 Claude 가 내 설정집을 읽는다.

> 🚧 Pre-alpha — the **Mac app** is in daily use (Rust core + SwiftUI). Other platforms follow the design freeze.

## Mac app

**Install:** download `Ithaca-<version>.zip` from [GitHub Releases (latest)](https://github.com/colosan/project_ithaca/releases/latest), unzip, move `Ithaca.app` to `/Applications`, and on first launch use System Settings → Privacy & Security → **Open Anyway** (the app isn't notarized yet). Updates arrive in-app (Sparkle, signature-checked). Apple Silicon only for now. User guide (Korean): [`docs/mac-app.md`](docs/mac-app.md).

- **Projects → folders → sheets**, Markdown kept as typed, serial order by drag or ⌥⌘↑↓, trash with 30-day undo.
- **Episodes** — numbering (prologue/side stories excluded), draft · revising · scheduled · published, release dates, stock count and next release in the list, folder stats.
- **Counts** — with/without spaces always on screen, 원고지 pages, Munpia/Novelpia counts, per-sheet goals.
- **Paste-ready export** — plain text for serial platforms (blank lines, indent, Markdown stripped), or .txt / .md files.
- **History** — every save is a hash-chained block; restore any version without losing the rest.
- **Claude (read-only)** — Claude Desktop reads the projects you tick, via a bundled local MCP server. No token, no network.
- **Safe by default** — autosave that never drops unsaved text, daily local backups (7 days + 4 weeks) restored as copies, damaged-sheet recovery, one writer per library (a second instance opens read-only).
- **Import** — the web version's JSON backup, or a folder of .txt/.md files (natural order, CP949-aware).
- Inspector (reference · info · outline), focus mode, typewriter scrolling, ⌘K palette, Korean & English UI.

## Why

- **Lore · Episodes · Ideas** — a story bible, serialized chapters and a scratchpad, in one structured project.
- **Local-first** — works fully offline. Sync is optional: iCloud, peer-to-peer, or your own relay server.
- **No silent merges** — one device edits a sheet at a time; diverged offline copies are resolved side by side, by you.
- **Claude-ready** — the desktop app can expose your project over MCP so your own Claude can read (and, if you allow it, edit) it. Every AI edit is recorded and revertible.
- **Native everywhere** — iPhone · iPad · Mac (SwiftUI), Android · Windows (Compose), one Rust core.
- **Korean & English** from day one.

## Repository

| Path | What |
|---|---|
| `design/` | Design tokens, UI strings, screen specs & prototypes — the source of truth |
| `workbench/` | Design review viewer: every screen × 4 size classes × light/dark × ko/en |
| `app-web/` | A usable web build for daily writing while the design settles (stored in the browser) |
| `tools/design-gen/` | Generates Swift · Kotlin · TS from `design/`, and lints it |
| `core/` | Rust core: model, hash-chain ledger, on-disk store + migrations, FFI (UniFFI) |
| `swift/` | Mac app (SwiftUI, built with SwiftPM — no Xcode needed) |
| `kotlin/` | Android · Windows (after the design freeze) |
| `docs/adr/` | Architecture decisions |

```bash
pnpm install
pnpm wb            # http://localhost:9151
pnpm app           # http://localhost:9152 — web version
tools/mac/build.sh # dist/Ithaca.app — Mac app (needs Rust + Command Line Tools)
pnpm design:check
```

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
