// `Ithaca --selftest-editor`: drives the real ManuscriptView text view offscreen the way input methods do and
// checks the IME rules: composition is never disturbed by styling/autosave, modeless replace-style input works,
// autosave lands after the pause, and one ⌘Z undoes a word, not a jamo. In-memory library; nothing on disk.
import AppKit
import SwiftUI

@MainActor
enum EditorSelfTest {
    static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let lib = MockLibrary(seeded: false)
        let suite = "io.github.colosan.ithaca.editortest"
        UserDefaults().removePersistentDomain(forName: suite)
        let model = AppModel(library: lib, defaults: UserDefaults(suiteName: suite)!)
        model.createProject(title: "IME", language: .ko, folders: ["연재"], goal: nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ShellView().environment(model))
        window.makeKeyAndOrderFront(nil)
        pump(0.5)
        guard let tv = findTextView(window.contentView) else { fail("no text view") }
        window.makeFirstResponder(tv)
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ✓ " : "  ✗ ") + what); if !ok { failures.append(what) } }

        // 1. Marked-text composition (classic 2-set, three jamo steps), pausing longer than the style debounce each step.
        for (i, s) in ["ㅎ", "하", "한"].enumerated() {
            tv.setMarkedText(s, selectedRange: NSRange(location: (s as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            pump(0.3)
            check(tv.hasMarkedText() && tv.markedRange().length == 1 && tv.string == s, "composition step \(i + 1) intact after styling pause (\(tv.string))")
        }
        pump(2.0)  // longer than autosave: save must wait while composing
        check(tv.hasMarkedText(), "still composing after 2 s idle (autosave did not commit/replace)")
        tv.insertText("한", replacementRange: tv.markedRange())
        for s in ["ㄱ", "그", "글"] {
            tv.setMarkedText(s, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            pump(0.05)
        }
        tv.insertText("글", replacementRange: tv.markedRange())
        tv.insertText(" ", replacementRange: tv.selectedRange())
        check(tv.string == "한글 ", "marked composition result '\(tv.string)'")

        // 2. Modeless input sources rewrite the previous character instead of using marked text.
        let start = (tv.string as NSString).length
        tv.insertText("ㅇ", replacementRange: tv.selectedRange())
        for s in ["아", "안"] {
            pump(0.2)  // styling may run between keystrokes here; the replace must still hit the right character
            tv.insertText(s, replacementRange: NSRange(location: start, length: 1))
        }
        tv.insertText("녕", replacementRange: tv.selectedRange())
        check(tv.string == "한글 안녕", "modeless replace-style result '\(tv.string)'")

        // 3. Autosave after the idle pause.
        pump(2.0)
        let saved = (try? lib.sheetText(project: model.projectId!, sheet: model.sheetId!)) ?? ""
        check(saved == "한글 안녕" && model.saveStatus == .saved, "autosaved after idle ('\(saved)')")

        // 4. Undo granularity: one ⌘Z removes the last word, not one jamo/syllable.
        tv.undoManager?.undo()
        check(tv.string == "한글 ", "one undo removes the last word ('\(tv.string)')")

        // 5. Heading styling applied after typing settles, characters untouched.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("# 제목\n", replacementRange: NSRange(location: 0, length: 0))
        pump(0.4)
        let headingFont = tv.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        check((headingFont?.pointSize ?? 0) > 20, "heading line styled (\(headingFont?.pointSize ?? 0) pt)")
        check(tv.string.hasPrefix("# 제목\n"), "text unchanged by styling")

        print(failures.isEmpty ? "✓ editor self-test passed" : "✗ \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private static func findTextView(_ v: NSView?) -> ManuscriptTextView? {
        guard let v else { return nil }
        if let t = v as? ManuscriptTextView { return t }
        for s in v.subviews { if let t = findTextView(s) { return t } }
        return nil
    }

    private static func fail(_ m: String) -> Never { print("✗ \(m)"); exit(1) }
}
