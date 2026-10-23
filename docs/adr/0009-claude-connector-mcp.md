# ADR-0009 · Claude 연동: 읽기 전용 MCP 서버(ithaca-mcp)와 연재 통계

- 상태: 확정 (2026-10-24). 소유자 부재 중 core 담당이 결정했다. 바꾸려면 이 ADR을 고친다.
- 관련: [0001](0001-name-and-repository-structure.md) · [0002](0002-sheet-integrity-and-lease.md) · [0005](0005-i18n.md) · [0008](0008-mac-first-build-and-updates.md) · design/PRODUCT.md · design/screens/preferences/spec.md(Claude 연동) · docs/research/2026-10-24-serial-writers-and-platforms.md(P1)

## 맥락

PRODUCT.md는 "내 Claude가 내 설정집을 읽는다"를 핵심 차별점으로 둔다. 권한 기본값은 **읽기만**이고, Claude가 고친 것은 모두 `actor=claude`로 기록되어 되돌릴 수 있어야 한다(ADR-0002 §6). 데스크톱에서만 동작한다.

앱은 라이브러리의 쓰기 잠금(`.lock`)을 쥐고 있다. 그래서 Claude Desktop이 띄우는 별도 프로세스가 라이브러리를 읽으려면, 잠금 없이 아무것도 쓰지 않고 여는 방법이 필요하다.

MCP 규격은 2026-07-28 개정에서 `initialize` 핸드셰이크를 없앴다. 대신 요청마다 `_meta`에 버전을 싣는 무상태 방식으로 바뀌었다. 지금 배포된 Claude Desktop 같은 클라이언트는 아직 핸드셰이크 방식(2025-11-25 이하)을 쓸 수 있다.

## 결정

1. **`ithaca-mcp`는 stdio 바이너리다.**
   - `core/crates/ithaca-mcp`에 둔다. 앱 번들의 `Contents/MacOS/ithaca-mcp`로 넣고, 앱과 같은 서명으로 안쪽부터 서명한다(`tools/mac/build.sh`).
   - Claude Desktop 설정: `{"mcpServers":{"ithaca":{"command":"/Applications/Ithaca.app/Contents/MacOS/ithaca-mcp"}}}`
   - HTTP 서버, 주소, 토큰은 지금 만들지 않는다. stdio는 사용자가 직접 설정한 로컬 프로세스라서 인증이 필요 없다. 환경설정 spec의 "주소 · 토큰" 행은 원격 클라이언트가 필요해질 때 다시 판단한다.
2. **ithaca-ffi는 ithaca-mcp에 의존하지 않는다.**
   - ADR-0001 그림의 "mcp → ffi(feature desktop)"를 이렇게 바꾼다.
   - 앱이 쓰는 것은 설정 파일뿐이라서, `mcp.json`을 읽고 쓰는 코드는 ithaca-store(`store::mcp`)에 둔다. ffi는 그것을 노출만 한다.
3. **MCP 구현은 serde_json으로 직접 짠다.**
   - 공식 Rust SDK(rmcp)는 쓰지 않는다. tokio 같은 비동기 런타임과 매크로 의존성을 끌고 온다. 반면 우리 표면은 도구 6개와 리소스 2종뿐이다.
   - 새 개정(2026-07-28)과 옛 개정을 함께 지원하는 dual-era 동작을 직접 정할 수 있다.
   - 새 의존성이 없다.
4. **프로토콜은 dual-era로 한다.**
   - 현재 개정 **2026-07-28**: 요청마다 `_meta`를 보고, `server/discover`를 지원하고, 결과에 `resultType`을 붙인다.
   - 옛 개정: `initialize`로 **2025-11-25 · 2025-06-18 · 2025-03-26 · 2024-11-05**를 협상한다. 모르는 버전이 오면 2025-11-25로 답한다.
   - 지원하지 않는 버전을 `_meta`로 보내면 `-32022`를 돌려준다.
   - 메서드: `initialize`, `ping`, `server/discover`, `tools/list`, `tools/call`, `resources/list`, `resources/read`, `resources/templates/list`.
