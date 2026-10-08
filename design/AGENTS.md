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
  - **조작 가능하게 만든다.** 선택 · 패널 · 토글은 `useState`(초기값은 `state` prop), 다른 화면으로 가는 버튼은 `useNavigate()("slug#state")`.
    누를 수 있는 요소엔 `cursor: "pointer"`. 이동 대상은 meta.json `links` 와 맞춘다.
  - `export const states = [...] as const` 와 `export default function` 필수.
  - 버튼 · 토글 · 세그먼트 · 체크 · 입력은 kit 컴포넌트(`Button` · `IconButton` · `Segmented` · `Chip` · `Checkbox` · `Radio` · `Switch` · `TextField`)만. 화면에서 새로 그리지 않는다.
  - 아이콘은 `<Icon name>` · `<IconButton icon>` 만. 이름은 `design/icons.json` 에 있는 것만 — 필요하면 거기에 더한다(Lucide 이름). ↺ ✕ ⚙ 같은 문자 아이콘은 BLOCK.
- `meta.json` 의 `links` 가 캔버스의 화살표다: `{ "from": "<내 state>", "to": "<slug>" | "<slug>#<state>", "label": { "ko", "en" } }`.
  화면을 이동시키는 동작(버튼·제스처·외부 사건)마다 하나씩. `design:check` 가 없는 화면·state 를 막는다.

## 계획된 화면
- 아직 그리지 않은 화면은 `spec.md` + `meta.json`(`"planned": true`) 만 둔다. 캔버스에 점선 카드로 보인다.
- 다른 화면의 `links` 는 계획된 화면을 `"to": "<slug>"`(state 없이)로 가리킬 수 있다.
- 그리기 시작하면 `prototype.tsx` 를 추가하고 `planned` 를 지운다.

## workbench 검출 결과는 고친다
- 프레임 배지 ⚠ (잘림 · 넘침 · 화면 밖)는 결함이다. 280px 폭 · English 에서도 0 이어야 한다.
- 토큰 페이지 대비표의 빨간 칸(4.5:1 미만)은 `ink.markup` 외에는 없어야 한다.

## 캔버스 · 프리셋
- `canvas.json` — 카드 위치. workbench 에서 카드를 끌면 저장된다. 손으로 고칠 일 없음.
- `viewports.json` — 실제 기기·창 프리셋. Windows 는 `physical` + `scale`(디스플레이 배율)로 적고 논리 크기는 workbench 가 나눠서 쓴다.

## 화면을 고칠 때 (스크린샷 검사)
1. 고치기 **전**: 기준이 없으면 `pnpm design:snap --update --only <slug>` (기준은 이 기계에만 있다 — git 에 안 올라감)
2. 고친 **후**: `pnpm design:snap --only <slug>` → `design/snapshots/report.md` 를 읽는다
   - **Defects** 는 무조건 고친다 (clip · spill · offscreen · unsafe). 글자 200% · 경계 폭(600 · 840 · 1200)에서 자주 나온다
   - **Changed** 는 diff PNG 를 열어 의도한 변화인지 본다. 의도했으면 `--update`, 아니면 고친다
3. 매트릭스는 `design/snapshot-matrix.json` — 기기를 다 찍지 않고 폭 경계 양쪽 · 최소 폭 · 큰 모니터만

## 완료 조건
`pnpm design:check` BLOCK 0 · `pnpm typecheck` 통과 · 고친 화면의 `pnpm design:snap` 결함 0. 하나라도 실패하면 완료가 아니다.

## 스크롤 · 글자 크기
- 실제 앱에서 스크롤될 영역은 `overflow: "auto"`. `"hidden"` 은 정말 잘라내는 곳(둥근 모서리 등)에만 — 검출기가 hidden 안의 넘친 글자를 결함으로 본다.
- 글자가 든 줄·버튼·바는 `height` 대신 `minHeight` — 글자 크기 200% 에서도 줄이 따라 커져야 한다. 고정 `height` 는 글자 없는 것(진행 막대, 토글)에만.
