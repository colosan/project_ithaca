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

        // 6. Sheet switch while composing: the composition is committed into the OLD sheet and saved there;
        //    the new sheet gets none of it.
        pump(2.0)
        let first = model.sheetId!
        let pid = model.projectId!
        let second = (try? lib.createSheet(project: pid, folder: model.folders[0].id, text: "둘째"))!.id
        model.reloadOutline()
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.setMarkedText("ㅁ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let withComposition = tv.string
        model.openSheet(second)
        pump(0.3)
        check(((try? lib.sheetText(project: pid, sheet: first)) ?? "") == withComposition, "composition committed into the old sheet on switch")
        check(tv.string == "둘째" && model.text == "둘째" && !model.dirty, "new sheet untouched by the old composition ('\(tv.string)')")

        // 7. A change tagged with the previous load token is ignored.
        model.textDidChange("옛 시트 글", token: model.loadToken - 1)
        check(model.text == "둘째" && !model.dirty, "stale-token edit ignored")

        // 8. Save failure: the switch back is refused, the typed text stays in the view and the model.
        var prompts = 0
        model.saveFailurePrompt = { _ in prompts += 1; return .cancel }
        model.debugSaveError = "simulated disk error"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText(" 저장 안 됨", replacementRange: tv.selectedRange())
        model.openSheet(first)
        pump(0.3)
        check(model.sheetId == second && tv.string == "둘째 저장 안 됨" && model.text == tv.string && model.dirty && prompts == 1,
              "switch refused on save failure, text kept ('\(tv.string)', prompts \(prompts))")
        if case .failed = model.saveStatus { check(true, "footer shows the failure") } else { check(false, "status \(model.saveStatus)") }
        // Backoff retry lands once the disk works again (first retry after 2 s).
        model.debugSaveError = nil
        pump(2.5)
        check(model.saveStatus == .saved && ((try? lib.sheetText(project: pid, sheet: second)) ?? "") == "둘째 저장 안 됨", "automatic retry saved it")
        model.saveFailurePrompt = nil

        // 9. Line endings: a sheet stored with CR/CRLF loads as \n (not dirty); a CR insert lands as \n and saves clean.
        let crlf = (try? lib.createSheet(project: pid, folder: model.folders[0].id, text: "가\r\n나\r다"))!.id
        model.reloadOutline()
        model.openSheet(crlf)
        pump(0.3)
        check(model.text == "가\n나\n다" && tv.string == model.text && !model.dirty && model.saveStatus == .saved, "CRLF sheet loads as \\n, not dirty")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("\r\n라\r마", replacementRange: tv.selectedRange())
        pump(0.1)
        check(!tv.string.contains("\r") && model.text == "가\n나\n다\n라\n마", "CR insert normalized ('\(model.text.debugDescription)')")
        model.flushSave()
        check(!model.dirty && model.saveStatus == .saved, "saved clean after CR insert")

        // 10. Formatting shortcuts: Markdown marks in and out, one undo step each; symbols and pairs.
        let fmt = (try? lib.createSheet(project: pid, folder: model.folders[0].id, text: "그는 웃었다\n둘째 줄"))!.id
        model.reloadOutline()
        model.openSheet(fmt)
        pump(0.3)
        guard let ed = model.editor else { fail("no editor bridge") }
        tv.setSelectedRange(NSRange(location: 3, length: 3))
        ed.format(.bold)
        check(tv.string.hasPrefix("그는 **웃었다**") && tv.selectedRange() == NSRange(location: 5, length: 3), "⌘B wraps the selection ('\(tv.string.prefix(12))')")
        pump(0.3)
        let boldFont = tv.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        check(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true || (boldFont?.fontName.contains("Bold") ?? false), "bold text drawn bold (\(boldFont?.fontName ?? "-"))")
        ed.format(.bold)
        check(tv.string.hasPrefix("그는 웃었다\n"), "⌘B again unwraps")
        tv.undoManager?.undo()
        check(tv.string.hasPrefix("그는 **웃었다**"), "one undo restores the marks")
        tv.undoManager?.undo()
        check(tv.string.hasPrefix("그는 웃었다\n"), "second undo removes them")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        ed.format(.heading(2))
        check(tv.string.hasPrefix("## 그는 웃었다\n"), "⌥⌘2 makes a heading")
        ed.format(.heading(1))
        check(tv.string.hasPrefix("# 그는 웃었다\n"), "⌥⌘1 changes the level")
        ed.format(.heading(1))
        check(tv.string.hasPrefix("그는 웃었다\n"), "same level again → body")
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        ed.format(.quote)
        check(tv.string == "> 그는 웃었다\n> 둘째 줄", "quote every selected line ('\(tv.string)')")
        ed.format(.quote)
        check(tv.string == "그는 웃었다\n둘째 줄", "quote again removes it")
        tv.setSelectedRange(NSRange(location: 3, length: 3))
        ed.insert("「", wrapping: "」")
        check(tv.string.hasPrefix("그는 「웃었다」"), "pair wraps the selection")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        ed.insert("…", wrapping: nil)
        check(tv.string.hasSuffix("둘째 줄…") && tv.selectedRange().location == (tv.string as NSString).length, "symbol at the caret")
        ed.format(.sceneBreak)
        check(tv.string.hasSuffix("둘째 줄…\n\n* * *\n\n"), "scene break on its own line")
        pump(0.1)
        check(model.text == tv.string && model.dirty, "formatting reaches the model for autosave")

        // 11. A click on the empty page below a short text puts the caret at the end (not ignored).
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        if let scroll = tv.enclosingScrollView {
            let below = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.maxY - 20), to: nil)
            func mouse(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: below, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
            scroll.mouseDown(with: mouse(.leftMouseDown))
            check(tv.selectedRange().location == (tv.string as NSString).length, "click below the text moves the caret to the end (\(tv.selectedRange().location))")
        }

        // 12. ⌘C / ⌘X / ⌘V through the text view (the writer's clipboard is put back afterwards).
        let pb = NSPasteboard.general
        let clip = pb.pasteboardItems?.map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } } ?? []
        tv.setSelectedRange(NSRange(location: 0, length: 2))
        let picked = (tv.string as NSString).substring(with: tv.selectedRange())
        tv.copy(nil)
        check(pb.string(forType: .string) == picked, "⌘C puts the selection on the clipboard ('\(pb.string(forType: .string) ?? "nil")')")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.paste(nil)
        check(tv.string.hasSuffix(picked), "⌘V pastes it")
        pump(0.1)  // separate undo groups: one per event, like real key presses
        let before = tv.string
        tv.setSelectedRange(NSRange(location: 0, length: 2))
        tv.cut(nil)
        check(pb.string(forType: .string) == picked && tv.string == String(before.dropFirst(2)), "⌘X moves the selection to the clipboard")
        tv.undoManager?.undo()
        check(tv.string == before, "undo brings the cut text back")
        pb.clearContents()
        pb.writeObjects(clip.map { pairs in let i = NSPasteboardItem(); pairs.forEach { i.setData($0.1, forType: $0.0) }; return i })

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