5. **읽기 전용이 기본이고, 요청마다 새로 연다.**
   - 도구를 호출할 때마다 `<library>/mcp.json`을 다시 읽고 `Store::open_read_only`로 연다. 이 열기는 잠금 없이 열고, 캐시도 정리도 purge도 하지 않는다.
   - 블록은 원자적으로 쓰인다. 그리고 sheet 블록이 그것을 가리키는 목차 블록보다 먼저 쓰인다. 그래서 앱이 방금 쓴 내용이 반쪽 없이 보인다(테스트로 확인했다).
   - 파일이 없거나, 깨졌거나, `enabled: false`이면 모든 도구가 "Ithaca → 설정 → Claude에서 켜라"는 오류를 돌려준다.
   - 목록에 있는 살아 있는 작품만 보인다. 숨긴 작품과 없는 작품은 같은 오류로 답한다.
6. **도구는 6개다**(영어 설명, ADR-0005): `list_projects`, `get_outline`, `read_sheet`, `search`, `get_lore`, `get_episode_stats`. 모두 `readOnlyHint`가 붙는다.
   - 크기 상한: sheet 200,000자, 설정집 150,000자(넘는 sheet는 목록으로 알려 준다), 검색 결과 100개(작품당 50개).
   - "연재 폴더"는 회차 정보가 있는 sheet를 하나라도 가진 폴더다. 작품 전체에 회차 정보가 하나도 없으면 첫 폴더를 연재 폴더로 본다. 나머지 폴더가 설정집(`get_lore`)이 된다.
7. **쓰기 도구는 아직 없다.**
   - 나중에 넣을 때는 `Access::Edit`인 도구를 만든다. 이 도구는 `mcp.json`의 `permission`이 허락할 때만 목록에 나온다.
   - 쓰기는 MCP 프로세스가 직접 라이브러리를 쓰기로 열어서 하지 않는다. **잠금을 쥔 앱을 거친다.** 그래야 블록이 `actor=claude`로 기록되고 history에서 되돌릴 수 있다.
   - 앱과 이어지는 통로(로컬 소켓, 요청 파일 등)는 그때 새 ADR로 정한다.
8. **연재 추가 기능(r3)**
   - `EpisodeInfo.excluded`: 프롤로그 · 외전 · 공지를 표시한다. 번호가 없고, 다시 번호 매기기에서 건너뛰며, 비축분에 세지 않는다. 예약 상태는 그대로 쓸 수 있어서 `next_release`에는 들어간다.
   - 플랫폼 분량은 "본문 칸에 붙여 넣는 글"로 센다. `platform_body`는 내보내기 기본 규칙에서 **제목 줄을 뺀** 글이다. 플랫폼마다 제목 칸이 따로 있기 때문이다. 문피아 · 노벨피아 목표 기준(`GoalBasis::Munpia/Novelpia`)과 폴더 통계의 플랫폼 합계가 이 기준을 쓴다.
   - `FolderStats`: 합계는 폴더의 모든 sheet로 낸다(프롤로그도 올리는 글이다). 평균과 상태 수는 회차(excluded가 아닌 sheet)로만 낸다.
   - 호환성: 목표 기준 `munpia | novelpia`를 쓴 작품은 r3보다 옛 core(앱 0.2.0 이하)가 목차를 읽지 못한다. 옛 core는 그 작품을 건너뛰고 알린다. 아무것도 쓰지 않고 데이터도 잃지 않는다. 앱은 업데이트로 앞으로만 가므로 이 위험을 받아들인다. format 번호는 올리지 않는다.

## 결과

- 의존성이 늘지 않았다. ithaca-mcp는 ithaca-model, ithaca-store, serde_json만 쓴다.
- 앱(Swift)에 새로 생기는 것: `Library.openReadOnly`, `mcpSettings()`, `setMcpSettings(enabled:projects:)`, `nextRelease`, `folderStats`, `goalCount`, `platformBody`, `EpisodeInfo.excluded`, `GoalBasis.munpia/.novelpia`. 계약은 `core/API.md`의 "(added: r3)" 항목이다.
- 검증: `core/crates/ithaca-mcp/tests/stdio.rs`가 실제 바이너리를 띄운다. 앱 역할을 하는 writer가 잠금을 쥔 상태에서 옛 핸드셰이크, 새 무상태 요청, 버전 오류, 숨긴 작품 차단, 설정 꺼짐 오류, 재시작 없이 새 글 보기를 확인한다.
