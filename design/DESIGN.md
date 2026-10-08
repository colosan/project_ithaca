# DESIGN · 시각 언어

> 초안 (2026-10-01). 값(숫자·색)은 여기 적지 않는다 — 정본은 `design/tokens/*.json`. 여기는 "왜"와 판단 기준.

## 한 줄

**종이 위의 원고가 주인공이고, 도구는 물러선다.**
Ulysses 에서 가져오는 것은 모양이 아니라 태도다: 본문 한 줄 길이를 지키고, 서식 기호는 흐리게 남기고, 색은 하나만 쓴다.

## Ulysses 에서 가져오는 것

- **3단 구조** (라이브러리 / 시트 목록 / 에디터)가 폭에 따라 접힌다 → `layout.sizeClasses`
- **Markdown 기호를 지우지 않고 흐리게** 둔다 → `color.ink.markup`
- **본문 폭 상한**: 창이 넓어져도 원고 줄은 길어지지 않는다 → `layout.editor.measure`
- **포인트 색 하나**: 선택·주요 동작에만 → `color.accent.*`

## Ulysses 와 다르게 가는 것

- **연재가 1급 개념**: 회차 번호·상태·분량이 목록에서 바로 보인다.
- **설정집이 따로 있다**: 원고 옆에서 참조하는 정형 데이터.
- **점유 · 분기 상태가 눈에 보인다**: ⚠ 는 `color.state.warning` 하나로 통일 — "다른 곳에서 편집 중"과 "갈라진 사본 있음"은 작가가 놓치면 안 된다.

## 판단 기준

1. 원고 면적을 줄이는 장식은 넣지 않는다. 그림자는 떠 있는 것(팝오버·다이얼로그)에만.
2. 위계는 색보다 굵기·크기·간격으로. ink 3단(primary · secondary · tertiary) 안에서 해결한다.
3. 한국어 본문 행간은 넉넉하게(`type.editor.body`). 영어 UI 라벨은 한국어보다 길다 — 버튼·탭은 en 으로 넘침을 먼저 본다.
4. 다크 모드는 반전이 아니라 따로 고른 값이다. 둘 다 workbench 에서 나란히 검수한다.

## 대비 (2026-10-01, workbench 대비표로 검출)

- 글자로 쓰이는 색은 **모든 면 위에서 4.5:1 이상**(WCAG AA 본문)을 지킨다. 예외는 `ink.markup` 하나 — Markdown 기호를 일부러 흐리게 두는 것이 정체성이라서.
- 초안 값에서 light `ink.tertiary` · `accent.primary` · `state.*` 가 2.6~4.2 였다 → 색상·채도는 두고 명도만 기준까지 옮겼다. 그 결과 accent 가 황토에서 **짙은 갈색** 쪽으로 내려왔다.
- tertiary 가 어두워지면서 secondary 와 겹쳐 ink 3단이 무너졌다 → secondary 를 한 단 더 진하게(light) · 밝게(dark) 벌렸다. 대비 순서: primary > secondary > tertiary 를 유지한다.

## 아이콘 · 컨트롤 (2026-10-08, 검토 필요)

- **아이콘은 Lucide 하나**(ISC). 어휘는 `design/icons.json` — 이름은 쓰임새(`history`, `reference`), 값은 Lucide 이름. 네 플랫폼이 같은 벡터를 쓴다(SF Symbols · Material 로 바꾸지 않는다 — 모양이 갈라지면 디자인 검수가 무의미해진다). 선 굵기 1.75.
- **글자로 아이콘을 그리지 않는다** (↺ ✕ ⚙ ◫ …). 폴백 글꼴마다 크기·굵기가 달라 화면이 조잡해진다 → `design:check` 가 막는다.
- **컨트롤은 kit 하나로**: Button(primary · secondary · ghost · danger) · IconButton · Segmented · Chip · Checkbox · Radio · Switch · TextField. 화면이 제각각 그리지 않는다. 네이티브도 같은 이름의 컴포넌트를 하나씩 만든다.
  - primary 는 화면에 하나. 나머지는 secondary(흰 면 + 선 + 얕은 그림자) 또는 ghost.
  - Segmented 는 가라앉은 트랙 위에 고른 칸만 떠 있는 모양(iOS · macOS 와 같은 문법).
  - 버튼 · 입력의 모서리는 `radius.control`, 묶음 상자는 `radius.panel`, 다이얼로그는 `radius.sheet`.
- 서체 Pretendard 는 workbench 에 번들(OFL) — 설치 여부와 상관없이 모든 기계 · 스냅샷이 같은 글꼴로 그린다.

## [미정]

- 본문 서체: Pretendard 로 시작. 명조 계열(Noto Serif KR 등) 선택지를 줄지.
- accent 색 최종값 — 지금은 황토색 잠정.
