# ADR-0001 · 이름과 저장소 구조

- 상태: 확정 (2026-10-01)
- 관련: [0002](0002-sheet-integrity-and-lease.md) · [0003](0003-sync-transports.md) · [0004](0004-ui-shells.md) · [0005](0005-i18n.md) · [0006](0006-design-first.md)

## 맥락

Ulysses를 몇 달 구독해서 써보고 나니 불편한 점이 많아서, 연재 소설 작업용 앱을 직접 만들어 오픈소스로 공개한다.
요구사항은 다음과 같다.

- iOS, Android, Mac, Windows 지원
- 서버 없이도 완전히 동작
- 내 Claude가 MCP로 작품 데이터를 읽고 쓸 수 있음 (desktop 전용)
- 설정 / 연재 / 아이디어를 정해진 틀로 구분
- Ulysses 같은 감성의 디자인

이미 있는 제품을 조사했지만(2026-10-01) 이 조합을 만족하는 건 없었다.

- **Manuskript**: 데스크톱 전용이고 동기화가 없으며 GPL-3.0이다.
- **Novelcrafter**: 웹 기반 구독 서비스이고, MCP 연동은 서드파티 실험 프로젝트뿐이다.
- **Campfire**: 모바일에서 온라인 연결이 필수이고 모듈 단위로 구독한다.

## 결정

### 이름
- 제품 이름은 **Ithaca**로 한다. 율리시스가 끝내 돌아간 고향이라는 뜻을 담았다. 구독에서 벗어나 내 원고가 돌아갈 집이라는 의미다.
- GitHub repo 이름은 `ithaca-writer`로 한다. "Ithaca"라는 단어 자체는 검색 경쟁이 심하기 때문이다. 같은 이름의 repo가 461개 있고, 그중 1위는 google-deepmind/ithaca다.
- 스토어 표기는 "Ithaca — Serial Writing"으로 한다.
- 코드 식별자는 다음과 같다.
  - crate prefix: `ithaca-`
  - bundle id / Gradle 패키지: `io.github.colosan.ithaca`
  - 도메인을 확보하면 그때 교체한다.

### 저장소: monorepo 하나

```
design/       디자인 데이터. 토큰 6축, 문자열, 화면(spec + prototype + 검수 상태)의 정본
workbench/    디자인 검수 뷰어 (Vite). design/ 을 읽기만 하고 meta.json 의 검수 기록만 쓴다
tools/        design-gen: design/ → Swift · Kotlin · workbench 생성물 + 위반 검사
fixtures/     샘플 작품. 프로토타입, 네이티브 preview, core 테스트가 함께 쓴다
core/         Rust workspace. 로직 전부 (model · ledger · diff · store · sync · mcp · ffi) + relay 서버
swift/        iOS · iPadOS · macOS (SwiftUI, XcodeGen)
kotlin/       Android · Windows (Compose Multiplatform)
docs/adr/     결정 기록
```

### 의존 방향 (한 방향으로만 흐른다)

```
ithaca-model ← ithaca-ledger ← ithaca-store ← ithaca-sync ─┐
                    ↑               ↑                        ├─ ithaca-ffi ← Swift / Kotlin
               ithaca-diff     ithaca-mcp ──────────────────┘   (mcp 는 feature "desktop")
ithaca-relay → ithaca-sync (protocol 만)

design/{tokens,strings} → tools/design-gen → swift · kotlin · workbench 생성물
```

- `ithaca-ledger`는 IO를 하지 않는다. 그래서 무결성 판정이나 분기 판정을 파일이나 네트워크 없이 테스트할 수 있다.
- 플랫폼 UI는 `ithaca-ffi`에 있는 함수만 호출한다. 이렇게 API 표면을 하나로 고정해서 iOS와 Android의 동작이 서로 어긋나는 것을 막는다.

### 라이선스
- 프로젝트 라이선스는 `MIT OR Apache-2.0` dual로 한다.
- GPL과 AGPL 의존성은 들이지 않는다. 앱스토어 약관과 충돌하기 때문이다.
- Manuskript 같은 GPL 프로젝트는 기능 아이디어만 참고하고, 코드는 가져오지 않는다.

### 명령 진입점
- 지금은 루트의 `package.json` 스크립트로 실행한다: `pnpm wb`, `pnpm design:gen`, `pnpm design:check`, `pnpm typecheck`.
- `justfile`은 Rust와 네이티브 빌드가 들어올 때 추가한다.

## 결과

- 처음에는 `design/`, `workbench/`, `tools/`만 실제로 동작한다. `core/`, `swift/`, `kotlin/`은 README만 있는 자리표시다.
- 생성물(`*/generated/*`)은 커밋한다. Xcode나 Gradle 빌드에 Node가 필요하지 않도록 하기 위해서다. 대신 생성물이 원본과 어긋났는지는 `design:check`가 검사한다.
