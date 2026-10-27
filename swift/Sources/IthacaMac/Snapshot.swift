// `Ithaca --snapshot <dir>`: renders key screens offscreen (NSHostingView + cacheDisplay) to PNGs and exits.
// No screen recording / accessibility permission needed, so the lead (or CI) can look at screens without the app on screen.
// Uses the seeded MockLibrary and a throwaway UserDefaults suite — the real library and preferences are not touched.
import AppKit
import IthacaDesign
import SwiftUI

@MainActor
enum Snapshot {
    struct Scene {
        var name: String
        var size: CGSize
        var dark = false
        var locale: LocalePref = .ko
        var setup: (AppModel, UserDefaults) -> Void = { _, _ in }
        /// Settings render as a pane without a window title bar (it showed as an empty strip above the form).
        var titled = true
        /// Dialogs: size the canvas to the view (what a sheet does), so empty space below the form shows up as a real bug.
        var fit = false
        /// Before the model exists (what info() reports: read-only, problems…).
        var info: LibraryInfo? = nil
        var view: (AppModel) -> AnyView = { _ in AnyView(ShellView()) }
    }

    static func run(to dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["ITHACA_SNAPSHOT_ONLY"]
        for s in scenes where only == nil || s.name.contains(only!) {
            render(s, to: dir.appendingPathComponent("\(s.name).png"))
        }
        print("✓ snapshots in \(dir.path)")
        exit(0)
    }

