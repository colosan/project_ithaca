# 연재 작가 · 연재 플랫폼 · 경쟁 앱 · macOS 구현 함정 조사

- 작성: 2026-10-24 (researcher agent)
- 범위: 한국 웹소설 플랫폼 규칙, 연재 작가의 작업 흐름, 경쟁 앱 기능, macOS 네이티브 구현(ADR-0008) 함정
- 전제: PRODUCT.md(2026-10-01, 2026-10-08 제안 표), ADR-0001~0008을 읽고 그 틀 안에서 정리했다. ADR과 부딪히는 근거는 §6에 따로 적었다.
- **출처 신뢰도 표기**: 〔공식〕 플랫폼·벤더 공식 문서/공지 · 〔위키〕 나무위키 등 사용자 편집 문서 · 〔커뮤니티〕 디시·아카·블로그 경험담 · 〔홍보〕 경쟁 툴 회사가 쓴 비교글 · 〔미확인〕 근거가 하나뿐이거나 간접적인 것. 접근일은 모두 2026-10-24.

> 한 줄 결론: 플랫폼마다 **글자수를 세는 규칙이 다르고**(문피아 공백 포함 · 노벨피아 공백·문장부호 제외 · 조아라 용량), 붙여넣기에서 가장 흔한 사고는 **빈 줄이 두 배가 되는 것**이다. 작가가 실제로 관리하는 것은 **회차 번호 · 분량 · 비축분 · 예약일 · 설정**이다. 네이티브 쪽에서 가장 위험한 것은 **macOS 한글 2벌식이 marked text 없이 조합한다는 보고**와 **ad-hoc 서명 + Sparkle + 하드닝 런타임 조합**이다.

---

## 1. 한국 연재 플랫폼

공식 "작가 가이드"가 공개 웹에 거의 없다(대부분 로그인 뒤 작가 페이지에 있다). 아래 수치 중 〔공식〕이 아닌 것은 실제 업로드로 확인해야 한다.

### 1.1 분량 기준과 글자수 세는 법

