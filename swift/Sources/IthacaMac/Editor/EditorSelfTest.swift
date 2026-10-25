// `Ithaca --selftest-editor`: drives the real ManuscriptView text view offscreen the way input methods do and
// checks the IME rules: composition is never disturbed by styling/autosave, modeless replace-style input works,
// autosave lands after the pause, and one ⌘Z undoes a word, not a jamo. In-memory library; nothing on disk.
import AppKit
import IthacaDesign
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
        // 13. Select all; rich text on the clipboard pastes as plain text in the manuscript's own style.
        tv.selectAll(nil)
        check(tv.selectedRange() == NSRange(location: 0, length: (tv.string as NSString).length), "⌘A selects the whole sheet")
        let rich = NSAttributedString(string: "리치\r\n텍스트", attributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.red])
        let rtfData = try! rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pb.clearContents()
        pb.setData(rtfData, forType: .rtf)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.paste(nil)
        let pastedFont = tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        check(tv.string.hasPrefix("리치\n텍스트") && pastedFont?.pointSize == (Styles.base(model.textSize)[.font] as? NSFont)?.pointSize,
              "RTF-only clipboard pastes as plain text, \\n, body font (\(pastedFont?.pointSize ?? 0) pt)")

        // 14. Drag and drop: text drops are normalized; non-text drags (colors, fonts) aren't accepted.
        let dpb = NSPasteboard(name: NSPasteboard.Name("io.github.colosan.ithaca.selftest.drag"))
        dpb.clearContents()
        dpb.setString("드롭\r\n글", forType: .string)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        check(tv.readSelection(from: dpb, type: .string) && tv.string.hasPrefix("드롭\n글"), "dropped text lands with \\n line endings")
        let drag = Set(tv.acceptableDragTypes.map(\.rawValue))
        check(drag.contains(NSPasteboard.PasteboardType.string.rawValue) || drag.contains("NSStringPboardType"), "text drags accepted")
        check(!drag.contains(NSPasteboard.PasteboardType.color.rawValue) && !drag.contains(NSPasteboard.PasteboardType.font.rawValue), "color / font drags refused")
        // Dragging a selection out writes its text (the TextKit 2 empty-clipboard trap, drag side).
        tv.setSelectedRange(NSRange(location: 0, length: 2))
        dpb.clearContents()
        check(tv.writeSelection(to: dpb, types: tv.writablePasteboardTypes) && dpb.string(forType: .string) == "드롭", "dragging a selection out carries its text")
        dpb.releaseGlobally()

        // 15. Double-click selects a Korean word (eojeol); Services see the selection.
        check(tv.selectionRange(forProposedRange: NSRange(location: 1, length: 0), granularity: .selectByWord) == NSRange(location: 0, length: 2),
              "double-click selects '드롭'")
        tv.setSelectedRange(NSRange(location: 0, length: 2))
        let legacy = NSPasteboard.PasteboardType("NSStringPboardType")
        check(tv.validRequestor(forSendType: legacy, returnType: legacy) != nil, "Services can take and replace the selection")

        // 16. Context menu: cut/copy/paste/look up stay; Font and Layout Orientation (vertical text) are gone.
        let right = NSEvent.mouseEvent(with: .rightMouseDown, location: tv.convert(NSPoint(x: tv.textContainerInset.width + 4, y: tv.textContainerInset.height + 4), to: nil),
                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menuActions = (tv.menu(for: right)?.items ?? []).flatMap { [$0] + ($0.submenu?.items ?? []) }.compactMap { $0.action.map(NSStringFromSelector) }
        check(["cut:", "copy:", "paste:"].allSatisfy(menuActions.contains), "context menu has cut / copy / paste")
        check(!menuActions.contains("orderFrontFontPanel:") && !menuActions.contains("changeLayoutOrientation:"), "context menu has no Font / Layout Orientation")

        // 17. Read-only (locked) view: cut / paste / delete change nothing, copy still works.
        tv.isEditable = false
        let locked = tv.string
        tv.setSelectedRange(NSRange(location: 0, length: 2))
        tv.cut(nil); tv.paste(nil); tv.delete(nil)
        check(tv.string == locked, "read-only: cut / paste / delete leave the text alone")
        tv.copy(nil)
        check(pb.string(forType: .string) == "드롭", "read-only: copy still works")
        tv.isEditable = true

        // 18. Cut with a multi-range selection removes every range, one undo step.
        let multi = (try? lib.createSheet(project: pid, folder: model.folders[0].id, text: "가나다라마바"))!.id
        model.reloadOutline()
        model.openSheet(multi)
        pump(0.3)
        tv.selectedRanges = [NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 3, length: 1))]
        tv.cut(nil)
        check(tv.string == "나다마바" && pb.string(forType: .string) == "가\n라", "multi-range cut ('\(tv.string)')")
        tv.undoManager?.undo()
        check(tv.string == "가나다라마바", "one undo restores a multi-range cut")

        // 19. Preferences apply live: text size, line spacing, markup modes, typewriter room below the last line.
        let prefs = (try? lib.createSheet(project: pid, folder: model.folders[0].id, text: "- 대사 한 줄\n**본문**"))!.id
        model.reloadOutline()
        model.openSheet(prefs)
        pump(0.3)
        func fontSize(at i: Int) -> CGFloat { (tv.textStorage?.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
        // Dynamic token colors are compared as resolved for the view's appearance.
        func resolved(_ c: NSColor?) -> [CGFloat] {
            var out: [CGFloat] = []
            tv.effectiveAppearance.performAsCurrentDrawingAppearance {
                if let s = c?.usingColorSpace(.sRGB) { out = [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent].map { ($0 * 255).rounded() } }
            }
            return out
        }
        func color(at i: Int) -> [CGFloat] { resolved(tv.textStorage?.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor) }
        let normal = fontSize(at: 3)
        model.textSize = .large
        pump(0.2)
        check(fontSize(at: 3) > normal && (tv.typingAttributes[.font] as? NSFont)?.pointSize == fontSize(at: 3), "text size applies live (\(normal) → \(fontSize(at: 3)) pt)")
        model.textSize = .normal
        pump(0.2)
        let lh = (tv.textStorage?.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? 0
        model.lineSpacing = .wide
        pump(0.2)
        let lh2 = (tv.textStorage?.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? 0
        check(lh2 > lh, "line spacing applies live (\(lh) → \(lh2))")
        model.lineSpacing = .normal
        pump(0.2)
        check(color(at: 0) == resolved(.token(T.Color.inkMarkup)) && color(at: 2) == resolved(.token(T.Color.inkPrimary)), "dim: line-start '-' drawn in ink.markup, text in ink.primary")
        model.markup = .hide
        pump(0.2)
        check(color(at: 9).last == 0, "hide: emphasis marks hidden live")
        check(color(at: 0) == resolved(.token(T.Color.inkMarkup)), "hide: line-start '-' (dialogue dash) stays visible")
        // Home / End / Page keys move the caret (⇧ extends), not just the view.
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(.function), timestamp: 0,
                                     windowNumber: tv.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: code)!
            tv.keyDown(with: e)
        }
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        key(119)
        check(tv.selectedRange() == NSRange(location: 8, length: 0), "End moves the caret to the line end (\(tv.selectedRange()))")
        key(115, .shift)
        check(tv.selectedRange() == NSRange(location: 0, length: 8), "⇧Home selects to the line start (\(tv.selectedRange()))")
        key(115)
        check(tv.selectedRange() == NSRange(location: 0, length: 0), "Home moves the caret to the line start")
        model.markup = .show
        pump(0.2)
        check(color(at: 0) == resolved(.token(T.Color.inkSecondary)), "show: marks in ink.secondary")
        model.markup = .dim
        let scroll = tv.enclosingScrollView!
        model.typewriter = true
        pump(0.2)
        check(abs(scroll.contentInsets.bottom - (scroll.contentSize.height * 0.5).rounded()) < 1, "typewriter room below the last line applies live (\(scroll.contentInsets.bottom))")
        model.typewriter = false
        pump(0.2)
        check(abs(scroll.contentInsets.bottom - (scroll.contentSize.height * 0.4).rounded()) < 1, "and goes back when it's off")

        // 20. Typing at the bottom of a long sheet keeps the caret in view, blank last lines included.
        let long = (try? lib.createSheet(project: pid, folder: model.folders[0].id, text: (1...200).map { "줄 \($0) 가나다라마바사" }.joined(separator: "\n")))!.id
        model.reloadOutline()
        model.openSheet(long)
        pump(0.4)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        pump(0.1)
        func caretVisible() -> Bool {
            let r = tv.convert(window.convertFromScreen(tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)), from: nil)
            return scroll.documentVisibleRect.contains(NSPoint(x: scroll.documentVisibleRect.midX, y: r.maxY))
        }
        for i in 0..<20 { tv.insertText(i == 10 ? "끝" : "\n", replacementRange: tv.selectedRange()); pump(0.02) }
        pump(0.1)
        check(caretVisible(), "caret stays in view while typing new lines at the bottom")
        pump(0.5)
        check(model.liveCounts.chars == TextMetrics.counts(tv.string).chars && model.saveStatus == .pending, "footer counts follow the typing (\(model.liveCounts.chars)), status 저장 중")

        // 21. Focus mode dims everything but the caret's paragraph, and clears when it ends.
        func dimRuns() -> Int {
            var n = 0
            tv.textLayoutManager!.enumerateRenderingAttributes(from: tv.textLayoutManager!.documentRange.location, reverse: false) { _, a, _ in
                if a[.foregroundColor] != nil { n += 1 }
                return true
            }
            return n
        }
        model.focusMode = true
        pump(0.2)
        check(dimRuns() > 0, "focus mode dims the other paragraphs")
        tv.cancelOperation(nil)
        check(!model.focusMode, "Esc leaves focus mode")
        model.toggleEditorOnly()
        check(model.panesHidden && !model.focusMode, "⌘3 hides the side panes without focus mode")
        tv.cancelOperation(nil)
        check(!model.panesHidden, "Esc shows the side panes again")
        pump(0.2)
        check(dimRuns() == 0, "dimming cleared when focus mode ends")

        // 22. ⌘F shows the find bar above the manuscript; the replace field is available on an editable sheet.
        ed.showFindBar()
        pump(0.2)
        check(scroll.isFindBarVisible, "⌘F shows the find bar")
        let replaceItem = NSMenuItem(title: "", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "")
        replaceItem.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        check(tv.validateMenuItem(replaceItem), "find and replace available")
        let hide = NSMenuItem()
        hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
        tv.performTextFinderAction(hide)
        pump(0.2)
        check(!scroll.isFindBarVisible, "the find bar closes")
        model.flushSave()

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
