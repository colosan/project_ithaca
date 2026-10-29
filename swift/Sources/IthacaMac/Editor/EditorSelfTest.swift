// `Ithaca --selftest-editor`: drives the real ManuscriptView text view offscreen the way input methods do and
// checks the IME rules: composition is never disturbed by styling/autosave, modeless replace-style input works,
// autosave lands after the pause, and one ⌘Z undoes a word, not a jamo. In-memory library; nothing on disk.
import AppKit
import IthacaCore
import IthacaDesign
import SwiftUI

@MainActor
enum EditorSelfTest {
    static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Headless.enable()
        Wait.scale = 0.25  // the same pauses, a quarter as long (pump shortens its long waits to match)
        let lib = MockLibrary(seeded: false)
        let suite = "io.github.colosan.ithaca.editortest"
        UserDefaults().removePersistentDomain(forName: suite)
        let model = AppModel(library: lib, defaults: UserDefaults(suiteName: suite)!)
        model.createProject(title: "IME", language: .ko, folders: ["연재"], goal: nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        Headless.hide(window)  // invisible and click-through: tests must not cover the owner's screen
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
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        ed.format(.italic)
        check(tv.string == "*그는 웃었다*\n*둘째 줄*", "⌘I over two lines wraps each line ('\(tv.string)')")
        pump(0.3)
        let ob = tv.textStorage?.attribute(.obliqueness, at: 10, effectiveRange: nil) as? Double
        check((ob ?? 0) > 0, "second line drawn slanted")
        ed.format(.italic)
        check(tv.string == "그는 웃었다\n둘째 줄", "⌘I again unwraps every line")
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

        // 11b. The toast over the editor takes its own clicks ([Undo] · ✕), not the text view underneath.
        model.showToast(Toast(message: "Toast", sticky: true))
        pump(0.3)
        let onToast = NSPoint(x: window.frame.width - T.Space.s200 - 20, y: window.contentLayoutRect.maxY - T.Size.barTop - T.Space.s100 - 18)
        check(!(window.contentView?.superview?.hitTest(onToast) is NSTextView), "a click on the toast reaches the toast")
        model.toast = nil

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
        pump(0.2)  // before the (shortened) autosave
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

        // 23. Editor conveniences (story-bible spec §7): pairs, ellipsis, first-line indent, text replacement, symbol list.
        let conv = (try? lib.createSheet(project: pid, folder: model.folders[0].id, text: ""))!.id
        model.reloadOutline()
        model.openSheet(conv)
        pump(0.3)
        /// Committed input at the caret, one key press per event (like the keyboard after composition).
        func type(_ s: String) { tv.insertText(s, replacementRange: tv.selectedRange()); pump(0.05) }
        func undo() { tv.undoManager?.undo(); pump(0.05) }
        func setText(_ s: String, caret: Int? = nil) {
            tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
            tv.rawInsert(s, replacementRange: tv.selectedRange())
            tv.setSelectedRange(NSRange(location: caret ?? (s as NSString).length, length: 0))
            pump(0.05)
            tv.undoManager?.removeAllActions()
            tv.conveniences.reset()
        }
        // 22b. A space typed in front of a long run without spaces stays on its line: the run is not one word to wrap whole.
        func lineY(_ i: Int) -> CGFloat { tv.firstRect(forCharacterRange: NSRange(location: i, length: 1), actualRange: nil).minY }
        let run = String(repeating: "가나다라마바사아자차카타파하", count: 5)
        setText(run + "\n둘째 줄", caret: 0)
        type(" ")
        pump(0.2)
        check(lineY(1) == lineY(0) && lineY(run.count) != lineY(0), "space before a long unspaced run doesn't push it to the next line")
        let spaced = "서윤은 오늘도 불빛의 횟수를 셌다. 엘리엇의 지도에는 섬이 하나 더 있었다. 서윤은 그 점을 오래 바라보았다. 바다는 조용했고 등대는 꺼지지 않았다."
        setText(spaced)
        pump(0.2)
        let words = spaced.indices.map { spaced.distance(from: spaced.startIndex, to: $0) }.filter { $0 > 0 && Array(spaced)[$0 - 1] != " " && Array(spaced)[$0] != " " }
        check(words.allSatisfy { lineY($0) == lineY($0 - 1) }, "spaced prose still wraps between words")
        setText("")
        check(!model.autoPairs && model.ellipsis == .off && !model.firstLineIndent && !model.textReplacement, "conveniences are off by default")
        for s in ["(", "「", ".", ".", "."] { type(s) }
        check(tv.string == "(「...", "off: no closing pair, no ellipsis ('\(tv.string)')")

        model.autoPairs = true
        pump(0.2)
        setText("")
        type("「")
        check(tv.string == "「」" && tv.selectedRange() == NSRange(location: 1, length: 0), "pairs: 「 adds 」 with the caret between ('\(tv.string)')")
        type("안")
        type("」")
        check(tv.string == "「안」" && tv.selectedRange().location == 3, "pairs: typing 」 steps over the one put there ('\(tv.string)', \(tv.selectedRange().location))")
        type("」")
        check(tv.string == "「안」」", "pairs: a second 」 is just typed")
        // A syllable composed inside the pair (marked text) is left alone; the closer still steps over afterwards.
        setText("")
        type("「")
        for s in ["ㅎ", "하", "한"] {
            tv.setMarkedText(s, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            pump(0.05)
        }
        check(tv.string == "「한」" && tv.hasMarkedText(), "pairs: composition inside the pair intact ('\(tv.string)')")
        tv.insertText("한", replacementRange: tv.markedRange())
        type("」")
        check(tv.string == "「한」" && tv.selectedRange().location == 3, "pairs: closer steps over after the composed syllable ('\(tv.string)')")
        setText("")
        type("(")
        undo()
        check(tv.string == "(", "pairs: one undo takes back only the closer ('\(tv.string)')")
        undo()
        check(tv.string == "", "pairs: the next undo takes the typed opener")
        setText("")
        type("(")
        tv.deleteBackward(nil)
        pump(0.05)
        check(tv.string == "", "pairs: backspace in an empty pair deletes both ('\(tv.string)')")
        undo()
        check(tv.string == ")", "pairs: undo after that brings back the closer first ('\(tv.string)')")
        setText("웃었다", caret: 0)
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        type("『")
        check(tv.string == "『웃었다』" && tv.selectedRange() == NSRange(location: 1, length: 3), "pairs: an opener wraps the selection ('\(tv.string)')")
        undo()
        check(tv.string == "웃었다", "pairs: one undo unwraps it")
        setText("말", caret: 0)
        type("(")
        check(tv.string == "(말", "pairs: no closer in front of a word ('\(tv.string)')")
        setText("가")
        type("\"")
        check(tv.string == "가\"", "pairs: a straight quote after a letter is a closing quote ('\(tv.string)')")
        setText("")
        tv.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText("(", replacementRange: tv.markedRange())
        pump(0.05)
        check(tv.string == "(" && !tv.hasMarkedText(), "pairs: nothing added to input that ends a composition ('\(tv.string)')")
        setText("")
        tv.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(tv.string.hasPrefix("하") || tv.string == "(", "pairs: input while composing is left to the input method ('\(tv.string)')")
        tv.unmarkText()
        pump(0.05)

        model.ellipsis = .single
        pump(0.2)
        setText("그런")
        for _ in 0..<3 { type(".") }
        check(tv.string == "그런…" && tv.selectedRange().location == 3, "ellipsis: ... becomes … ('\(tv.string)')")
        undo()
        check(tv.string == "그런...", "ellipsis: one undo gives back the three dots ('\(tv.string)')")
        model.ellipsis = .double
        pump(0.2)
        setText("")
        for _ in 0..<3 { type(".") }
        check(tv.string == "……", "ellipsis: or …… when chosen ('\(tv.string)')")
        setText("..")
        tv.setMarkedText(".", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.insertText(".", replacementRange: tv.markedRange())
        pump(0.05)
        check(tv.string == "...", "ellipsis: not while composing ('\(tv.string)')")
        model.ellipsis = .off
        model.autoPairs = false
        pump(0.2)
        setText("")
        type("(")
        check(tv.string == "(", "pairs off again: just the typed character")

        // First-line indent: drawing only (paragraph style), not on headings, scene breaks or the front matter.
        let indented = "---\n종류: 인물\n---\n# 제목\n본문 첫 줄\n* * *\n둘째 문단"
        setText(indented)
        func headIndent(_ needle: String) -> CGFloat {
            let at = (tv.string as NSString).range(of: needle).location
            return (tv.textStorage?.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? -1
        }
        pump(0.3)
        check(headIndent("본문") == 0, "indent off: body flush")
        model.firstLineIndent = true
        pump(0.3)
        check(headIndent("본문") > 0 && headIndent("둘째") > 0, "indent on: body paragraphs indented (\(headIndent("본문")))")
        check(headIndent("제목") == 0 && headIndent("* * *") == 0 && headIndent("종류") == 0, "indent on: heading, scene break and front matter stay flush")
        check(tv.string == indented, "indent on: the text itself is unchanged")
        model.firstLineIndent = false
        pump(0.3)
        check(headIndent("본문") == 0, "indent off again")

        // System text replacement follows the preference.
        check(!tv.isAutomaticTextReplacementEnabled, "text replacement off by default")
        model.textReplacement = true
        pump(0.2)
        check(tv.isAutomaticTextReplacementEnabled, "text replacement on")
        model.textReplacement = false
        pump(0.2)
        check(!tv.isAutomaticTextReplacementEnabled, "text replacement off again")

        // The symbol list's order is the ⌘/ menu's (and Format › Symbols'); it persists only while customized.
        guard let coord = model.editor as? ManuscriptView.Coordinator else { fail("no coordinator") }
        check(coord.symbolMenu().items.first?.title.hasPrefix("…") == true, "default symbol menu starts with …")
        model.symbols = [Symbols.defaults[5], Symbols.defaults[0], Symbols.make("◎", close: nil), Symbols.make("〔", close: "〕")]
        let symMenu = coord.symbolMenu()
        check(symMenu.items.map { $0.title.components(separatedBy: "    ")[0] } == ["―", "…", "◎", "〔〕"] && symMenu.items.map(\.keyEquivalent) == ["1", "2", "3", "4"],
              "symbol menu follows the list order (\(symMenu.items.map(\.title)))")
        check(model.menu.symbols == model.symbols && (model.defaults.array(forKey: "ithaca.symbols") as? [[String]])?.count == 4, "the list reaches the menu bar and is stored")
        setText("")
        symMenu.performActionForItem(at: 3)
        check(tv.string == "〔〕" && tv.selectedRange().location == 1, "a custom pair from the menu leaves the caret inside ('\(tv.string)')")
        check(Symbols.decode(model.defaults.array(forKey: "ithaca.symbols")) == model.symbols, "the stored list reads back the same (names kept)")
        model.symbols = Symbols.defaults
        check(model.defaults.object(forKey: "ithaca.symbols") == nil && coord.symbolMenu().items.count == Symbols.defaults.count + 1, "reset: defaults again (24 + separator)")
        model.flushSave()

        // 24. Story bible entries (story-bible spec §1): new entries, an entry from the selection, add field, rendering.
        model.createFolder("자료")
        model.createFolder("설정")
        let serialId = model.folders[0].id
        guard let loreId = model.folders.first(where: { $0.name == "설정" })?.id else { fail("no lore folder") }
        check(model.loreFolder?.id == loreId, "lore folder: the one named 설정, not the second folder")
        let fa = FolderInfo(id: "a", name: "연재", order: 0, sheets: []), fb = FolderInfo(id: "b", name: "자료", order: 1, sheets: [])
        let fl = FolderInfo(id: "d", name: "Lore", order: 2, sheets: [])
        check(StoryBible.loreFolder([fa, fb], current: "a")?.id == "b" && StoryBible.loreFolder([fa], current: "a")?.id == "a"
              && StoryBible.loreFolder([fa, fb, fl], current: "a")?.id == "d", "lore folder rule: 설정/Lore, else the second, else the current")
        var made: [EntryKind: String] = [:]
        for kind in EntryKind.all {
            model.newEntry(kind, in: loreId)
            pump(0.3)
            let parsed = IthacaCore.parseEntry(text: tv.string)
            let ns = tv.string as NSString
            let caretLine = ns.substring(with: ns.lineRange(for: NSRange(location: tv.selectedRange().location, length: 0)))
            check(parsed?.kind == kind && parsed?.name == "" && model.sheet?.folder == loreId && model.sheet?.entry == kind,
                  "new \(kind): a parseable entry in the current folder (\(parsed.map { "\($0.kind)" } ?? "nil"))")
            check(caretLine == "# \n" && tv.selectedRange().location == StoryBible.nameCaret(tv.string), "new \(kind): caret on the empty name line")
            made[kind] = model.sheetId
        }
        // Make from the selection: the entry lands in the lore folder, the editor stays on the prose.
        let prose = (try? lib.createSheet(project: pid, folder: serialId, text: "서윤은 등대 계단을 올랐다."))!.id
        model.reloadOutline()
        model.openSheet(prose)
        pump(0.3)
        tv.setSelectedRange(NSRange(location: 0, length: 2))
        check(AppCommand.entryCharacter.available(model) && !AppCommand.addField.available(model), "palette: make-from-selection on, add field off in prose")
        let fromSel = model.makeEntryFromSelection(.character)
        pump(0.2)
        let madeText = fromSel.flatMap { try? lib.sheetText(project: pid, sheet: $0) } ?? ""
        check(model.sheetId == prose && tv.string == "서윤은 등대 계단을 올랐다." && tv.selectedRange() == NSRange(location: 0, length: 2),
              "make from selection: the editor stays on the original sheet")
        check(IthacaCore.parseEntry(text: madeText)?.name == "서윤" && model.folders.first { $0.id == loreId }?.sheets.contains { $0.id == fromSel } == true,
              "make from selection: '서윤' created in 설정")
        check(model.toast?.action == model.t(.actionOpen) && model.toast?.message.contains("서윤") == true, "make from selection: toast with [열기] (\(model.toast?.message ?? "-"))")
        model.toast?.undo?()
        pump(0.3)
        check(model.sheetId == fromSel, "[열기] opens the new entry")
        model.toast = nil
        model.openSheet(prose)
        pump(0.3)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        check(!AppCommand.entryCharacter.available(model), "make from selection needs a selection")
        // Add field: appended at the end as one undo step, caret under the new title; suggestions drop what's there.
        model.openSheet(made[.term]!)
        pump(0.3)
        check(AppCommand.addField.available(model) && model.openEntryKind == .term, "add field available in an entry")
        check(StoryBible.missingSections(tv.string, language: .ko) == ["예문"], "term suggestions: 예문")
        let beforeAdd = tv.string
        coord.appendSection("예문")
        pump(0.1)
        check(tv.string == beforeAdd + "\n## 예문\n" && tv.selectedRange().location == (tv.string as NSString).length, "add field appends '## 예문' with the caret below it")
        check(StoryBible.missingSections(tv.string, language: .ko) == [], "suggestions drop a field that's there")
        coord.appendSection("버릇")
        pump(0.1)
        check(tv.string.hasSuffix("## 예문\n\n## 버릇\n"), "a custom field after it, one blank line apart")
        tv.undoManager?.undo()
        check(tv.string == beforeAdd + "\n## 예문\n", "one undo removes the custom field")
        tv.undoManager?.undo()
        check(tv.string == beforeAdd, "a second undo removes the first")
        check(coord.addFieldMenu()?.items.first?.title == "예문" && coord.entryMenuItems().map(\.title) == [model.t(.entryAddField)],
              "context menu: add field (no selection → no make-from-selection)")
        // Rendering: labels for keys and section titles; the text never changes.
        model.openSheet(made[.character]!)
        pump(0.4)
        let entryText = tv.string
        let ens = entryText as NSString
        let keyAt = ens.range(of: "종류").location, valueAt = ens.range(of: "인물").location
        let sectionAt = ens.range(of: "## 성격").location
        check(color(at: keyAt) == resolved(.token(T.Color.inkTertiary)) && color(at: valueAt) == resolved(.token(T.Color.inkPrimary)),
              "front matter: key in ink.tertiary, value in ink.primary")
        check(color(at: 0) == resolved(.token(T.Color.inkMarkup)), "front matter: --- in ink.markup")
        check(fontSize(at: keyAt) < fontSize(at: valueAt), "front matter: key label smaller (\(fontSize(at: keyAt)) < \(fontSize(at: valueAt)))")
        check(color(at: sectionAt + 3) == resolved(.token(T.Color.inkSecondary)) && fontSize(at: sectionAt + 3) < fontSize(at: valueAt)
              && color(at: sectionAt) == resolved(.token(T.Color.inkMarkup)), "section title: label in ink.secondary, ## dim")
        check(tv.string == entryText && model.text == entryText && !model.dirty, "entry rendering leaves the text unchanged")
        // A plain sheet starting with --- (a scene break, no kind key) keeps the ordinary look; ## stays a heading.
        let plain = (try? lib.createSheet(project: pid, folder: serialId, text: "---\n키: 값\n---\n## 소제목\n본문"))!.id
        model.reloadOutline()
        model.openSheet(plain)
        pump(0.4)
        check(color(at: 4) != resolved(.token(T.Color.inkTertiary)) && fontSize(at: (tv.string as NSString).range(of: "소제목").location) > fontSize(at: 4),
              "plain sheet with --- is not styled as an entry")
        // Typing the kind key turns it into an entry: the ## line restyles too.
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.insertText("종류: 장소\n", replacementRange: tv.selectedRange())
        pump(0.4)
        let sub = (tv.string as NSString).range(of: "소제목").location
        check(color(at: sub) == resolved(.token(T.Color.inkSecondary)), "becoming an entry restyles its ## lines")
        model.flushSave()
        // 24. Story bible in the editor (story-bible spec §2–§5): `@` names, ⌥Esc, the card, mentions, underline.
        bibleChecks(model: model, lib: lib, tv: tv, coord: coord, check: check, setText: setText, type: type, undo: undo)

        pb.clearContents()
        pb.writeObjects(clip.map { pairs in let i = NSPasteboardItem(); pairs.forEach { i.setData($0.1, forType: $0.0) }; return i })

        print(failures.isEmpty ? "✓ editor self-test passed" : "✗ \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    // swiftlint:disable:next function_body_length
    private static func bibleChecks(model: AppModel, lib: MockLibrary, tv: ManuscriptTextView, coord: ManuscriptView.Coordinator,
                                    check: (Bool, String) -> Void, setText: (String, Int?) -> Void, type: (String) -> Void, undo: () -> Void) {
        let pid = model.projectId!, folder = model.folders[0].id
        // Start from no entries: the entry-sheet checks before this leave some behind.
        for s in model.folders.flatMap(\.sheets) where s.entry != nil { try? lib.deleteSheetForever(project: pid, sheet: s.id) }
        // ⌘4 sticky note: only the editor, nothing open over it; ⌘4 again brings the panes back.
        model.inspectorOpen = true
        model.toggleMini()
        check(model.mini && model.panesHidden && !model.inspectorOpen, "small window: editor only")
        model.toggleMini()
        check(!model.mini && !model.panesHidden, "small window off: panes back")
        // The ＋ picker: template fields without summary and notes; 0.6.0's `세력` reads as a group.
        check(NewSheetPicker.templateFields(.character, .ko) == ["성격", "말투", "호칭", "반응"], "picker fields \(NewSheetPicker.templateFields(.character, .ko))")
        check(NewSheetPicker.templateFields(.term, .ko) == ["뜻"], "picker fields (term)")
        check(IthacaCore.parseEntry(text: "---\n종류: 세력\n---\n# 해무회\n")?.kind == .group, "old 세력 kind is a group")
        check(model.nextEpisodeNumber(in: folder) != nil && model.folders.count > 1 && model.nextEpisodeNumber(in: model.folders[1].id) == nil, "episode number only in the serial folder")
        func make(_ text: String) -> String { (try? lib.createSheet(project: pid, folder: folder, text: text))!.id }
        let seoyun = make("---\n종류: 인물\n별칭: 윤이, 등대지기의 딸\n상태: 실종\n---\n# 서윤\n\n## 한 줄 소개\n불빛 횟수를 세는 아이.\n\n## 말투\n짧게 끊어 말한다.\n\n## 호칭\n오빠를 '진아'라고 부른다.\n\n## 변화\n- 3화부터: 말이 늘었다.\n- 20화부터: 등대를 떠난다.\n")
        let seojin = make("---\n종류: 인물\n---\n# 서진\n\n## 한 줄 소개\n서윤의 오빠.\n")
        let island = make("---\n종류: 장소\n별칭: 섬\n---\n# 벼리섬\n\n## 한 줄 소개\n등대가 있는 섬.\n")
        _ = make("---\n종류: 인물\n---\n# 벼리\n")
        _ = make("---\nkind: term\n---\n# 한서\n\n## 뜻\n옛 기록.\n")
        let ep1 = make("1화\n\n서진이 왔다.\n\"서윤아, 가자.\"\n벼리섬에 비가 왔다.")
        let ep2 = make("2화\n\n서진은 혼자 남았다.")
        _ = try? lib.setEpisode(project: pid, sheet: ep1, info: EpisodeInfo(number: 1, status: .published))
        _ = try? lib.setEpisode(project: pid, sheet: ep2, info: EpisodeInfo(number: 2, status: .draft))
        let page = make("")
        model.reloadOutline()
        model.openSheet(page)
        pump(0.6)
        check(model.bible.count == 5, "bible cache refreshed after the outline reload (\(model.bible.map(\.name)))")
        check(model.bible.first?.name == "서진" && model.bible.first?.lastSeen?.number == 2, "bible sorted by last seen (\(model.bible.map(\.name)))")
        let names = coord.names
        func rows() -> [String] { names.state.rows.map { $0.alias ? "\($0.text)·\($0.entry.name)" : $0.text } }
        func fresh(_ s: String) { names.close(); coord.card.close(); setText(s, nil) }
        func marked(_ s: String) {
            tv.setMarkedText(s, selectedRange: NSRange(location: (s as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            pump(0.05)
        }
        let returnKey = #selector(NSResponder.insertNewline(_:))

        // Trigger positions.
        for (before, opens) in [("", true), ("말 ", true), ("「", true), ("\"", true), ("(", true), ("말\n", true), ("메일me", false), ("가", false)] {
            fresh(before)
            type("@")
            check(names.isOpen == opens, "@ after '\(before.debugDescription)' \(opens ? "opens" : "does not open") the list")
        }
        fresh("")
        type("@")
        type("@")
        check(tv.string == "@" && !names.isOpen, "@@ leaves a single @ and no list ('\(tv.string)')")
        check(names.panelFrame == nil, "no panel on screen after @@")
        fresh("")
        type("@")
        check(names.panelFrame.map { $0.width > 0 } == true && tv.window?.childWindows?.contains { $0 is NamePanel } == true && !(NSApp.keyWindow is NamePanel),
              "panel shown as a child window that never becomes key")
        check(tv.window?.firstResponder === tv, "the editor keeps the keyboard while the list is up")

        // Filtering: prefix, initial consonants, alias, substring; ordering.
        check(rows() == ["서진", "벼리섬", "서윤", "벼리", "한서"], "empty query: most recently seen first, then by name (\(rows()))")
        type("ㅅ")
        check(rows() == ["서진", "벼리섬", "서윤", "한서"], "ㅅ: 초성 at the start or inside, recent first (\(rows()))")
        type("ㅇ")
        check(rows() == ["서윤"], "ㅅㅇ → 서윤 only (\(rows()))")
        fresh("")
        type("@")
        for s in ["윤", "이"] { type(s) }
        check(rows() == ["윤이·서윤"], "alias match shows 'alias · name' (\(rows()))")
        fresh("")
        type("@")
        for s in ["벼", "리"] { type(s) }
        check(rows() == ["벼리", "벼리섬"], "exact match first (\(rows()))")
        type("섬")
        check(rows() == ["벼리섬"], "longer query narrows (\(rows()))")
        type("ㅋ")
        check(!names.isOpen, "no match closes the list")
        fresh("")
        type("@")
        type("서")
        type(" ")
        check(!names.isOpen && tv.string == "@서 ", "a space closes the list, text kept")

        // Return / Tab insert as one undo step; ⇧Return and Esc keep the text.
        fresh("말 ")
        type("@")
        for s in ["서", "진"] { type(s) }
        tv.doCommand(by: returnKey)
        check(tv.string == "말 서진" && !names.isOpen && tv.selectedRange().location == 4, "Return inserts the name ('\(tv.string)')")
        undo()
        check(tv.string == "말 @서진", "one undo gives back @ and the query ('\(tv.string)')")
        fresh("")
        type("@")
        type("윤")
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        check(tv.string == "서윤", "Tab inserts the name matched by its middle ('\(tv.string)')")
        fresh("")
        type("@")
        for s in ["윤", "이"] { type(s) }
        tv.doCommand(by: returnKey)
        check(tv.string == "윤이", "an alias match inserts the alias ('\(tv.string)')")
        fresh("")
        type("@")
        type("ㅅ")
        tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        check(names.state.selected == 1, "↓ moves the selection")
        tv.doCommand(by: returnKey)
        check(tv.string == "벼리섬", "Return inserts the selected row ('\(tv.string)')")
        fresh("")
        type("@")
        type("서")
        check(names.doCommand(returnKey, shift: true) && tv.string == "@서" && !names.isOpen, "⇧Return closes and keeps '@서' ('\(tv.string)')")
        fresh("")
        type("@")
        type("서")
        model.focusMode = true
        tv.cancelOperation(nil)
        check(tv.string == "@서" && !names.isOpen && model.focusMode, "Esc closes the list first, text kept, focus mode stays")
        tv.cancelOperation(nil)
        check(!model.focusMode, "the next Esc leaves focus mode")

        // Composition: the syllable being composed filters too, and Return inserts the up-to-date name.
        fresh("말 ")
        type("@")
        type("서")
        marked("ㅇ")
        check(rows().first == "서윤", "composing ㅇ filters (\(rows()))")
        marked("유")
        check(rows() == ["서윤"], "composing 유 matches 윤 (\(rows()))")
        tv.doCommand(by: returnKey)
        check(tv.string == "말 서윤" && !tv.hasMarkedText(), "marked syllable + Return inserts the right name ('\(tv.string)')")
        fresh("")
        type("@")
        marked("ㅅ"); marked("서"); marked("성")
        check(rows().contains("서윤"), "'성' while composing still finds 서윤 (ㅇ goes on to the next syllable) (\(rows()))")
        // What the input method really sends for Return: commit the syllable, then insertNewline.
        tv.insertText("서", replacementRange: tv.markedRange())
        marked("ㅈ"); marked("지"); marked("진")
        tv.insertText("진", replacementRange: tv.markedRange())
        tv.doCommand(by: returnKey)
        check(tv.string == "서진", "IME commit then Return inserts 서진 ('\(tv.string)')")

        // ⌥Esc: names first, then the system's words; a particle after the word is cut.
        fresh("서")
        var index = -1
        let comps = tv.completions(forPartialWordRange: NSRange(location: 0, length: 1), indexOfSelectedItem: &index) ?? []
        check(comps.prefix(2) == ["서진", "서윤"] && index == 0, "⌥Esc completions put names first (\(comps.prefix(4)))")
        fresh("벼리에")
        check(tv.rangeForUserCompletion == NSRange(location: 0, length: 2), "⌥Esc ignores the particle after 벼리 (\(tv.rangeForUserCompletion))")
        check(AppCommand.completeName.keysLabel == "⌥⎋" && AppCommand.entryCard.keysLabel == "⌥⌘R", "commands: Insert Name ⌥⎋, card ⌥⌘R")

        // The card: the name at (or right before) the caret.
        fresh("그때 서윤이가 벼리섬에 갔다")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        check(coord.showEntryCard() && coord.card.shown?.entry == seoyun, "⌥⌘R right after 서윤 opens its card")
        check(tv.window?.firstResponder === tv, "the card leaves the keyboard in the editor")
        tv.cancelOperation(nil)
        check(!coord.card.isOpen && tv.string == "그때 서윤이가 벼리섬에 갔다", "Esc closes the card")
        tv.setSelectedRange(NSRange(location: 10, length: 0))
        check(coord.showEntryCard() && coord.card.shown?.entry == island, "inside 벼리섬: the longest name wins")
        type("!")
        check(!coord.card.isOpen && tv.string.contains("벼리!섬"), "typing closes the card, the key goes to the text")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        check(!coord.showEntryCard(), "not on a name: no card")
        fresh("윤이는")
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        check(coord.showEntryCard() && coord.card.shown?.entry == seoyun, "an alias opens the entry's card")
        let last = model.lastAppearance(of: model.entry(seoyun)!)
        check(last?.number == 1 && last?.lines.first == "\"서윤아, 가자.\"", "card: last seen 1화 with its line (\(String(describing: last)))")
        let e = model.entry(seoyun)!
        check(e.summary == "불빛 횟수를 세는 아이." && e.status == "실종" && e.section(.voice) == "짧게 끊어 말한다." && e.latestChange == "20화부터: 등대를 떠난다.",
              "card fields: summary, status, voice, latest change")
        tv.doCommand(by: returnKey)
        pump(0.2)
        check(model.sheetId == seoyun, "Return on the card opens the entry")
        check(model.openEntry?.sheet == seoyun && model.appearances(seoyun).compactMap(\.number) == [1], "entry sheet: appearances (\(model.appearances(seoyun).map(\.number)))")
        let numbered = model.appearances(seoyun).first { $0.number != nil }
        check(numbered.map(model.appearanceLabel) == "1화", "appearance row label (\(numbered.map(model.appearanceLabel) ?? "-"))")
        model.openSheet(page)
        pump(0.3)

        // v3 §1: as-of-episode card, previous episode's end, noting a line, finding in appearance lines.
        check(e.latestChange(through: 10) == "3화부터: 말이 늘었다." && e.latestChange(through: 2) == nil && e.latestChange(through: nil) == "20화부터: 등대를 떠난다.",
              "latest change as of an episode")
        check(BibleEntry.episodeNumber(in: "ep 12: left") == 12 && BibleEntry.episodeNumber(in: "120화: 사망") == 120 && BibleEntry.episodeNumber(in: "메모") == nil, "episode number in a change item")
        let mid = "---\n종류: 인물\n---\n# 가\n\n## 메모\n- 하나\n\n## 말투\n짧게\n"
        check(StoryBible.appendItem("- 둘", to: .notes, in: mid, language: .ko) == "---\n종류: 인물\n---\n# 가\n\n## 메모\n- 하나\n- 둘\n\n## 말투\n짧게\n", "note goes under the notes section's last line")
        check(StoryBible.appendItem("- 둘", to: .changes, in: mid, language: .ko).hasSuffix("## 말투\n짧게\n\n## 변화\n- 둘\n"), "no changes section: a new one at the end")
        check(StoryBible.tail(String(repeating: "가나다라마\n", count: 300), about: 600).hasPrefix("…\n") && StoryBible.tail("짧다", about: 600) == "짧다", "previous episode tail")
        model.openSheet(ep2)
        pump(0.3)
        let asOf2 = model.cardAppearances(of: model.entry(seoyun)!)
        check(asOf2.last?.number == 1 && asOf2.first?.number == 1, "card as of 2화: first and last 1화")
        check(model.previousEpisode()?.tail.contains("벼리섬에 비가 왔다.") == true, "previous episode's end (\(model.previousEpisode()?.tail ?? "nil"))")
        check(model.noteTargets(for: "서진은 혼자 남았다.").map(\.name) == ["서진"], "note targets: names in the selection")
        let seojinBefore = (try? lib.sheetText(project: pid, sheet: seojin)) ?? ""
        check(model.noteInEntry(model.entry(seojin)!, "서진은 혼자\n남았다.", asChange: false), "note in entry")
        check((try? lib.sheetText(project: pid, sheet: seojin))?.hasSuffix("## 메모\n- 2화: 서진은 혼자 남았다.\n") == true, "noted as '- 2화: …' under 메모 (\((try? lib.sheetText(project: pid, sheet: seojin)) ?? ""))")
        model.toast?.undo?()
        check((try? lib.sheetText(project: pid, sheet: seojin)) == seojinBefore, "toast undo restores the entry")
        model.toast = nil
        let found = model.searchAppearances(model.entry(seoyun)!, "가자")
        check(found.count == 1 && found.first?.sheet == ep1 && found.first?.label == "1화", "find in appearance lines (\(found))")
        model.openSheet(page)
        pump(0.3)

        // Inspector "이 시트에 나온 항목": 1 s after typing stops, each entry once, in order; not while composing.
        fresh("벼리섬에 서윤이 갔다. 서윤은 웃었다. 서진")
        pump(1.3)
        check(model.mentionedEntries.map(\.name) == ["벼리섬", "서윤", "서진"], "mentions in this sheet, once each (\(model.mentionedEntries.map(\.name)))")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let gen = model.mentionsGeneration
        marked("ㅎ")
        pump(1.3)
        check(model.mentionsGeneration == gen && tv.hasMarkedText(), "no mention refresh while composing")
        tv.unmarkText()
        pump(1.3)
        check(model.mentionsGeneration > gen, "refreshed once the composition ended")

        // Underline: rendering attributes only.
        fresh("서윤이 벼리섬에 갔다")
        pump(1.3)
        check(coord.marks.debugUnderlined() == 0, "underline off by default")
        model.underlineNames = true
        pump(0.3)
        check(coord.marks.debugUnderlined() == 2, "underline on: both names (\(coord.marks.debugUnderlined()))")
        check(tv.string == "서윤이 벼리섬에 갔다" && tv.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil, "underline never touches the text or its attributes")
        model.underlineNames = false
        pump(0.3)
        check(coord.marks.debugUnderlined() == 0, "underline off again")
        model.flushSave()
    }

    /// Waits of a second or more stand for the app's own pauses: they shrink with them (`Wait.scale`).
    private static func pump(_ seconds: Double) {
        NSApp.windows.forEach(Headless.hide)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds >= 1 ? seconds * Wait.scale : seconds))
    }

    private static func findTextView(_ v: NSView?) -> ManuscriptTextView? {
        guard let v else { return nil }
        if let t = v as? ManuscriptTextView { return t }
        for s in v.subviews { if let t = findTextView(s) { return t } }
        return nil
    }

    private static func fail(_ m: String) -> Never { print("✗ \(m)"); exit(1) }
}