| 플랫폼 | 최소/관행 분량 | 세는 법 | 근거 |
|---|---|---|---|
| **문피아** | 유료 회차 최소 **공백 포함 4,000자**(예전 5,000자), 무료 제한 없음. 일반연재 승급: 회차당 3,000자 이상, 총 75,000자(로맨스 50,000자), 7일 이상 | **공백 포함**. 내서재에 **쪽수**(1쪽 = 470자, 엔터 제외, 올림)와 글자수를 함께 표시. 연속 공백·줄바꿈을 1자로 압축한다는 설명도 있음 | 〔커뮤니티〕 [디시 웹소설연재 갤 2026-06-15](https://gall.dcinside.com/mgallery/board/view/?id=tgijjdd&no=1280077) · 〔커뮤니티〕 [스토리벤치 문피아 연재 방법](https://storybench.kr/blog/%EB%AC%B8%ED%94%BC%EC%95%84-%EC%97%B0%EC%9E%AC-%EB%B0%A9%EB%B2%95) · 〔공식〕 [문피아 공지 2026-02-23 "내서재 글자수 확인"](https://nhelp.munpia.com/notices/1773?page=0) · 〔미확인〕 연속 공백 압축: [pyozi 글자수 계산기](https://pyozi.com/tools/word-counter) |
| **노벨피아** | 플러스(유료) 신청: **매 화 공백 제외 3,000자 이상, 15화 이상**. 공모전도 공백 미포함 3,000자 | **띄어쓰기 · 점(.) · 따옴표(") · 쉼표(') · 개행 · 탭 · 느낌표 · 물음표 · 공백문자를 세지 않음**. 그래서 한글 프로그램의 "공백 제외 3,500자"가 노벨피아에서는 2,900자로 나왔다는 사례가 있음 | 〔공식〕 [노벨피아 FAQ "글자수 기준은 무엇인가요?" 2021-07-22](https://novelpia.com/faq/all/view_383218/) · 〔위키〕 [나무위키 노벨피아/시스템](https://namu.wiki/w/%EB%85%B8%EB%B2%A8%ED%94%BC%EC%95%84/%EC%8B%9C%EC%8A%A4%ED%85%9C) · 〔커뮤니티〕 [디시 663699](https://gall.dcinside.com/mgallery/board/view/?id=tgijjdd&no=663699) |
| **조아라** | 유료(노블레스) 최소 **10KB**(용량). 공백 미포함 약 3,000자 ≈ 공백 포함 약 4,150자로 환산된다는 추정. 노블레스 "성실연재"는 월 18일 이상 연재 | **용량(바이트) 기준** — 글자수가 아님 | 〔커뮤니티〕 [디시 2026-06-15](https://gall.dcinside.com/mgallery/board/view/?id=tgijjdd&no=1280077) · 〔언론, 2019〕 [웹툰가이드](https://www.webtoonguide.com/ko/board/news04_generalnews/9419) |
| **카카오페이지** | 공식 1화 기준 공개 없음. 투고는 HWP/DOCX 원고 + 시놉시스, 완성 원고 3화 이상이라는 설명 | 공백 포함이 관행 | 〔커뮤니티/미확인〕 [seosa.ink 투고 가이드](https://seosa.ink/blog/kakaopage-web-novel-submission-guide) |
| **카카오페이지 스테이지** | **2024-12-20 폐쇄** (자유연재 플랫폼). 조사 대상에서 사실상 제외 | — | 〔위키〕 [나무위키 카카오페이지 스테이지](https://namu.wiki/w/%EC%B9%B4%EC%B9%B4%EC%98%A4%ED%8E%98%EC%9D%B4%EC%A7%80%20%EC%8A%A4%ED%85%8C%EC%9D%B4%EC%A7%80) — 종료일은 출처마다 다름(2024-05-20 설도 있음) 〔미확인〕 |
| **네이버 웹소설 / 시리즈** | 챌린지리그 → 베스트리그(장르별 주간 랭킹으로 자동 승격, 2020 개편). 2025-01 이후 시리즈에디션 신작은 네이버 시리즈에만. 정식 연재 "공백 포함 6,000자 이상"이라는 2019년 댓글이 있으나 현재 기준인지 불명 | 공백 포함이 관행 | 〔위키〕 [나무위키 네이버웹소설](https://namu.wiki/w/%EB%84%A4%EC%9D%B4%EB%B2%84%EC%9B%B9%EC%86%8C%EC%84%A4) · 〔언론〕 [뉴스핌 2020-06-09](https://www.newspim.com/news/view/20200609000350) · 〔미확인〕 6,000자 |
| **리디** | 공식 회차 규격 공개 없음. 투고 경로만 안내 | — | 〔공식〕 [리디 고객센터 투고 방법](https://ridihelp.ridibooks.com/support/solutions/articles/154000210045-%EC%9B%B9%ED%88%B0-%EC%9B%B9%EC%86%8C%EC%84%A4-%ED%88%AC%EA%B3%A0-%EB%B0%A9%EB%B2%95) |

**업계 관행**: "공백 포함 5,000자 안팎(4,000~6,000)"이 1화의 사실상 표준이고, 100원 단가의 기준으로 통한다. 주 5~7회 연재. 〔커뮤니티〕 [브런치 "웹소설 분량은 어떻게 써야 할까"](https://brunch.co.kr/@qsza45/11) · [pyozi 2026-03-12](https://pyozi.com/blog/word-count-guide)

**Ithaca에 대한 함의**
- "공백 포함 · 공백 제외" 두 숫자(PRODUCT 결정)는 맞지만 **충분하지 않다**. 같은 원고가 플랫폼마다 다른 숫자로 나온다. 특히 노벨피아는 문장부호까지 빼므로 "공백 제외"와 수백 자 차이가 난다. 작가는 마감 직전 이 차이 때문에 플랫폼 입력창에 붙여 보고 다시 고친다.
- **"공백"의 정의를 고정해야 한다.** 줄바꿈을 공백 포함 수에 넣는지(문피아 쪽수는 엔터 제외), 연속 공백을 몇 자로 볼지. 한글(HWP) · 문피아 · 우리 앱의 숫자가 어긋나면 사용자는 앱을 믿지 않는다. → §5 P0 "분량 규칙 고정".
- 목표 분량에 **플랫폼 기준**(문피아 공백 포함 / 노벨피아 기준 / 조아라 KB)을 고를 수 있으면 "규칙 4개" 붙여넣기 결정을 바꾸지 않고도 플랫폼 차이를 흡수할 수 있다.

### 1.2 붙여넣기 동작 (입력창 · 줄바꿈 · 특수문자)

- **빈 줄 두 배 문제 (가장 흔함)**: 문단 기반 에디터(Tiptap/ProseMirror 등)에서 복사하면 클립보드의 plain text가 문단을 `\n\n`으로 잇고 HTML `<p>`도 같이 실려서, 노벨피아 입력창에서 Enter 한 번이 "빈 줄 낀 두 줄"이 됐다. 고친 방법: **클립보드에 HTML 없이 plain text만**, 문단 하나 = 한 줄, 빈 문단 하나 = 빈 줄 하나. 반대로 plain text 붙여넣기/TXT 내보내기에서 연속 줄바꿈을 접어 **장면 전환용 빈 줄이 사라지는** 버그도 있었다. 〔커뮤니티, 2026-10-09〕 [Guksu/builbook PR #19](https://github.com/Guksu/builbook/pull/19) — 문피아·네이버는 작성자가 직접 확인하지 못함.
- **노벨피아 에디터**: 외부 서식은 대부분 지워짐. 굵게·기울임·밑줄만, 글자색 검정, 왼쪽 정렬 고정. 자동 저장이 불완전하다는 평. 공개일(예약) 옵션 있음. 맞춤법 검사 BETA는 약함. Ctrl+Enter로 만든 빈 줄이 게시 후 한 줄 띄우기로 바뀌고, 탭·취소선 미지원이라 띄어쓰기로 대체한다는 경험담. 〔위키〕 [나무위키 노벨피아/시스템](https://namu.wiki/w/%EB%85%B8%EB%B2%A8%ED%94%BC%EC%95%84/%EC%8B%9C%EC%8A%A4%ED%85%9C) · 〔커뮤니티, 2024-11〕 [아카라이브 질문글](https://arca.live/b/webfiction/120760071)
- **문피아 에디터**: 2026-02 개편에서 입력창 크기 조절, **"붙여넣기" 버튼**(미리 복사한 글을 넣는 전용 버튼), 글자수 표시, 예약 시간 자동 불러오기가 추가됐다. 〔공식〕 [문피아 공지 2026-02-23](https://nhelp.munpia.com/notices/1773?page=0). 아주 오래된 공지지만 **같은 특수문자를 30개 넘게 이은 구분선**(`-----`, `=====`)은 줄바꿈이 안 돼 화면이 깨지니 줄여 달라는 안내가 있다. 〔공식, 2005-08-11〕 [문피아 공지 437](https://nhelp.munpia.com/notices/437?page=63)
- **들여쓰기**: 웹 입력창은 대부분 앞쪽 공백이나 탭을 보존하지 않거나 플랫폼 뷰어가 자체 문단 스타일을 쓴다. 탭/스페이스 들여쓰기는 음절 폭 차이로 고르지 않게 보인다는 편집자 조언도 있다. 〔커뮤니티〕 [페스트북 원고 작성법](https://festbook.co.kr/%EC%9E%91%EA%B0%80%EB%8B%98-%EC%9B%90%EA%B3%A0%EB%8A%94-%EC%9D%B4%EB%A0%87%EA%B2%8C-%EB%B3%B4%EB%82%B4%EC%A3%BC%EC%8B%9C%EB%A9%B4-%EC%A2%8B%EC%95%84%EC%9A%94/). 모바일 웹소설은 **들여쓰기 없이 문단 사이 빈 줄**이 관행이라는 설명이 많다(카카오 투고 가이드: "문단 간 1줄 공백, 대화 앞 들여쓰기 없음" 〔미확인〕 [seosa.ink](https://seosa.ink/blog/kakaopage-web-novel-submission-guide)). → 현재 export 기본값(빈 줄 ○ · 들여쓰기 ✕)과 일치한다.
- **특수문자 관행**: `……`(가운데 여섯 점이 원칙, `…`·`...`도 흔함), `『』`(책·매체 제목), `「」`(소제목·편지·메시지), `─`(줄표), `·`, `* * *`(장면 전환). 상태창·시스템 메시지에는 `[ ]`, `【 】`, `《 》` 등이 쓰이지만 플랫폼 규정은 없다. 〔커뮤니티〕 [판무저장소 특수문자 모음](https://fanmooz.com/%EC%9B%B9%EC%86%8C%EC%84%A4-%ED%8A%B9%EC%88%98%EB%AC%B8%EC%9E%90/) · [디시 "말줄임표 쓰는 법"](https://gall.dcinside.com/mgallery/board/view/?id=tgijjdd&no=299140). 노벨피아는 `.` `"` `'` `!` `?`를 세지 않으므로 `...`과 `…`는 같은 0자, 문피아에서는 3자 대 1자다 → 말줄임표 스타일이 분량을 바꾼다.
- **Markdown 기호**: Ithaca 시트는 Markdown이므로 `*`, `**`, `#`, `>`가 플랫폼에 그대로 들어가면 사고다. export "Markdown 기호 지우기" 기본 ○는 맞다. 단, `* * *`(장면 전환)를 "기호"로 오인해 지우면 안 된다(Markdown에서는 수평선). → 수평선은 사용자가 고른 장면 전환 문자열로 바꾸는 규칙이 필요.

### 1.3 회차 제목 · 번호 · 예약

- **회차 번호는 플랫폼이 붙인다.** 작가가 쓰는 회차 제목은 보통 "부제" 또는 "N화. 부제"/"부제 (N)" 같은 자유 형식이다. 프롤로그를 1화로 묶거나 따로 두는 경우가 섞여 있어 **작가의 회차 번호와 플랫폼의 번호가 어긋날 수 있다**. 외전은 본편 완결 뒤에 붙인다. 〔커뮤니티〕 [아카라이브 프롤로그 글](https://arca.live/b/webfiction/28589346) · [브런치 웹소설 쓰는 법](https://brunch.co.kr/@blueear64/17) — 번호 표기 관행에 대한 공식 근거는 찾지 못함 〔미확인〕.
- **예약 연재**: 문피아는 예약글 접기/펼치기, 직전 예약 시간 자동 불러오기(2026-02). 노벨피아는 "공개일 사용". 커뮤니티에서는 8시간/12시간 텀 연재, 장르별 시간대(판타지 17~18시, 현판·스포츠 12~13시) 같은 전략이 돈다. 연재 시작 전 **15화 비축**이 흔한 조언. 〔공식〕 [문피아 공지](https://nhelp.munpia.com/notices/1773?page=0) · 〔커뮤니티〕 [디시 "문피아 연재 예약하는 법"](https://m.dcinside.com/board/tgijjdd/503891) · [스토리벤치](https://storybench.kr/blog/%EB%AC%B8%ED%94%BC%EC%95%84-%EC%97%B0%EC%9E%AC-%EB%B0%A9%EB%B2%95)
- **용어**: 비축분(올리지 않은 완성 원고), 생방(비축 없이 써서 바로 올림), 투베(문피아 투데이베스트), 휴재 공지. 〔커뮤니티〕 [디시 웹소설용어 2편](https://gall.dcinside.com/mgallery/board/view/?id=tgijjdd&no=885848)
- **함의**: Ithaca는 플랫폼에 올리지 않는다(서버 없음 원칙). 대신 작가가 "어느 회차를 어디에 언제 올렸는지 / 올릴지"를 앱 안에 적어 둘 수 있으면 된다. 이것이 PRODUCT [미정] 1번 "회차 정보"의 답에 가깝다 → §5 P1.

---

## 2. 연재 작가의 하루 작업 흐름

### 2.1 쓰는 도구
- **한글(HWP)**: 맞춤법 검사 품질과 원고지 매수 때문에 여전히 많다. 투고 원고가 HWP/DOCX인 곳이 있다. 〔홍보〕 [타입탁 "작가들에게 물어본 웹소설 프로그램"](https://www.typetak.com/ko/blog/webnovel_program) · [펜시브 비교](https://pensiv.so/ko/blog/writing-program-comparison)
- **스크리브너**: 장편·자료 관리용. 학습 곡선, 약 88,000원, 한글화가 기계 번역 수준이라는 불만, 스크립트 모드·내보내기에서 한글 깨짐 사례. 〔커뮤니티〕 [클리앙 스크리브너 내보내기 한글 깨짐](https://www.clien.net/service/board/cm_mac/12847500) · [클리앙 시나리오 한글 오류](https://www.clien.net/service/board/cm_mac/6580824)
- **율리시스**: Mac/iOS 사용자. 장점으로 "충돌 없는 동기화 · 글자 수 목표 · 오류 없는 내보내기 · 깔끔한 UI · 눈 편한 배경"이 꼽히고, 단점은 **연 5만 원 구독**, Apple 전용, 영어 위주 UI. 한 작가는 대체 앱을 찾아보다 위 조합을 다 가진 앱이 없어 돌아왔다고 썼다 → **Ithaca가 이 다섯 가지를 다 갖춰야 갈아탈 이유가 생긴다.** 〔커뮤니티〕 [Threads @iron.storybuilder](https://www.threads.com/@iron.storybuilder/post/C9UBuQ3Twqb) · [브런치 툴 총정리](https://brunch.co.kr/@morningwalk/1243)
- **구글 독스**: 무료·클라우드·댓글. 노벨피아 최적화 세팅 공유글이 있을 정도로 많이 쓴다. 구조화와 맞춤법은 약함. 〔커뮤니티〕 [아카라이브 구글 문서 노벨피아 세팅](https://arca.live/b/webfiction/32187112)
- **노션**: 본문보다 **설정집·캐릭터 DB·플롯 보드** 보조용. 〔홍보〕 위 비교글들
- **옵시디언**: 메모장 → 한글 → 노벨라 → 스크리브너 → 워드 → 구글독스 → 노션 → 뮤블을 거쳐 정착했다는 작가의 가이드(2025-05-26). 플랫폼별 글자수 플러그인(Pia-count), 프로젝트 칸반, 캔버스로 설정 정리, 줄간격 2.0·들여쓰기 1em CSS. 단점: **"모든 걸 직접 설정해야"** 해서 추천받은 사람들이 포기. 〔커뮤니티〕 [디시 옵시디언 가이드](https://gall.dcinside.com/mgallery/board/view/?id=tgijjdd&no=1093753) → 옵시디언 수준의 기능을 **설정 없이 기본값으로** 주는 것이 Ithaca의 자리다.
- **국내 웹소설 전용 툴(직접 경쟁자)**: 노벨라(웹, 월 9,900원, 부산대 맞춤법 검사, 플롯 2D 배치, 캐릭터-회차 연동), 펜시브(로컬 모드, AI Ask/Plan/Agent/Review, 한국어 맞춤법), 타입탁(AI, 인물 관계도), 뮤블(데스크톱 무료, 위젯·화면 분할). 모두 **한국어 맞춤법 검사**를 핵심 기능으로 내세운다. 〔홍보〕 [노벨라 블로그 2025-11-25](https://novela.so/ko/blog/writing-programs-for-authors) · [펜시브](https://pensiv.so/ko/blog/writing-program-comparison)

### 2.2 흔한 불만 (반복해서 나온 것)
1. **플랫폼과 글자수가 안 맞는다** — 노벨피아식 글자수 표시 프로그램이 따로 돌 정도. 〔커뮤니티〕 [아카라이브 노벨피아식 글자수 프로그램](https://arca.live/b/webfiction/112965368)
2. **붙여넣으면 줄간격·빈 줄이 망가진다**, 모바일에서 다르게 보인다 → 플랫폼 화면과 맞추려고 "조판 양식"(맑은 고딕 10pt, 줄간격 160% 등)을 따로 만든다. 〔커뮤니티〕 [아카라이브 노벨피아 조판양식](https://arca.live/b/webfiction/32132394)
3. **플랫폼 에디터 자동 저장을 못 믿는다** → 외부에서 쓰고 붙여넣는다.
4. **맞춤법** — macOS/외산 앱은 한국어 맞춤법이 약해 부산대 검사기를 따로 돌린다.
5. **구독 피로**(율리시스), **설정 지옥**(옵시디언), **학습 곡선**(스크리브너).
6. **Mac 한글 입력 지연** — 긴 문서 중간에서 타자가 몇 초 늦게 따라온다는 보고(스크리브너·율리시스·메모 공통, 특정 macOS 버전 이후). 〔커뮤니티〕 [클리앙 "맥 한글입력 딜레이"](https://www.clien.net/service/board/cm_mac/14465092)

### 2.3 작가가 추적하는 것
| 항목 | 어떻게 | Ithaca 현재 |
|---|---|---|
| 회차 번호 · 순서 | 파일명/시트명, 엑셀 | 시트 순서(작가가 정함). 번호 없음 |
| 회차 분량 | 플랫폼 기준 글자수 | 공백 포함·제외, 원고지 매수 |
| **비축분 수** | 엑셀 "작성 회차 − 발행 회차" | 없음 |
| 연재 일정 · 예약일 · 플랫폼 | 플랫폼 예약 + 메모 | 없음([미정] 1) |
| 회차 상태(초고/퇴고/발행) | 색 라벨, 폴더 | 없음([미정] 1) |
| 설정집 · 캐릭터 시트 | 노션 DB, 별도 문서 | 설정 폴더 + 참조 패널 |
| 복선(설치 회차 → 회수 회차) | 엑셀/노션 표. "미회수 복선이 10개 넘으면 위험" | 없음 |
| 완결 예상일 | 목표 회차 ÷ 주당 연재 수 | 없음 |

근거: 〔커뮤니티〕 [스토리벤치 도구·완결 회차 글](https://storybench.kr/blog/%EC%9B%B9%EC%86%8C%EC%84%A4-%EC%99%84%EA%B2%B0-%EB%AA%87%ED%99%94) · [디시 용어집](https://gall.dcinside.com/mgallery/board/view/?id=tgijjdd&no=885848)

---

## 3. 경쟁 앱 기능

| 앱 | 이 사용자에게 의미 있는 기능 | 출처 |
|---|---|---|
| **Ulysses** | 라이브러리 → 그룹 → 시트, 시트 **붙이기(glue)**, 필터(텍스트·날짜·키워드), 키워드, **목표(시트·그룹·프로젝트) + 마감일 → 하루 분량 자동 계산**, 진행 색(파랑→초록→빨강), 타자기 모드(2016), 리비전 모드(2020), Material 시트(2020), **Projects + 프로젝트별 키워드·내보내기 설정(2022-12)**, 내부 링크·백링크(2024~25), Apple Intelligence Writing Tools(2024-10), **프로젝트 템플릿(2026-09)**, 프로젝트/그룹/필터 통계 화면(2026-05), 스타일시트(ulss) 내보내기 | 〔공식〕 [Ulysses releases](https://ulysses.app/releases/) · [Goals](https://help.ulysses.app/goals) · [Sheets & Groups](https://help.ulysses.app/the-library/567894-sheets-groups) — glue는 공식 페이지에서 이번에 재확인 못 함 〔미확인〕 |
| **Scrivener 3** | 바인더, 코르크보드(카드 시놉시스, 라벨 색), **스냅숏**(문서별 버전), **Compile**(여러 문서 → 하나의 출력), Scrivenings(여러 문서를 이어 보기), 컬렉션, 사용자 메타데이터(체크박스·날짜·목록), 북마크, 목표 | 〔언론/서적〕 [MacStories](https://www.macstories.net/?p=52009) · [Take Control of Scrivener 3](https://www.oreilly.com/library/view/take-control-of/9781492065791/) |
| **iA Writer** | 집중 모드(문장/문단), 타자기 스크롤, 품사 하이라이트, 스타일 체크(군더더기·클리셰, 사용자 패턴), **Authorship**(직접 쓴 글과 붙여넣은/AI 글 구분), Content Blocks, 위키링크 | 〔공식〕 [iA Writer Support](https://ia.net/writer/support/) |
| **Novelcrafter** | **Codex**(설정집) — 이름·별칭이 본문에서 자동 인식·링크, 등장 위치 목록, **Progressions**(특정 장면 이후에만 유효한 설정 변화: 결혼·직업 변화 등), 시리즈 단위 codex | 〔공식〕 [Codex](https://www.novelcrafter.com/features/codex) · [Progression additions](https://docs.novelcrafter.com/en/articles/8675593-progression-additions) |
| **Campfire** | 모듈 구독(타임라인·백과사전·인물·지도…), 무료 25,000단어 제한, 웹은 온라인 필수, 데스크톱 앱만 오프라인 | 〔공식〕 [Campfire pricing](https://www.campfirewriting.com/pricing) · [apps](https://www.campfirewriting.com/apps) |
| **Manuskript** (GPL — 아이디어만) | 눈송이식 개요, 인물/플롯/세계 탭, 장면별 상태·목표 — ADR-0001 대로 코드는 보지 않음 | ADR-0001 |
| **국내 툴** | 노벨라·펜시브·타입탁: 한국어 맞춤법, 캐릭터-회차 연동, AI 피드백, 구독/웹 기반 | §2.1 |

### 3.1 table stakes vs differentiator (한국 연재 작가 기준)

**Table stakes — 없으면 Ulysses에서 넘어오지 않는다**
- 빠르고 안정적인 한글 입력(긴 문서에서도 지연 없음, 자소 분리 없음)
- 자동 저장 + 잃어버리지 않는다는 확신(버전/백업)
- 공백 포함·제외 글자수, 시트 목표와 진행 표시
- 폴더/그룹 → 시트, 순서 바꾸기, 검색
- 플랫폼 입력창에 그대로 붙여넣을 수 있는 복사
- 집중 모드, 타자기 스크롤, 눈 편한 테마/글꼴/줄간격
- 내보내기(txt · docx), 백업

**Differentiator — Ithaca만의 이유**
- **플랫폼별 글자수**(문피아 쪽수 · 노벨피아 기준 · 조아라 KB)를 한 화면에서 — 지금 작가들이 플러그인·별도 프로그램으로 하는 일
- **회차 메타데이터**(번호·상태·발행일·플랫폼) + **비축분 수** — 연재 작가 고유의 숫자
- **설정 참조 패널 + Claude(MCP)가 설정집을 읽음** — Novelcrafter codex를 로컬·무구독으로
- 구독 없음 · 오픈소스 · 로컬 파일 · Claude가 고친 것은 전부 기록·되돌리기(ADR-0002 actor=claude)
- 장기적으로: 설정 항목의 **회차별 변화(progression)**, 복선 추적

---

## 4. macOS 네이티브 구현 함정 (조사 결과)

### 4.1 한글 IME × NSTextView / TextKit 2
- **macOS 한국어 2벌식은 marked text를 쓰지 않을 수 있다.** `replacementRange`를 존중하는 클라이언트(일반 NSTextView 포함)에서는 `setMarkedText`를 부르지 않고, 매 키마다 `insertText:replacementRange:`로 **방금 넣은 글자를 바꿔 쓴다**. 클라이언트가 replacement를 무시하는 걸 한 번 보면 그 앱에 한해 marked text 모드로 바꾸고 이를 기억한다. 〔커뮤니티, 2026-10, macOS 27에서 수동 확인〕 [longbridge/gpui-kit PR #3341](https://github.com/longbridge/gpui-kit/pull/3341) · [secondlife/viewer PR #6459](https://github.com/secondlife/viewer/pull/6459) — 두 프로젝트의 관찰이고 Apple 문서는 없음 〔미확인〕.
  - 결과 1: **`hasMarkedText()`로 "조합 중"을 판별하는 코드는 한글에서 틀린다.** 조합 중에도 텍스트 저장소가 매 키마다 바뀐다.
  - 결과 2: 사용자 정의 undo가 있으면 **⌘Z가 자모 하나씩 되돌아간다**(gpui-kit이 겪은 버그). 표준 NSTextView undo는 AppKit이 묶어주지만, 우리가 `textStorage`를 직접 고치는 경로(Markdown 기호 흐리게, 짝 닫기, 둥근 따옴표, 붙여넣기 변환)는 undo 그룹을 직접 관리해야 한다.
  - 결과 3: 키마다 텍스트가 바뀌므로 **"텍스트 변경 → 저장 → hash chain 블록"을 키마다 하면 안 된다.** 블록은 debounce(예: 입력 멈춤 1~2초, 시트 전환, 앱 비활성) 단위로.
- **조합 중 속성 변경**: marked text가 있는 동안 하이라이터가 `textStorage` 속성을 다시 칠하면 선택 범위·조합이 깨지거나 main thread가 바빠진다. 고친 사례는 `hasMarkedText()`가 참이면 칠하기를 미루고, commit/cancel 뒤 한 번 칠한다. 〔커뮤니티〕 [flashtex PR #871](https://github.com/flash-tex/flashtex/pull/871) · 속성 변경 시 선택이 튀는 이유: [Christian Tietze 2017](https://christiantietze.de/posts/2017/11/syntax-highlight-nstextstorage-insertion-point-change/). 한글은 위의 모드 때문에 marked text가 없어도 "방금 바꿔 쓴 음절"이 있다 → **커서가 있는 문단은 칠하기를 지연**하는 편이 안전.
- `shouldChangeTextIn`은 타이핑뿐 아니라 undo와 Writing Tools 동작에서도 불린다 — marked 상태만으로 걸러내면 안 된다. 〔공식 포럼〕 [Apple forums 808915](https://developer.apple.com/forums/thread/808915)
- **TextKit 2 → 1 조용한 전환**: `textView.layoutManager`를 한 번이라도 읽으면 TextKit 1으로 영구 전환되고 `textLayoutManager`는 nil이 된다. NSTextTable도 전환을 일으킨다. `NSTextView.willSwitchToNSLayoutManagerNotification`으로 감지. 〔공식 포럼〕 [Apple forums 833107](https://developer.apple.com/forums/thread/833107) · [TextKit 2 정리 (shadowfacts)](https://shadowfacts.net/2022/textkit-2/)
- **TextKit 2 큰 문서 성능**: 약 3,000줄을 넘으면 스크롤이 눈에 띄게 나빠지고, `ensureLayout`로 문서 끝까지 이동하면 수 초, 추정 높이가 틀려 스크롤바가 튄다는 보고. 〔공식 포럼〕 [729491](https://developer.apple.com/forums/thread/729491) · [761364](https://developer.apple.com/forums/thread/761364) · [795657](https://developer.apple.com/forums/thread/795657) · [797770](https://developer.apple.com/forums/thread/797770) · STTextView 저자의 비판 〔커뮤니티〕 [feedbagel 요약](https://feedbagel.com/post/textkit-2-promised-improvements-marred-by-implementation-issues). 다행히 웹소설 한 회차는 5,000자 ≈ 50~150문단이라 시트 하나는 작다. **위험한 것은 "폴더 전체 이어 보기"(Scrivenings식)와 export 미리보기**다.
- **한국어 줄바꿈**: `NSParagraphStyle.lineBreakStrategy`에 `.hangulWordPriority`("한글 사이에서 줄을 끊지 않음")를 넣으면 어절 단위로 줄이 바뀐다(CSS `word-break: keep-all`과 같은 효과). `.standard`는 "UI 라벨과 같은 설정"이라고만 되어 있어 본문에 무엇이 들어가는지 문서로는 알 수 없다. 〔공식〕 [LineBreakStrategy](https://developer.apple.com/documentation/appkit/nsparagraphstyle/linebreakstrategy-swift.struct) · 배경 〔W3C〕 [Approaches to line breaking](https://w3c.github.io/i18n-drafts/articles/typography/linebreak.en). TextKit 2에서의 동작, 공백 없는 긴 문자열("으아아아아…", URL)에서의 넘침은 문서가 없어 **직접 확인 필요** 〔미확인〕.
- **맞춤법**: macOS 내장 맞춤법 검사기가 한국어를 지원하는지 공식 근거를 찾지 못했다. `NSSpellChecker.availableLanguages`를 실기기에서 찍어 확인해야 한다 〔미확인〕. 국내 경쟁 툴은 모두 부산대 검사기를 내세우는데, 공개 API·약관은 확인되지 않았다(외부 서버 호출은 "서버 없이 동작" 원칙과도 긴장이 있다).

### 4.2 Sparkle 2 × ad-hoc 서명 × Gatekeeper
- **Sparkle 문서**: ad-hoc 서명으로 실행하면 **Library Validation이 켜진 경우 시스템이 Sparkle.framework 로드를 거부할 수 있다.** Developer ID 서명이면 문제없다. 비 Xcode 프로젝트는 `-Wl,-rpath,@loader_path/../Frameworks` 필요. zip에는 앱만 넣어 **App Translocation**을 줄이라고 하고, 읽기 전용 위치나 translocation 때문에 업데이트가 실패해도 **기본으로는 사용자에게 알리지 않는다.** 필수 키: `SUFeedURL`, `SUPublicEDKey`, 증가하는 `CFBundleVersion`. 〔공식〕 [Sparkle documentation](https://sparkle-project.org/documentation/)
- **현재 `tools/mac/build.sh`는 `codesign --force --deep --sign - --options runtime`** 이다. `--options runtime`(하드닝 런타임)은 Library Validation을 켜므로 위 경고에 그대로 걸릴 수 있다. 또 Apple은 **서명에 `--deep`을 쓰지 말고 안쪽부터(XPC 서비스 → Autoupdate → Sparkle.framework → 앱) 하나씩 서명**하라고 권한다. 〔공식 포럼/TN2206 인용〕 [Apple forums 15433](https://developer.apple.com/forums/thread/15433) · [Tor 메일링 TN2206 인용, 2015](https://archives.seul.org/or/dev/Oct-2015/msg00186.html)
- **Gatekeeper**: macOS 15 Sequoia부터 **Control-클릭 → 열기 우회가 없어졌다.** 처음 실행이 막히면 시스템 설정 → 개인정보 보호 및 보안 → "확인 없이 열기(Open Anyway)". 〔언론〕 [Macworld](https://www.macworld.com/article/2457844/what-to-do-when-you-cant-open-an-app-you-just-installed-in-macos-sequoia.html) · [iDownloadBlog](https://www.idownloadblog.com/apple-macos-sequoia-gatekeeper-change-install-unsigned-apps-mac/). 본인이 빌드한 앱은 quarantine 속성이 없어 해당 없음(ADR-0008과 일치). GitHub에서 받은 zip은 quarantine이 붙고, 다운로드 폴더에서 바로 실행하면 translocation된다 → `/Applications`로 옮기라는 안내 필요.
- **Sparkle 업데이트 후**: Sparkle이 내려받은 업데이트에는 quarantine이 붙지 않아 이후 업데이트는 경고 없이 열린다는 보고가 다수. 반면 **macOS 15+에서 ad-hoc 앱을 Autoupdate가 교체하면 TCC "앱 관리" 프롬프트, cdhash 캐시 무효화, "손상되었습니다" 차단이 잦다**는 반대 보고도 있다(근거 인용 없음). 〔커뮤니티, 2026-10〕 [vlewin/splash-control #28](https://github.com/vlewin/splash-control/issues/28) 〔미확인〕
- **ad-hoc의 지정 요구사항(DR)은 빌드마다 바뀐다.** 그래서 업데이트할 때마다 **키체인 항목 접근 프롬프트**가 다시 뜨고, 손쉬운 사용·파일 접근 같은 **TCC 권한이 초기화**된다. 고정 인증서로 서명하면 DR이 빌드 간에 같다. 〔공식〕 [TN3127 Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) · 〔공식 포럼〕 [98484](https://developer.apple.com/forums/thread/98484). 앞으로 동기화 E2E 키(ADR-0003)를 키체인에 두면 업데이트마다 프롬프트가 뜬다.

### 4.3 SwiftPM만으로 SwiftUI 앱 만들기
- `swift build`는 실행 파일만 만든다. **`.app` 번들로 실행해야** Dock·활성화·번들 ID 문제가 없다(이미 build.sh가 그렇게 함). 〔커뮤니티〕 [theswiftdev](https://theswiftdev.com/how-to-build-macos-apps-using-only-the-swift-package-manager/) · 대안 도구 [Swift Bundler](https://swiftpackageregistry.com/stackotter/swift-bundler)
- **`Bundle.module`**: SwiftPM이 생성하는 접근자는 정해진 위치(빌드 경로 절대값 포함)에서 `<Package>_<Target>.bundle`을 찾고 없으면 **`fatalError`**. 개발 Mac에서는 빌드 폴더 절대 경로로 찾아져서 동작하다가 **다른 Mac이나 `swift package clean` 뒤에 죽는** 전형적 함정. 지금은 리소스를 선언한 타깃이 없지만, 생기면 직접 만든 번들 찾기(`Bundle.main.resourceURL` 기준)를 쓰고 빌드 폴더를 지운 상태로 실행해 확인할 것. 〔공식 포럼〕 [Apple forums 678490](https://developer.apple.com/forums/thread/678490) · 〔Swift Forums〕 [Bundle.module not available](https://forums.swift.org/t/bundling-resources-with-a-swift-package-bundle-module-not-available/84185)
- 에셋 카탈로그(`actool`)·`.icns` 생성·`.xcstrings` 컴파일·SwiftUI Preview는 Command Line Tools만으로는 안 되거나 불편하다(아이콘 생성 스크립트가 Xcode를 요구한 사례). 〔커뮤니티〕 [macos-spm-app-packaging](https://www.skills.sh/dagba/ios-mcp/macos-spm-app-packaging). ADR-0005가 이미 OS 리소스 대신 생성 테이블을 쓰므로 문구는 문제없고, 아이콘은 체크인된 `.icns`를 쓰면 된다.

---

## 5. 우선순위 기능 목록

화면 이름은 `design/screens/<slug>`. "신규"는 아직 화면이 없는 것.

### P0 — 첫 매일 쓰는 Mac 버전
| 기능 | 한 줄 근거 | 화면 |
|---|---|---|
| **한글 입력 무결성**: 자소 분리·글자 누락 0, 조합 중 칠하기 지연, 한글 undo가 음절/단어 단위 | Ulysses 대체의 최소 조건이고, 2벌식이 marked text 없이 조합한다는 보고가 있어 기본값을 믿을 수 없다 | app-shell(에디터) |
| **어절 단위 줄바꿈**(`hangulWordPriority`) + 넉넉한 줄간격 기본값 | 음절 단위로 끊긴 한글은 플랫폼 화면과 달라 보이고 퇴고를 방해한다 | app-shell · preferences(에디터) |
| **자동 저장 + 매일 로컬 백업**(이미 결정) + 저장됨 표시 | 작가들이 플랫폼 에디터를 떠나는 첫째 이유가 "저장을 못 믿어서"다 | app-shell · preferences(백업) |
| **분량 규칙 고정**: 공백 포함·제외의 정의(줄바꿈·연속 공백·grapheme) 문서화, 하단 상시 표시, 시트 목표 진행 | 한글·플랫폼과 숫자가 어긋나면 앱 숫자를 믿지 않는다 | app-shell(하단 · 정보 탭) · project-settings |
| **플랫폼 붙여넣기 복사**: plain text만 클립보드에, 문단=한 줄, 빈 줄 보존, Markdown 기호 제거(단 `***`는 장면 전환 문자열로) | 빈 줄 두 배·장면 전환 빈 줄 소실이 실제로 보고된 1순위 사고다 | export(`paste`) |
| **웹 버전에서 가져오기**(ADR-0008) + txt 폴더 가져오기 | 1차 사용자의 원고가 지금 웹 앱과 파일에 있다 | new-project(first-run) |
| 폴더 → 시트, 순서 바꾸기, 휴지통·되돌리기, 찾기 | 이미 정한 Ulysses 수준의 기본 구조 | app-shell · trash · search |
| 집중 모드 · 타자기 스크롤 · 테마/글자 크기 | 율리시스를 다시 찾게 만든 이유 목록에 들어 있다 | app-shell · preferences |
| **안전한 서명·업데이트**: inside-out 서명, Sparkle 로드 확인, `/Applications` 이동 안내 | 업데이트가 앱을 깨뜨리면 매일 쓰기가 끝난다 | preferences(정보 · 업데이트) |

### P1 — 다음
| 기능 | 한 줄 근거 | 화면 |
|---|---|---|
| **플랫폼별 글자수 보기**(문피아 공백 포함·쪽수 / 노벨피아 기준 / 조아라 KB) + 목표 기준으로 선택 | 작가들이 플러그인·별도 프로그램으로 하는 일이고 경쟁 앱에 드물다 | app-shell(정보 탭) · project-settings |
| **연재 폴더 템플릿**: 회차 번호(자동, 프롤로그·외전 제외 가능), 상태(초고/퇴고/비축/예약/발행), 발행일·플랫폼 | PRODUCT [미정] 1의 답. 작가가 엑셀로 추적하는 핵심 열이다 | app-shell(시트 목록 · 정보 탭) · project-settings |
| **비축분 수 · 다음 연재일** 표시 | "비축 15화"가 연재 시작의 기준이고 매일 확인하는 숫자다 | app-shell(라이브러리/목록 머리) |
| 폴더 단위 통계(합계 분량, 회차 평균) | Ulysses 2026-05 통계 화면, 유료화 조건(총 75,000자 등) 확인 | app-shell(정보 탭) · 신규 |
| Claude(MCP) 읽기 전용 + 설정집 참조 | 핵심 차별점. 권한 기본은 읽기만(이미 결정) | preferences(Claude 연동) |
| 버전 기록·되돌리기 UI | 스크리브너 스냅숏에 해당. ADR-0002 chain 위에 | history |
| docx 내보내기, 폴더 전체 이어 붙여 내보내기 | 투고 원고가 HWP/DOCX | export(`file`) |
| 한국어 맞춤법 경로 조사 · 결정 | 경쟁 국내 툴 모두의 핵심 기능. 외부 서버 호출 여부는 ADR 판단 필요 | preferences(에디터) |

### P2 — 나중
| 기능 | 한 줄 근거 | 화면 |
|---|---|---|
| 설정 항목 자동 인식·등장 회차 목록(Novelcrafter codex식) | 설정 충돌 방지, Claude에게도 좋은 색인 | app-shell(참조 탭) · 신규 |
| 설정의 회차별 변화(progression) · 복선 추적(설치 → 회수 회차) | 장기 연재의 실제 고통이지만 데이터 모델이 커진다 | 신규 |
| 폴더 이어 보기(Scrivenings) | 퇴고에 유용하나 TextKit 2 큰 문서 성능 위험이 있다 | app-shell |
| 완결 예상일 · 연재 캘린더 | 목표 회차 ÷ 주당 연재 수 | 신규 |
| 동기화(iCloud/relay)와 기기 점유 | 이미 ADR-0003. Mac 하나로 매일 쓰는 데는 필요 없음 | pair-device · branch-resolve |
| epub, Ulysses·Scrivener 가져오기 | PRODUCT [미정] 3 | export · new-project |
| 바꾸기(replace) · 초성 검색 | v1에서 뺀 것(이미 결정) | search |

---

## 6. 구현 함정 — 엔지니어가 바로 할 일

1. **한글 조합 판별에 `hasMarkedText()`만 쓰지 않는다.** 2벌식은 `insertText(_:replacementRange:)`로 음절을 바꿔 쓴다는 보고가 있다. 텍스트 변경 처리(칠하기, 짝 닫기, 둥근 따옴표, 글자수)는 **입력이 멈춘 뒤** 또는 커서 문단 밖에서만 한다. 테스트: 새 bundle id(modeless)와 기존 bundle id(marked) 두 모드 모두에서 "한글" 입력·중간 삽입·Backspace·조합 중 Enter/Space/숫자(ADR-0004 체크리스트를 Mac에도 적용).
2. **`textStorage`를 직접 고칠 때는** `shouldChangeText(in:replacementString:)` → 편집 → `didChangeText()`로 감싸 undo에 남기고, 조합 중이면 미룬다. ⌘Z 한 번이 자모 하나를 지우면 버그다.
3. **`layoutManager`에 손대지 않는다.** TextKit 1으로 조용히 떨어진다. `willSwitchToNSLayoutManagerNotification`을 디버그 빌드에서 assert로 건다. NSTextTable도 쓰지 않는다.
4. **분량 계산은 Rust core 한 곳**(`unicode-segmentation`은 이미 의존성)에서, 정의를 `core/FORMAT.md` 또는 spec에 적는다: grapheme 단위, 줄바꿈은 공백 포함 수에서 제외할지, 연속 공백 처리. 문피아·노벨피아 규칙은 이 함수의 변형으로. fixture 원고로 한글(HWP)·문피아 숫자와 대조 테스트.
5. **hash chain 블록은 키 입력마다 만들지 않는다.** 입력 멈춤/시트 전환/앱 비활성/종료에서 debounce. 한글은 키마다 텍스트가 바뀌므로 블록 수가 폭증한다.
6. **줄바꿈**: 본문 paragraph style에 `lineBreakStrategy = [.hangulWordPriority, .pushOut]`(pushOut은 선택) + `lineBreakMode = .byWordWrapping`. 공백 없는 긴 문자열·URL·`………`에서 넘침이 없는지 TextKit 2에서 직접 확인.
7. **클립보드**: "플랫폼에 붙여넣기" 복사는 `NSPasteboard`에 **`.string`만** 쓴다(RTF/HTML 넣지 않기). 일반 ⌘C도 기본은 plain text가 안전하다. 붙여넣기는 들어오는 RTF/HTML을 plain text로 바꾸고 빈 줄을 보존.
8. **서명**: `--deep` 대신 안쪽부터 서명 — `Sparkle.framework/Versions/B/XPCServices/*.xpc` → `Autoupdate`·`Updater.app` → `Sparkle.framework` → `Ithaca.app`. ad-hoc을 유지하는 동안은 하드닝 런타임을 빼거나 `com.apple.security.cs.disable-library-validation` 엔타이틀먼트를 넣고, **배포 zip을 다른 사용자 계정에서 받아 실행해 Sparkle 로드·업데이트 1회를 실제로 확인**한다.
9. **고정 서명 ID 검토(ADR-0008 보완 후보)**: Apple 계정 없이도 키체인 "인증서 지원"으로 만든 자체 서명 코드 서명 인증서를 쓰면 DR이 빌드 간 같아져 키체인 프롬프트·TCC 초기화를 피할 수 있다(근거: TN3127의 DR 설명에서 추론, 직접 검증 필요). E2E 키를 키체인에 넣기 전에 결정할 것.
10. **배포 안내**: README/릴리스 노트에 "zip을 풀어 `/Applications`로 옮긴 뒤 실행 → 막히면 시스템 설정 › 개인정보 보호 및 보안 › 확인 없이 열기"를 적는다(Sequoia부터 Control-클릭 우회 없음). 앱이 translocation 경로(`/private/var/folders/.../AppTranslocation/`)에서 돌면 첫 실행에 옮기라고 알린다 — Sparkle은 그 경우 조용히 실패한다.
11. **`Bundle.module` 금지 또는 래핑**: 리소스 타깃이 생기면 `Bundle.main.resourceURL`에서 찾는 접근자를 직접 두고, CI/릴리스 전에 `.build`를 지운 상태로 `.app`을 실행해 본다.
12. **긴 문서 성능 예산**: 시트 하나(≤ 2만 자)는 문제없을 것으로 보이나, "폴더 이어 보기"·export 미리보기는 10만 자 이상이 된다. 1만 자/10만 자 fixture로 타이핑 지연·스크롤을 측정하는 스냅 테스트를 둔다(ADR-0004의 "1만 자 끊김" 항목을 Mac에도).

### ADR과의 관계
- 충돌하는 결정은 없다. PRODUCT 2026-10-08 제안(export 규칙 4개, 들여쓰기 기본 ✕, 빈 줄 기본 ○)은 조사 결과와 맞는다.
- **보완이 필요해 보이는 곳**: (a) ADR-0008 서명 — `--deep --options runtime` ad-hoc 조합은 Sparkle 문서 경고에 해당, 고정 서명 ID 검토(§6-8, 9). (b) PRODUCT "분량" — 플랫폼별 기준(P1)을 넣으려면 project-settings의 "기준" 선택지가 늘어난다. (c) PRODUCT [미정] 1 — 근거상 회차 번호·상태·발행일·플랫폼·비축분은 필요하다.
- 맞춤법을 외부 서비스(부산대 등)로 하려면 "서버 없이 동작" 원칙과 관련된 판단이 필요하므로 사람에게 묻는다.
