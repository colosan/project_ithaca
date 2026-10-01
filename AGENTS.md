# Ithaca — agent 공통 규칙

바뀐 경로에서 가장 가까운 `AGENTS.md` 가 이 파일보다 우선한다 (`design/AGENTS.md` …).

## 지금 단계
**디자인 확정 단계** (ADR-0006). 실제로 동작하는 것은 `design/` · `workbench/` · `tools/` 뿐이다.
`core/` · `swift/` · `kotlin/` 은 디자인 v1.0 동결 전까지 생성물 외에는 손대지 않는다.

## 결정은 ADR 에 있다
`docs/adr/0001~0006`. 여기 없는 판단이 필요하면 멈추고 사람에게 묻는다. 결정을 바꾸면 ADR 을 고친다(새 번호 또는 상태 갱신).

## 명령
| 명령 | 무엇 |
|---|---|
| `pnpm wb` | workbench 검수 뷰어 (http://localhost:9151) |
| `pnpm design:gen` | design/ → Swift · Kotlin · workbench 생성물 |
| `pnpm design:check` | 토큰 · 문구 · 드리프트 · 프로토타입 lint (BLOCK 있으면 exit 1) |
| `pnpm typecheck` | workbench + 프로토타입 타입 검사 |
| `pnpm design:snap` | 모든 화면 × 상태를 고정 매트릭스로 스크린샷 → 기준과 비교 · 결함 검출 → `design/snapshots/report.md` (`--only <slug>`, `--update`) |

## 라이선스 (오픈소스 공개 전제)
- 프로젝트: `MIT OR Apache-2.0`. 의존성은 permissive 만 — GPL · AGPL 금지.
- 새 의존성을 들이기 전에 라이선스를 확인하고 PR/커밋 설명에 적는다.
- GPL 프로젝트(Manuskript 등)와 외부 비공개 코드는 아이디어만 참고, 코드 복사 금지.

## 커밋
개인 repo — `user.email` 은 `80652992+colosan@users.noreply.github.com` (repo local config 에 설정됨).
