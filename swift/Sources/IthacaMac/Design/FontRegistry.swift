// Pretendard (OFL-1.1) ships inside Ithaca.app/Contents/Resources/Fonts (tools/mac/build.sh) and is registered for this
// process at launch, so the UI and the editor draw with the token family on every Mac — the same face as the workbench
// and the snapshots (DESIGN.md). Without the bundle (swift run) Fonts.ns falls back to the system font.
import CoreText
import Foundation

enum FontRegistry {
    static let faces = ["Pretendard-Regular", "Pretendard-Medium", "Pretendard-SemiBold", "Pretendard-Bold"]

    static func registerBundledFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true) else { return }
        for face in faces {
            let url = dir.appendingPathComponent(face + ".otf")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered (installed system-wide too) is fine; anything else falls back to the system font.
                _ = error?.takeRetainedValue()
            }
        }
    }
}
