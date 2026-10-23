# tools/mac — Mac 빌드 · 설치 · 릴리스 (ADR-0008)

Xcode 없이 Command Line Tools + Rust만으로 빌드한다.

| 스크립트 | 무엇 |
|---|---|
| `build.sh` | Rust core → UniFFI → SwiftPM → `dist/Ithaca.app` → 서명 |
| `embed-frameworks.sh` | (build.sh가 부른다) Sparkle.framework를 `Contents/Frameworks`에 `ditto`로 복사하고 안쪽부터 서명 |
| `install.sh` | `dist/Ithaca.app`을 `/Applications`에 설치. 실행 중이면 종료, 이전 버전은 `~/Library/Application Support/Ithaca-Release/previous/`에 보관 |
| `release.sh` | `patch\|minor\|major\|X.Y.Z [--dry-run]` — 버전 올리기 → 빌드 → zip → EdDSA 서명 → appcast → 커밋 · 태그 · 푸시 → GitHub Release |
| `make-signing-identity.sh` | 이 Mac에 고정 자체 서명 인증서 "Ithaca Local Signing"을 만든다 (한 번, 직접 실행) |
| `icon/make-icon.swift` | 앱 아이콘 PNG 세트 생성 (`swift/Apps/macOS/AppIcon.icns`의 원본) |

## 릴리스

```sh
tools/mac/release.sh patch --dry-run   # 먼저 확인: dist/release/<ver>/ 에 zip · appcast.xml · notes.md
tools/mac/release.sh patch             # 실제 릴리스 (작업 트리가 깨끗해야 한다)
```

- 버전: `VERSION` = `CFBundleShortVersionString`. 빌드 번호 = 릴리스 커밋의 커밋 수(Sparkle은 이 숫자로 비교한다).
- appcast의 정본은 `tools/mac/appcast.xml`(릴리스마다 새 항목을 맨 위에 더하고 이전 항목은 둔다). 매 릴리스에 전체 appcast를 함께 올리므로 앱이 보는 `releases/latest/download/appcast.xml`은 항상 최신이다.
- 릴리스 노트 = 이전 태그 이후 `git log` 제목.
- GitHub 인증: `gh auth status`가 실패하면 git credential helper의 github.com 토큰을 프로세스 환경변수(`GH_TOKEN`)로만 쓴다. 출력하거나 파일에 쓰지 않는다.
- `gh release`만 실패하면 태그는 이미 올라가 있다 — 스크립트가 출력하는 `gh release create …` 한 줄을 다시 실행한다.

## 키 (EdDSA, 업데이트 서명)

- 비밀키: 이 Mac의 **로그인 키체인**, account `ithaca` (`generate_keys --account ithaca`로 생성).
- 사람 없이 서명하려고 키체인에서 내보낸 사본을 둔다: `~/Library/Application Support/Ithaca-Release/sparkle_ed25519_private.key` (폴더 700, 파일 600). 키체인 항목은 `sign_update`가 읽으려 할 때 허용 대화상자를 띄워서 무인 실행이 멈춘다. `release.sh`는 이 파일이 있으면 `--ed-key-file`로 쓰고, 없으면 키체인을 쓴다.
- 공개키: `swift/Apps/macOS/Info.plist`의 `SUPublicEDKey`.
- **비밀키를 잃으면 이미 설치된 앱은 더 이상 업데이트를 받지 못한다.** 키체인 백업 또는 위 파일을 안전한 곳(암호 관리자)에 따로 보관한다. 저장소에는 절대 넣지 않는다.
- 다른 Mac에서 릴리스하려면: `generate_keys --account ithaca -f <파일>`로 가져온다.

도구 위치: `swift/.build/artifacts/sparkle/Sparkle/bin/` (`cd swift && swift package resolve --disable-keychain` 후).

## 앱 서명

| 상황 | 서명 | hardened runtime |
|---|---|---|
| 기본 | ad-hoc (`-`) | 끔 |
| `make-signing-identity.sh`를 실행한 Mac | "Ithaca Local Signing" (자체 서명) | 끔 |
| 나중에 Apple 개발자 계정 | `SIGN_IDENTITY="Developer ID Application: …"` + 공증 | 켬 (스크립트가 자동) |

- ad-hoc 서명은 빌드마다 바뀌어서 macOS가 업데이트마다 다른 앱으로 본다(개인정보 접근 허용 · 키체인 항목이 초기화될 수 있다). 고정 인증서로 서명하면 designated requirement가 같아서 이어진다. **이 Mac에서 한 번** 터미널로 `tools/mac/make-signing-identity.sh`를 실행하자 — 마지막 단계에서 로그인 키체인 암호를 묻는다. 성공하면 `~/Library/Application Support/Ithaca-Release/signing-identity` 표시 파일이 생기고, 그때부터 `build.sh`가 그 인증서로 서명한다. 표시 파일이 없으면 ad-hoc(무인 빌드가 키체인 대화상자에서 멈추지 않게).
- 서명은 안쪽부터: Sparkle의 XPC 서비스 → Autoupdate → Updater.app → Sparkle.framework → 앱. `--deep`으로 서명하지 않는다.
- Developer ID가 아닐 때 hardened runtime을 끄는 이유: hardened runtime은 library validation을 켜고, Team ID가 없는 서명(ad-hoc · 자체 서명)끼리는 프레임워크를 거부할 수 있다. 공증을 안 하면 hardened runtime은 필요 없다.
- SwiftPM은 `--disable-keychain`으로 부른다. 안 그러면 github.com 자격 증명을 키체인에서 찾다가 대화상자에서 멈춘다.

## 처음 설치할 때 (Gatekeeper)

공증되지 않은 앱이라 **다른 사람이 다운로드한 zip**은 처음 열 때 막힌다. macOS 15부터는 Control-클릭 → 열기로 우회되지 않는다:

1. `Ithaca.app`을 `/Applications`로 옮기고 한 번 연다 → 경고가 뜨면 닫는다.
2. 시스템 설정 → 개인정보 보호 및 보안 → 아래쪽 "Ithaca"의 **그래도 열기** → 암호 입력.
3. (또는 터미널: `xattr -dr com.apple.quarantine /Applications/Ithaca.app`)

이 Mac에서 직접 빌드해 `install.sh`로 설치한 앱은 격리 표시가 없어서 해당하지 않는다.

**그 다음 업데이트는 Sparkle이 처리한다.** Sparkle은 EdDSA 서명을 확인한 뒤 내려받은 앱의 격리 표시를 지우고 교체하므로 Gatekeeper 경고가 다시 뜨지 않는다. Sparkle 2.10은 앱 업데이트에서 EdDSA 서명이 맞으면 새 앱의 코드 서명이 "유효한지"만 보고, 이전 앱과 같은 인증서인지는 보지 않는다(`SUUpdateValidator.m`). 그래서 ad-hoc → 자체 서명 → Developer ID로 바꾸는 것도 업데이트로 넘어간다. 대신 **EdDSA 키는 절대 바꾸지 않는다**.
