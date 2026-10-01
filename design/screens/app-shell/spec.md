# app-shell · 앱 뼈대 (라이브러리 / 시트 목록 / 에디터)

> 샘플 화면 — 파이프라인 검증용 초안. 화면 목록 확정(ADR-0006 4단계) 때 다시 쓴다.

## 목적
Ulysses 식 3단 구조가 size class 에 따라 어떻게 접히는지 정한다. 모든 화면이 이 뼈대 위에 선다.

## size class 별 레이아웃

| class | 보이는 pane | 숨은 pane 여는 법 |
|---|---|---|
| compact | 에디터 하나 | 상단 ‹ 뒤로 → 시트 목록 → 라이브러리 (push) |
| medium | 시트 목록 + 에디터 | 상단 ☰ → 라이브러리 overlay |
| expanded | 라이브러리 + 시트 목록 + 에디터 | — |
| large | expanded 와 같음 (+ 설정 참조 패널 자리, 미정) | — |

- 에디터 본문 폭은 `editor.measure` 에서 멈춘다. 남는 폭은 좌우 여백.
- pane 폭은 `pane.library` · `pane.sheetList` 기본값. 끌어서 조절은 네이티브 단계.

## 상태

- `default` — 3화 편집 중.
- `readonly` — 다른 기기가 점유 중(ADR-0002). 에디터 위 경고 띠 + [점유하기], 본문은 `opacity.readOnly`.

## 분량 표기
원고 언어를 따른다(ADR-0005): ko 원고 → `editor.charCount`(공백 포함 글자수), en 원고 → `editor.wordCount`.

## 플랫폼 관례 (프로토타입에서 흉내 내지 않음)
- 상단 바·뒤로 제스처·사이드바 토글 모양은 iOS / Android / macOS / Windows 기본을 따른다.