    static var scenes: [Scene] {
        let wide = CGSize(width: 1240, height: 800)
        let updater = UpdaterViewModel()
        func settings(_ tab: SettingsSection, _ locale: LocalePref = .ko) -> Scene {
            Scene(name: "settings-\(tab.rawValue)\(locale == .ko ? "" : "-\(locale.rawValue)")", size: CGSize(width: 640, height: 560), locale: locale,
                  setup: { _, d in d.set(tab.rawValue, forKey: "ithaca.settingsTab") }, titled: false,
                  view: { _ in AnyView(SettingsView(updater: updater, only: tab)) })
        }
        func editorAll(_ locale: LocalePref) -> Scene {
            Scene(name: "settings-editor-all-\(locale.rawValue)", size: CGSize(width: 640, height: 2240), locale: locale,
                  setup: { m, _ in m.autoPairs = true; m.ellipsis = .double; m.symbols.append(Symbols.make("〔", close: "〕")) }, titled: false,
                  view: { _ in AnyView(SettingsView(updater: updater, only: .editor)) })
        }
        func claude(_ locale: LocalePref) -> Scene {
            Scene(name: "settings-claude-on-\(locale.rawValue)", size: CGSize(width: 640, height: 760), locale: locale,
                  setup: { m, d in
                      d.set(SettingsSection.claude.rawValue, forKey: "ithaca.settingsTab")
                      _ = try? m.library.setMcpSettings(McpSettings(enabled: true, projects: m.projects.prefix(1).map(\.id)))
                  }, titled: false,
                  view: { _ in AnyView(SettingsView(updater: updater, only: .claude)) })
        }
        return [
            Scene(name: "shell-ko-light", size: wide),
            Scene(name: "shell-ko-dark", size: wide, dark: true),
            Scene(name: "shell-ko-lines-wider-narrow", size: wide, setup: { m, _ in m.lineSpacing = .wider; m.lineWidth = .narrow }),
            Scene(name: "shell-en-light", size: wide, locale: .en),
            Scene(name: "shell-900", size: CGSize(width: 900, height: 700)),
            Scene(name: "shell-700-library-overlay", size: CGSize(width: 700, height: 700), setup: { m, _ in m.libraryOverlay = true }),
            Scene(name: "shell-1240-inspector-info", size: wide, setup: { m, d in m.inspectorOpen = true; d.set("info", forKey: "ithaca.inspectorTab") }),
            Scene(name: "shell-1240-inspector-reference-dark", size: wide, dark: true, setup: { m, d in m.inspectorOpen = true; d.set("reference", forKey: "ithaca.inspectorTab") }),
            Scene(name: "shell-inspector-outline-1000", size: CGSize(width: 1000, height: 700), setup: { m, d in m.inspectorOpen = true; d.set("outline", forKey: "ithaca.inspectorTab") }),
            Scene(name: "shell-focus", size: wide, setup: { m, _ in m.focusMode = true }),
            Scene(name: "shell-library-folded", size: wide, setup: { m, d in
                for t in ["두 번째 작품", "세 번째 작품"] { _ = try? m.library.createProject(title: t, language: .ko, folders: ["연재"]) }
                m.refreshProjects()
                d.set(true, forKey: "ithaca.libraryFolded")
            }),
            Scene(name: "shell-library-many", size: wide, setup: { m, _ in
                for t in ["두 번째 작품", "세 번째 작품"] { _ = try? m.library.createProject(title: t, language: .ko, folders: ["연재"]) }
                m.refreshProjects()
            }),
            // Empty folder: the list offers "new sheet" (navigation spec).
            Scene(name: "shell-empty-folder", size: wide, setup: { m, _ in m.createFolder("빈 폴더") }),
            Scene(name: "shell-list-focused", size: wide, setup: { m, _ in m.listFocusRequest += 1 }),
            Scene(name: "shell-trash", size: wide, setup: { m, _ in
                if let s = m.folder?.sheets.last { m.trashSheet(s.id) }
                m.toast = nil
                m.showingTrash = true
            }),
            Scene(name: "shell-toast", size: wide, setup: { m, _ in if let s = m.folder?.sheets.first { m.trashSheet(s.id) } }),
            Scene(name: "shell-damaged", size: wide, setup: { m, _ in
                if let mock = m.library as? MockLibrary, let id = m.sheetId { mock.damagedSheets.insert(id); m.reloadOutline(); m.openSheet(id) }
            }),
            Scene(name: "shell-damaged-en-nobackup-900", size: CGSize(width: 900, height: 700), locale: .en, setup: { m, _ in
                if let mock = m.library as? MockLibrary, let id = m.sheetId { mock.damagedSheets.insert(id); m.reloadOutline(); m.openSheet(id); m.noBackupForSheet = id }
                m.tocDamagedProject = m.projectId
            }),
            Scene(name: "shell-en-trash", size: wide, locale: .en, setup: { m, _ in
                if let s = m.folder?.sheets.last { m.trashSheet(s.id) }
                m.toast = nil
                m.showingTrash = true
            }),
            Scene(name: "shell-en-toast", size: wide, locale: .en, setup: { m, _ in if let s = m.folder?.sheets.first { m.trashSheet(s.id) } }),
            Scene(name: "shell-busy", size: wide, setup: { m, _ in m.busy = m.t(.busyRestoreBackup) }),
            Scene(name: "export-en", size: CGSize(width: 940, height: 560), locale: .en, view: { _ in AnyView(ExportView()) }),
            Scene(name: "palette-empty", size: wide, setup: { m, _ in m.overlay = .palette(search: false) }),
            Scene(name: "palette-query", size: wide, setup: { m, _ in m.paletteSeed = "등대"; m.overlay = .palette(search: false) }),
            Scene(name: "export", size: CGSize(width: 940, height: 560), view: { _ in AnyView(ExportView()) }),
            Scene(name: "history", size: CGSize(width: 1040, height: 640), view: { _ in AnyView(HistoryView()) }),
            Scene(name: "history-en-dark", size: CGSize(width: 1040, height: 640), dark: true, locale: .en, view: { _ in AnyView(HistoryView()) }),
            // 0.5.3: dozens of autosaves today and yesterday, grouped into sessions; the newest one expanded.
            Scene(name: "history-sessions", size: CGSize(width: 1040, height: 640), setup: { m, _ in Self.autosaves(m) },
                  view: { _ in AnyView(HistoryView(expandNewest: true)) }),
            Scene(name: "history-sessions-en-dark", size: CGSize(width: 1040, height: 640), dark: true, locale: .en,
                  setup: { m, _ in Self.autosaves(m) }, view: { _ in AnyView(HistoryView()) }),
            Scene(name: "new-project-first-run", size: CGSize(width: 560, height: 640), titled: false, fit: true, view: { _ in AnyView(NewProjectView(firstRun: true)) }),
            Scene(name: "new-project-first-run-dark", size: CGSize(width: 560, height: 640), dark: true, titled: false, fit: true, view: { _ in AnyView(NewProjectView(firstRun: true)) }),
            Scene(name: "new-project-en", size: CGSize(width: 560, height: 480), locale: .en, titled: false, fit: true, view: { _ in AnyView(NewProjectView(firstRun: false)) }),
            Scene(name: "project-settings", size: CGSize(width: 560, height: 560), titled: false, fit: true, view: { _ in AnyView(ProjectSettingsView()) }),
            settings(.general), settings(.editor), settings(.editor, .en), settings(.backup), settings(.about),
            settings(.shortcuts), settings(.shortcuts, .en),
            // The whole editor tab (conveniences, the symbol list with a custom entry) on one tall canvas.
            editorAll(.ko), editorAll(.en),
            Scene(name: "settings-editor-dark", size: CGSize(width: 640, height: 560), dark: true, titled: false,
                  view: { _ in AnyView(SettingsView(updater: updater, only: .editor)) }),
            // The palette finds the editing commands by name, with their keys.
            Scene(name: "palette-commands", size: wide, setup: { m, _ in m.paletteSeed = "제목"; m.overlay = .palette(search: false) }),
            Scene(name: "palette-empty-dark", size: wide, dark: true, setup: { m, _ in m.overlay = .palette(search: false) }),
            // r3: release schedule, folder stats, platform goal, Claude connector.
            Scene(name: "shell-1240-scheduled-sheet", size: wide, setup: { m, d in
                if let s = m.folder?.sheets.first(where: { $0.episode?.status == .scheduled }) { m.openSheet(s.id) }
                m.inspectorOpen = true; d.set("info", forKey: "ithaca.inspectorTab")
            }),
            Scene(name: "shell-en-scheduled-sheet", size: wide, locale: .en, setup: { m, d in
                if let s = m.folder?.sheets.first(where: { $0.episode?.status == .scheduled }) { m.openSheet(s.id) }
                m.inspectorOpen = true; d.set("info", forKey: "ithaca.inspectorTab")
            }),
            Scene(name: "shell-1240-folder-stats", size: wide, setup: { m, _ in
                if let s = m.folder?.sheets.first { m.toggleExcluded(s.id) }
                m.showFolderInfo()
            }),
            Scene(name: "shell-en-folder-stats-1000", size: CGSize(width: 1000, height: 760), locale: .en, setup: { m, _ in m.showFolderInfo() }),
            Scene(name: "shell-goal-munpia", size: wide, setup: { m, _ in m.updateProject(ProjectPatch(goal: .some(Goal(count: 5000, basis: .munpia)))) }),
            Scene(name: "project-settings-munpia", size: CGSize(width: 560, height: 560), setup: { m, _ in m.updateProject(ProjectPatch(goal: .some(Goal(count: 5000, basis: .munpia)))) },
                  view: { _ in AnyView(ProjectSettingsView()) }),
            claude(.ko), claude(.en), settings(.claude),
            // fix4: read-only causes, one compact notice bar.
            Scene(name: "shell-readonly-locked-damaged", size: wide,
                  setup: { m, _ in if let mock = m.library as? MockLibrary, let id = m.sheetId { mock.damagedSheets.insert(id); m.reloadOutline(); m.openSheet(id) } },
                  info: Self.roInfo(locked: true, problems: ["Another Ithaca has this library open. Opened read-only; close the other one and open again to edit.", "Project x could not be read."])),
            Scene(name: "shell-readonly-newer-en", size: wide, locale: .en, info: Self.roInfo(locked: false, problems: [])),
            Scene(name: "shell-readonly-problems-expanded", size: wide,
                  setup: { _, d in d.set(true, forKey: "ithaca.noticeExpanded") },
                  info: Self.roInfo(locked: false, problems: ["library.json is missing but the folder holds projects. Opened read-only so nothing is overwritten."])),
            Scene(name: "shell-problems-only", size: wide, info: { var i = Self.roInfo(locked: false, problems: ["Project y could not be read."]); i.readOnly = false; return i }()),
            Scene(name: "icons", size: CGSize(width: 720, height: 300), view: { _ in AnyView(IconSheet()) }),
            // Story bible (story-bible §1 · §6): an entry open in the editor, kind icons in the list; the import sheet.
            Scene(name: "entry-sheet-ko", size: wide, setup: { m, _ in Self.bibleSeed(m) }),
            Scene(name: "entry-sheet-ko-dark", size: wide, dark: true, setup: { m, _ in Self.bibleSeed(m) }),
            Scene(name: "entry-sheet-ko-indent-large", size: wide, setup: { m, _ in Self.bibleSeed(m); m.firstLineIndent = true; m.textSize = .large }),
            Scene(name: "entry-sheet-en", size: wide, locale: .en, setup: { m, _ in Self.bibleSeed(m) }),
            Scene(name: "entry-toast", size: wide, setup: { m, _ in
                Self.bibleSeed(m)
                if let s = m.folders.first?.sheets.first { m.openSheet(s.id) }
                m.showToast(Toast(message: m.t(.entryCreated, ["folder": "설정", "name": "서윤"]), undo: {}, action: m.t(.actionOpen)))
            }),
            Scene(name: "bible-import", size: CGSize(width: 720, height: 640), titled: false, fit: true,
                  view: { _ in AnyView(BibleImportView(path: Self.notionFixture())) }),
            Scene(name: "bible-import-en-dark", size: CGSize(width: 720, height: 640), dark: true, locale: .en, titled: false, fit: true,
                  view: { _ in AnyView(BibleImportView(path: Self.notionFixture())) }),
            Scene(name: "bible-import-missing", size: CGSize(width: 720, height: 640), titled: false, fit: true,
                  view: { _ in AnyView(BibleImportView(path: "/nonexistent/노션 내보내기")) }),
        ]
    }

