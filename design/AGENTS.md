# design/ 규칙 (agent 가 이 폴더를 만질 때 먼저 읽는다)

값과 명세의 정본이다. 어긋나면 `docs/adr/` 와 여기 `DESIGN.md` · `PRODUCT.md` 가 이긴다.

## 토큰 (`tokens/*.json`)
- 값은 여기서만 바꾼다. 바꾼 뒤 `pnpm design:gen` (workbench 가 떠 있으면 자동).
- 생성물은 손대지 않는다: `workbench/src/generated/*` · `swift/**/Generated/*` · `kotlin/**/generated/*`.
- 새 토큰은 "쓰임새" 이름으로 (`color.state.warning` ○ / `color.orange` ✕).

## 문구 (`strings/{ko,en}.json`)
- 키를 더하면 **모든 locale 에 동시에** 더한다. `{자리표시자}` 이름도 같아야 한다.
- 복수형이 필요하면 en 에서 `{ "one", "other" }` 객체, `{count}` 필수.
- "설정" = 작품 설정집(Lore). 앱 환경 설정은 "환경설정"(Settings).

## 화면 (`screens/<slug>/`)
- 세 파일이 한 쌍: `spec.md`(무엇·왜·상태·size class 별 레이아웃) · `prototype.tsx` · `meta.json`(제목·버전·이동 경로).
- `prototype.tsx`:
  - import 는 `react` 와 `@ithaca/kit` 만.
  - 스타일 값은 토큰만 (`color.*` · `space[…]` · `size.*` · `radius.*` · `type.*` · `pane.*` · `editor.*` · `opacity.*`). 숫자·hex·px 금지 (0 만 허용).
  - 문구는 `useT()` 만. 원고 내용은 `useFrame().sample` (fixtures).
  - 레이아웃 분기는 `useFrame().sizeClass` 로. 네이티브가 같은 분기를 구현한다.
  - `export const states = [...] as const` 와 `export default function` 필수.
- `meta.json` 의 `links` 가 캔버스의 화살표다: `{ "from": "<내 state>", "to": "<slug>" | "<slug>#<state>", "label": { "ko", "en" } }`.
  화면을 이동시키는 동작(버튼·제스처·외부 사건)마다 하나씩. `design:check` 가 없는 화면·state 를 막는다.

## 캔버스 · 프리셋
- `canvas.json` — 카드 위치. workbench 에서 카드를 끌면 저장된다. 손으로 고칠 일 없음.
- `viewports.json` — 실제 기기·창 프리셋. Windows 는 `physical` + `scale`(디스플레이 배율)로 적고 논리 크기는 workbench 가 나눠서 쓴다.

## 완료 조건
`pnpm design:check` BLOCK 0 · `pnpm typecheck` 통과. 하나라도 실패하면 완료가 아니다.
