# Ithaca

**The open-source home for serial fiction.** Local-first, no subscription, and your AI can read your story bible.

**연재 작가를 위한 오픈소스 글쓰기 앱.** 서버도 구독도 없이, 내 Claude 가 내 설정집을 읽는다.

> 🚧 Pre-alpha — currently in the **design phase**. Nothing to install yet.

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
| `tools/design-gen/` | Generates Swift · Kotlin · TS from `design/`, and lints it |
| `core/` · `swift/` · `kotlin/` | App code (after the design freeze) |
| `docs/adr/` | Architecture decisions |

```bash
pnpm install
pnpm wb            # http://localhost:9151
pnpm design:check
```

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
