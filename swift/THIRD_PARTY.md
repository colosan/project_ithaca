# Third-party components in Ithaca for Mac

What ships inside `Ithaca.app` besides our own code (`MIT OR Apache-2.0`). Permissive licenses only (AGENTS.md).
The Rust core's dependencies are listed in `core/DEPENDENCIES.md`.

| Component | Version | License | Where in the app | Source |
|---|---|---|---|---|
| Sparkle | 2.10+ (SwiftPM) | MIT | `Contents/Frameworks/Sparkle.framework` — auto-update (ADR-0008) | https://github.com/sparkle-project/Sparkle |
| Pretendard | 1.3.9 (Regular · Medium · SemiBold · Bold, static OTF) | OFL-1.1 | `Contents/Resources/Fonts/` — UI and editor face, registered per process at launch; license text in `Pretendard-OFL.txt` next to the fonts (from `swift/Apps/macOS/Fonts/OFL.txt`) | https://github.com/orioncactus/pretendard |
| Lucide icons | via `design/icons.json` | ISC | Vector paths compiled into the app (`IthacaDesign/Generated/IconVectors.swift`) | https://lucide.dev |
