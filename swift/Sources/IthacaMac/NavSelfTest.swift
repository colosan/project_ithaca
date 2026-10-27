// `Ithaca --selftest-nav`: the library / sheet list / overlays offscreen, in-memory library. Keys go to the test's own
// offscreen window (window.sendEvent), never through the system: nothing on screen is driven.
// Checks: list keyboard (↑↓ · Return · Delete · type-select), ⌘⌫ in text, Esc on overlays, sheet drag payload,
// and the model actions behind the context menus (duplicate, status, folders, projects).
import AppKit
import IthacaCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum NavSelfTest {
    static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let lib = MockLibrary(seeded: true)
        let suite = "io.github.colosan.ithaca.navtest"
        UserDefaults().removePersistentDomain(forName: suite)
        let model = AppModel(library: lib, defaults: UserDefaults(suiteName: suite)!)
        model.confirmDelete = false
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ✓ " : "  ✗ ") + what); if !ok { failures += 1 } }

        // Type-select matching.
        check(SheetListPane.typeSelectMatches("다시", "다시 그리는 지도"), "type-select prefix")
        check(SheetListPane.typeSelectMatches("ㄷ", "다시 그리는 지도") && SheetListPane.typeSelectMatches("ㄷㅅ", "다시"), "type-select initial consonants")
        check(SheetListPane.typeSelectMatches("cast", "Castaway") && !SheetListPane.typeSelectMatches("x", "Castaway"), "type-select case-insensitive")

        // Offscreen window (far off any display) with the real shell, 1240 pt: everything docked.
        let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: 1240, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))  // off screen: tests must not show over the owner's work
        window.contentView = NSHostingView(rootView: ShellView().environment(model))
        window.orderFrontRegardless()
        pump(0.5)
        guard let sheets = model.folder?.sheets, sheets.count >= 3 else { print("✗ seed has no folder"); exit(1) }
        model.openSheet(sheets[0].id)
        pump(0.2)

        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)!
        }
        func send(_ e: NSEvent) { window.sendEvent(e); pump(0.15) }

        // List keyboard.
        model.listFocusRequest += 1
        pump(0.3)
        check(!(window.firstResponder is NSTextView), "list takes the keyboard (first responder \(type(of: window.firstResponder)))")
        send(key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        check(model.sheetId == sheets[1].id, "↓ opens the next sheet")
        send(key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        check(model.sheetId == sheets[0].id, "↑ opens the previous sheet")
        let target = sheets.first { !$0.title.isEmpty && $0.id != sheets[0].id }!
        send(key(0, String(target.title.prefix(1))))
        check(model.sheetId == sheets.first { SheetListPane.typeSelectMatches(String(target.title.prefix(1)), $0.title) }?.id, "type-select jumps to '\(target.title)'")
        send(key(36, "\r"))
        pump(0.2)
        check(window.firstResponder is ManuscriptTextView, "Return moves into the editor")

        // ⌘⌫ in the manuscript deletes to the line start; it does not trash the sheet.
        let open = model.sheetId
        let trashBefore = model.trash.count
        let tv0 = window.firstResponder as? ManuscriptTextView
        let nl = ((tv0?.string ?? "") as NSString).range(of: "\n").location
        tv0?.setSelectedRange(NSRange(location: nl == NSNotFound ? ((tv0?.string ?? "") as NSString).length : nl, length: 0))
        let lineBefore = tv0?.string ?? ""
        // The menu's ⌘⌫ action with the key event current, as AppKit runs it.
        if model.textTakesCommandDelete(key(51, "\u{7f}", .command)) == false { model.trashSheet() }
        pump(0.2)
        check(tv0 != nil && tv0!.string != lineBefore && tv0!.string.count < lineBefore.count, "⌘⌫ in the editor deletes to the line start")
        check(model.sheetId == open && model.trash.count == trashBefore, "⌘⌫ in the editor leaves the sheet alone")

        // Delete in the list trashes the open sheet and opens the next one.
        model.listFocusRequest += 1
        pump(0.3)
        let before = model.folder!.sheets
        let idx = before.firstIndex { $0.id == model.sheetId }!
        send(key(51, "\u{7f}"))
        check(model.trash.contains { $0.id == open } && model.sheetId == before.filter { $0.id != open }[min(idx, before.count - 2)].id, "Delete in the list trashes and opens the next")
        model.toast?.undo?()
        pump(0.1)
        check(!model.trash.contains { $0.id == open }, "undo toast restores it")

        // Esc closes the overlays at narrow widths.
        window.setContentSize(CGSize(width: 700, height: 700))
        pump(0.4)
        model.libraryOverlay = true
        pump(0.2)
        window.makeFirstResponder(nil)
        check(EscapeMonitor.handle(key(53, "\u{1b}"), model: model, window: window) && !model.libraryOverlay, "Esc closes the library overlay")
        model.inspectorOpen = true
        pump(0.2)
        check(!model.inspectorDocks && EscapeMonitor.handle(key(53, "\u{1b}"), model: model, window: window) && !model.inspectorOpen, "Esc closes the inspector overlay")
        check(!EscapeMonitor.handle(key(53, "\u{1b}"), model: model, window: window), "Esc with nothing over the editor passes through")
        window.setContentSize(CGSize(width: 1240, height: 800))
        pump(0.3)

        // Drag payload: its own type, so a text view doesn't paste the sheet id.
        let tv = window.contentView.flatMap(findTextView)
        check(tv.map { !$0.readablePasteboardTypes.contains(NSPasteboard.PasteboardType(UTType.ithacaSheet.identifier)) } ?? false,
              "sheet drag type is not something the manuscript accepts")

        // Model actions behind the menus.
        let f = model.folder!
        let src = f.sheets[0]
        model.duplicateSheet(src.id)
        let after = model.folder!.sheets
        check(after.count == f.sheets.count + 1 && after[1].id == model.sheetId && after[1].title == src.title, "duplicate lands below the original and opens")
        check(src.episode == nil || (after[1].episode?.number == nil && after[1].episode?.status == .draft), "duplicate of an episode is an unnumbered draft")
        model.setEpisodeStatus(.revising, sheet: after[2].id)
        check(model.folder!.sheets[2].episode?.status == .revising && model.sheetId == after[1].id, "status from the context menu, open sheet unchanged")
        model.toast = nil
        model.move(sheet: "not-a-sheet", to: f.id, before: nil)
        check(model.toast == nil, "a drop that isn't a sheet is ignored")
        model.createFolder("새 폴더 시험")
        check(model.folder?.name == "새 폴더 시험", "new folder is selected")
        model.newSheet(in: model.folders[0].id)
        check(model.folder?.id == model.folders[0].id, "new sheet from a folder's menu goes into that folder")
        // Delete the folder holding the open sheet: the next folder's first sheet opens.
        let doomed = model.folders[0]
        model.deleteFolder(doomed.id)
        check(!model.folders.contains { $0.id == doomed.id } && model.sheetId != nil && model.folder?.sheets.contains { $0.id == model.sheetId } == true,
              "deleting the open folder opens a sheet of the next one")
        model.toast?.undo?()
        check(model.folders.contains { $0.id == doomed.id } && model.folderId == doomed.id, "folder undo brings it back and shows it")
        while model.folders.count > 1 { model.deleteFolder(model.folders.last!.id) }
        model.toast = nil
        model.deleteFolder(model.folders[0].id)
        check(model.folders.count == 1 && model.toast == nil, "the last folder is never deleted (no error toast)")

        // Story bible (story-bible §1 · §6): a new entry from a folder's menu, then a Notion import into the lore folder.
        let loreBefore = model.loreFolder
        model.newEntry(.place, in: model.folders[0].id)
        check(model.sheet?.entry == .place && model.sheet?.folder == model.folders[0].id, "new place from a folder's menu goes into that folder")
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ithaca-navtest-notion-\(UUID().uuidString)")
        Self.notionFixture(fixture)
        let preview = (try? StoryBible.importPreview(path: fixture.path, kind: .character, language: .ko)) ?? []
        check(preview.map(\.name) == ["서윤", "하람"], "import preview: one entry per .md, Notion id cut (\(preview.map(\.name)))")
        check(preview.first?.fields ?? 0 >= 2 && preview.first?.sections ?? 0 >= 1 && preview.allSatisfy { IthacaCore.parseEntry(text: $0.text)?.kind == .character },
              "import preview: properties → fields, sections kept, texts are character entries")
        var missing = false
        do { _ = try StoryBible.importPreview(path: fixture.appendingPathComponent("없음").path, kind: .place, language: .ko) } catch let e as LibraryError { missing = e == .notFound } catch {}
        check(missing, "import preview: a missing path is notFound")
        guard let lore = loreBefore else { print("✗ no lore folder"); exit(1) }
        let loreCount = model.folders.first { $0.id == lore.id }?.sheets.count ?? 0
        check(model.importBible(preview), "import: all entries in")
        let imported = model.folders.first { $0.id == lore.id }?.sheets ?? []
        check(imported.count == loreCount + 2 && imported.suffix(2).map(\.title) == ["서윤", "하람"] && imported.suffix(2).allSatisfy { $0.entry == .character },
              "import: appended to the lore folder '\(lore.name)' as character entries")
        check(model.toast?.action == model.t(.actionOpen), "import: toast with [열기]")
        model.toast = nil
        try? FileManager.default.removeItem(at: fixture)

        // Projects from the library's context menu.
        let openProject = model.projectId!
        guard let other = model.projects.first(where: { $0.id != openProject }) else { print("✗ seed has one project"); exit(1) }
        model.renameProject(other.id, "  새 이름  ")
        check(model.projects.first { $0.id == other.id }?.title == "새 이름", "rename another project")
        model.deleteProject(other.id)
        check(model.projectId == openProject && !model.projects.contains { $0.id == other.id }, "delete another project keeps the open one")
        model.toast?.undo?()
        check(model.projects.contains { $0.id == other.id }, "project delete undo")

        print(failures == 0 ? "✓ nav selftest passed" : "✗ \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// A small Notion export: two pages (one with Notion's id suffix and properties), a sub folder, a file to skip.
    static func notionFixture(_ dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("하위"), withIntermediateDirectories: true)
        try? "# 서윤\n\n별칭: 윤이\n나이: 17\n소속: 등대\n\n등대지기의 딸.\n\n## 말투\n짧게 끊어 말한다.\n"
            .write(to: dir.appendingPathComponent("서윤 0123456789abcdef0123456789abcdef.md"), atomically: true, encoding: .utf8)
        try? "# 하람\n\n## Voice\n느릿하게 말한다.\n".write(to: dir.appendingPathComponent("하위/하람.md"), atomically: true, encoding: .utf8)
        try? "not an entry".write(to: dir.appendingPathComponent("메모.txt"), atomically: true, encoding: .utf8)
    }

    private static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private static func findTextView(_ v: NSView) -> ManuscriptTextView? {
        if let t = v as? ManuscriptTextView { return t }
        for s in v.subviews { if let t = findTextView(s) { return t } }
        return nil
    }
}
