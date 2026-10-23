# ADR-0008 · Mac 버전 먼저: 빌드, 업데이트, 데이터 이전

- 상태: 확정 (2026-10-24)
- 관련: [0001](0001-name-and-repository-structure.md), [0002](0002-sheet-integrity-and-lease.md), [0004](0004-ui-shells.md), [0006](0006-design-first.md)(부분 해제), [0007](0007-web-app-for-daily-use.md)

## 맥락

1차 사용자가 Mac에서 매일 쓰면서 개발을 이어가기로 했다. 그러려면 브라우저가 아니라 진짜 앱이 필요하다. 원고는 파일로 남아야 하고, 업데이트를 받아도 데이터가 이어져야 한다.

ADR-0004의 구조(Rust core + SwiftUI)를 그대로 지금 시작한다.

## 결정

1. **ADR-0006 동결을 Mac에 한해 푼다.**
   - `core/`와 `swift/`(macOS)를 지금 구현한다.
   - 디자인은 계속 `design/`이 정본이다. 네이티브는 spec을 따르고, 새로 발견한 것은 spec과 PRODUCT.md에 되돌려 적는다.
   - iOS, iPadOS, Android, Windows는 그대로 동결한다.
2. **빌드에 Xcode를 쓰지 않는다.**
   - SwiftPM(`swift/Package.swift`)과 `tools/mac/build.sh`로 빌드한다. Command Line Tools만 있으면 된다.
   - 순서: Rust staticlib → UniFFI Swift 바인딩(생성물, 체크인하지 않음) → `swift build` → `.app` 번들 → ad-hoc 서명.
   - ADR-0004의 XcodeGen `project.yml`은 iOS를 시작할 때 다시 판단한다.
3. **업데이트는 Sparkle 2(MIT)와 GitHub Releases로 한다.**
   - 앱은 `https://github.com/colosan/project_ithaca/releases/latest/download/appcast.xml`을 확인한다.
   - 업데이트 파일은 EdDSA로 서명한다. 비밀키는 이 Mac의 키체인에만 두고, 공개키는 Info.plist에 넣는다.
   - 릴리스는 `tools/mac/release.sh` 하나로 한다: 버전 올리기 → 빌드 → zip → 서명 → appcast 갱신 → `gh release`.
   - 지금 앱 서명은 ad-hoc이다. Apple 개발자 계정이 생기면 Developer ID 서명과 공증(notarization)으로 바꾼다. 이 부분만 바꾸면 된다.
   - 버전: `VERSION`(semver)이 곧 `CFBundleShortVersionString`이다. 빌드 번호는 커밋 수다.
4. **데이터는 "라이브러리 폴더"에 파일로 저장한다.**
   - 기본 위치는 `~/Library/Application Support/Ithaca/Library/`다. 위치를 바꾸는 기능은 나중에 넣는다(iCloud 폴더 transport, ADR-0003).
   - 형식은 ADR-0002를 따른다. sheet마다 hash chain을 두고, 블록은 이름이 hash인 불변 파일이다. 목차(폴더, 순서, 휴지통)도 하나의 chain이다. 자세한 형식은 `core/FORMAT.md`에 둔다.
   - `library.json`의 `format` 번호가 데이터 형식의 버전이다.
5. **데이터 이전(migration) 규칙**
   - core는 라이브러리를 열 때 `format`을 확인한다. 낮으면 순서대로 마이그레이션한다.
   - 마이그레이션하기 **전에** 라이브러리 전체를 `Backups/pre-migration-<from>-<to>-<날짜>/`에 복사한다.
   - 앱보다 **높은** format이면(새 버전으로 쓰다가 옛 버전을 연 경우) 읽기 전용으로 열고 업데이트하라고 안내한다. 절대 쓰지 않는다.
   - 마이그레이션마다 이전 format의 고정 샘플(fixture)로 테스트한다. `cargo test`가 통과해야 릴리스한다.
   - 웹 버전(ADR-0007)의 백업 JSON은 앱의 "웹 버전에서 가져오기"로 들여온다. 가져온 원고는 새 작품으로 추가하고, 아무것도 덮어쓰지 않는다.
6. **기기 id는 설치마다 하나다.** 앱의 설정(UserDefaults)에 두고, 라이브러리를 열 때 core에 넘긴다.

## 결과

- 새 의존성은 모두 허용 라이선스다.
  - 링크되는 것: UniFFI(MPL-2.0, 수정 없이 사용), Sparkle(MIT), serde · serde_json(MIT/Apache-2.0), blake3(CC0/Apache-2.0), similar(Apache-2.0), unicode-segmentation(MIT/Apache-2.0).
  - 빌드 도구로만 쓰는 것: Rust 툴체인(rustup, Homebrew).
- 서명이 ad-hoc이라 처음 열 때 Gatekeeper 경고가 뜰 수 있다. 직접 빌드해서 설치한 경우에는 해당하지 않는다.
- 빌드 기계가 Apple Silicon이라 지금은 arm64 전용 빌드다. 유니버설 빌드는 필요할 때 만든다.
