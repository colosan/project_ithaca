# ADR-0004 · UI 셸: Rust core + 네이티브 UI

- 상태: 확정 (2026-10-01)

## 맥락

검토한 선택지는 Tauri v2, Capacitor, Flutter, React Native, 네이티브였다.

이 프로젝트는 agent가 주도해서 개발한다. 그래서 UI를 두 번 작성하는 비용은 작고, 그만큼 **검증 비용**이 핵심 변수가 된다.

## 결정

- 로직은 전부 **Rust core**에 둔다. Swift와 Kotlin 바인딩은 UniFFI(MPL-2.0, 수정 없이 사용)로 자동 생성한다.
- **Apple**: SwiftUI 멀티플랫폼 타겟 하나로 iPhone, iPad, Mac을 모두 커버한다.
  - 에디터는 TextKit 2로 만든다.
  - iCloud는 Swift 네이티브 API로 붙인다.
  - MCP 토글은 macOS에만 둔다.
- **Android와 Windows**: Kotlin + Compose Multiplatform(Apache-2.0)으로 만든다. Windows 앱은 Compose Desktop으로 띄운다.
  - 번들하는 JVM은 OpenJDK(GPLv2 + Classpath Exception)이며, 배포해도 문제없다.
- `.xcodeproj` 대신 XcodeGen의 `project.yml`을 정본으로 둔다. `.xcodeproj`는 agent가 diff를 읽거나 수정하기 어려운 포맷이기 때문이다.

## 위험과 검증

- **Compose Desktop에서의 한글 IME.** 과거의 큰 버그(#2600 중복 입력, Android 삼성 키보드 문제)는 지금은 수정되어 있다. 하지만 Skia로 직접 그리는 구조라 회귀가 생기기 쉽다. 그래서 Windows 셸을 확정하기 전에 30분짜리 확인 spike를 한다. 확인 항목:
  - 조합 중 caret 위치
  - 문장 중간 입력
  - 조합 중 space, enter, 숫자 입력
  - 1만 자 분량에서 타이핑할 때 끊김이 없는지
- spike에 실패하면 Windows 셸은 WinUI 3로 대체한다.
- Swift 빌드는 Mac에서만 된다. 그래서 Apple 쪽 작업은 Mac에서 진행한다.