    /// Autosave runs like a real writing day: saves every ~2 min yesterday evening, this morning, and just now.
    static func autosaves(_ m: AppModel) {
        guard let mock = m.library as? MockLibrary, let id = m.sheetId, var text = try? mock.sheetText(project: m.projectId ?? "", sheet: id) else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000), minute: Int64 = 60_000
        let cal = Calendar.current
        let yesterday = Int64((cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!.timeIntervalSince1970 + 21 * 3600) * 1000)
        let words = ["바람이 ", "다시 ", "불었다. ", "서윤은 ", "등대 ", "계단을 ", "올랐다. ", "열한 ", "번째 ", "불빛이 "]
        func run(from start: Int64, saves: Int, every: Int64, trimEvery: Int = 0) {
            for i in 0..<saves {
                if trimEvery > 0, i % trimEvery == trimEvery - 1, text.count > 20 { text.removeLast(6) } else { text += words[i % words.count] }
                mock.debugAppendVersion(sheet: id, text: text, at: start + Int64(i) * every)
            }
        }
        run(from: yesterday, saves: 18, every: 2 * minute)
        run(from: yesterday + 75 * minute, saves: 6, every: 3 * minute)
        run(from: now - 4 * 60 * minute, saves: 24, every: 2 * minute, trimEvery: 5)
        run(from: now - 40 * minute, saves: 9, every: 4 * minute, trimEvery: 4)
    }

    /// The seed's lore folder as story bible entries (a filled character, a place, a faction, a term), the character open.
    static func bibleSeed(_ m: AppModel) {
        guard let pid = m.projectId, let lore = m.folders.first(where: { $0.name == "설정" }) else { return }
        let character = """
        ---
        종류: 인물
        별칭: 윤이, 등대지기의 딸
        나이: 19
        소속: 벼리섬 등대
        능력:
        상태: 아버지가 사라진 뒤 혼자 등대를 지킨다
        외모: 짧은 머리, 소매가 긴 비옷
        ---
        # 한서윤

        ## 한 줄 소개
        등대지기의 딸. 밤마다 불빛 신호를 기록한다.

        ## 성격
        말수가 적고 꼼꼼하다. 긴장하면 손끝으로 숫자를 센다.

        ## 말투
        짧고 단정함. 존댓말을 쓰지만 아버지 앞에서만 반말.

        ## 호칭
        아버지 → "아빠", 엘리엇 → "측량사님"

        ## 반응

        ## 메모
        아버지의 logbook 마지막 장을 아직 아무에게도 보여주지 않았다.

        """
        let place = "---\n종류: 장소\n별칭: 벼리 등대\n속한 곳: 벼리섬\n---\n# 벼리섬 등대\n\n## 한 줄 소개\n백 년 된 등대. 렌즈가 한 번도 꺼진 적 없다고 전해진다.\n"
        let sheets = lore.sheets
        if sheets.count >= 3 {
            _ = try? m.library.saveSheet(project: pid, sheet: sheets[0].id, text: character)
            _ = try? m.library.saveSheet(project: pid, sheet: sheets[2].id, text: place)
        }
        _ = try? m.library.createSheet(project: pid, folder: lore.id, text: "---\n종류: 세력\n별칭:\n우두머리: 해무회장\n---\n# 해무회\n\n## 한 줄 소개\n섬의 항로를 쥔 선주들의 모임.\n")
        _ = try? m.library.createSheet(project: pid, folder: lore.id, text: "---\n종류: 용어\n별칭: 불빛말\n---\n# 등대 신호\n\n## 뜻\n불빛의 횟수와 간격으로 주고받는 말.\n")
        m.reloadOutline()
        if let first = sheets.first { m.openSheet(first.id) }
    }

    /// A small Notion export in a temp folder (the same pages the selftests use).
    static func notionFixture() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ithaca-snapshot-notion")
        try? FileManager.default.removeItem(at: dir)
        NavSelfTest.notionFixture(dir)
        try? "# Elliot Marsh 0123456789abcdef0123456789abcdef\n\nAge: 31\nRole: surveyor\n\nWashed ashore with a broken theodolite.\n"
            .write(to: dir.appendingPathComponent("Elliot Marsh 0123456789abcdef0123456789abcdef.md"), atomically: true, encoding: .utf8)
        return dir.path
    }

    static func roInfo(locked: Bool, problems: [String]) -> LibraryInfo {
        LibraryInfo(format: 1, coreVersion: "mock", readOnly: !locked, migratedFrom: nil, backupPath: nil, inMemory: true, lockedByOther: locked, problems: problems)
    }

    private static func render(_ s: Scene, to url: URL) {
        let suite = "io.github.colosan.ithaca.snapshot"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(s.locale.rawValue, forKey: "ithaca.locale")
        let mock = MockLibrary(seeded: true, device: AppEnvironment.deviceName)
        mock.infoOverride = s.info
        let model = AppModel(library: mock, defaults: defaults)
        s.setup(model, defaults)
        let appearance = NSAppearance(named: s.dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        func content() -> some View {
            s.view(model)
                .environment(model)
                .environment(\.locale, Locale(identifier: model.locale.rawValue))
                .defaultAppStorage(defaults)
        }
        // A dialog renders at the size its sheet would take (its fitting size), not on a tall fixed canvas.
        var size = s.size
        if s.fit {
            let probe = NSHostingView(rootView: content())
            probe.appearance = appearance
            size = probe.fittingSize
        }
        let root = content()
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color.surfaceCanvas)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: s.titled ? [.titled, .fullSizeContentView] : [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))  // off screen: tests must not show over the owner's work
        window.appearance = appearance
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        // Let async work (text loading, tasks, layout passes) settle.
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
        print("  \(url.lastPathComponent)")
    }
}

/// Every icon of design/icons.json drawn from the generated Lucide vectors — a quick check of the SVG path parser.
private struct IconSheet: View {
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 10), spacing: 12) {
            ForEach(IthacaIcon.allCases, id: \.self) { i in
                VStack(spacing: 2) {
                    Icon(i, size: T.Size.iconLg, color: .inkPrimary)
                    Text(i.rawValue).font(.system(size: 8)).foregroundStyle(Color.inkTertiary).lineLimit(1)
                }
            }
        }
        .padding()
    }
}
