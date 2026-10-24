// Ithaca for Mac (ADR-0004, 0008). One main window, native menu bar, Settings scene.
//   Ithaca                    the real library (Rust core) in ~/Library/Application Support/Ithaca/Library
//   Ithaca --mock             in-memory sample library (ITHACA_MOCK=1 too); ITHACA_EMPTY=1 starts it empty
//   Ithaca --snapshot <dir>   renders key screens to PNGs and exits (see Snapshot.swift)
import AppKit
import IthacaCore
import IthacaDesign
import Observation
import SwiftUI

@main
enum Main {
    static func main() {
        // Before any view or the editor asks for a font.
        FontRegistry.registerBundledFonts()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot") {
            let dir = i + 1 < args.count ? args[i + 1] : FileManager.default.currentDirectoryPath + "/snapshots"
            MainActor.assumeIsolated { Snapshot.run(to: URL(fileURLWithPath: dir)) }
            return
        }
        if args.contains("--selftest-mem") {
            MainActor.assumeIsolated { PerfSelfTest.runMem() }
            return
        }
        if args.contains("--selftest-perf") {
            MainActor.assumeIsolated { PerfSelfTest.run() }
            return
        }
        if args.contains("--selftest-nav") {
            MainActor.assumeIsolated { NavSelfTest.run() }
            return
        }
        if args.contains("--selftest-editor") {
            MainActor.assumeIsolated { EditorSelfTest.run() }
            return
        }
        if args.contains("--selftest") {
            MainActor.assumeIsolated { SelfTest.run() }
            return
        }
        IthacaApp.main()
    }
}

/// `Ithaca --selftest`: write → "quit" → reopen round-trip through AppModel + the real library folder.
/// Run it twice: the first run writes a stamped line (saved via the same flushSave the quit path uses),
/// the second run opens the library fresh, restores the last sheet and checks the line is there.
@MainActor
enum SelfTest {
    static func run() {
        let (opened, error) = AppEnvironment.makeLibrary()
        guard let library = opened else { print("✗ open failed: \(error ?? "-")"); exit(1) }
        print("library \(AppEnvironment.libraryURL.path) · core \(library.info().coreVersion) · format \(library.info().format)")
        let model = AppModel(library: library, defaults: AppEnvironment.defaults)
        let marker = AppEnvironment.defaults.string(forKey: "ithaca.selftest.marker")
        if let marker {
            let ok = model.text.contains(marker)
            print(ok ? "✓ reopened and found \(marker) in '\(model.sheet?.title ?? "")'" : "✗ marker \(marker) missing; text: \(model.text.prefix(200))")
            AppEnvironment.defaults.removeObject(forKey: "ithaca.selftest.marker")
            exit(ok ? 0 : 1)
        }
        if !model.projects.contains(where: { $0.title == "Selftest" }) {
            model.createProject(title: "Selftest", language: .ko, folders: ["연재"], goal: nil)
        } else if let p = model.projects.first(where: { $0.title == "Selftest" }) { model.selectProject(p.id) }
        guard model.sheetId != nil else { print("✗ no sheet open; folders \(model.folders.map { ($0.name, $0.sheets.count) }) toast \(model.toast?.message ?? "-") outline \(model.outline == nil ? "nil" : "ok")"); if let p = model.projectId { do { _ = try library.outline(project: p) } catch { print(error) } }; exit(1) }
        let stamp = "왕복-\(Int(Date().timeIntervalSince1970))"
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ✓ " : "  ✗ ") + what); if !ok { failures += 1 } }

        // Save failure: a sheet switch is refused and the unsaved text stays in the buffer (never dropped).
        if model.folders.first?.sheets.count ?? 0 < 2, let pid = model.projectId, let fid = model.folders.first?.id {
            _ = try? library.createSheet(project: pid, folder: fid, text: "# 둘째 시트\n\n다른 글")
            model.reloadOutline()
        }
        let here = model.sheetId!
        let other = model.folders.first?.sheets.first { $0.id != here }?.id
        check(other != nil, "second sheet to switch to")
        var prompts = 0
        model.saveFailurePrompt = { _ in prompts += 1; return .cancel }
        model.debugSaveError = "simulated disk error"
        let unsaved = "# 저장 실패 시험\n\n아직 저장 안 된 글 \(stamp)"
        model.textDidChange(unsaved, token: model.loadToken)
        if let other { model.openSheet(other) }
        check(model.sheetId == here && model.text == unsaved && model.dirty, "switch refused on save failure, text kept")
        check(prompts == 1, "save-failure prompt shown once (\(prompts))")
        if case .failed = model.saveStatus { check(true, "footer shows the failure") } else { check(false, "footer status \(model.saveStatus)") }
        model.textDidChange(unsaved + " 더", token: model.loadToken)
        if case .failed = model.saveStatus { check(true, "failure stays visible while typing") } else { check(false, "failure hidden by typing") }
        model.textDidChange(unsaved, token: model.loadToken)
        // Retry from the prompt once the disk works again → the switch goes through.
        model.saveFailurePrompt = { _ in model.debugSaveError = nil; return .retry }
        if let other { model.openSheet(other) }
        check(model.sheetId == other && !model.dirty, "retry saved, then switched")
        check((try? library.sheetText(project: model.projectId!, sheet: here)) == unsaved, "retried text is on disk")
        model.saveFailurePrompt = nil

        // A change tagged with an older load token (a view still showing the previous sheet) is ignored.
        let before = model.text
        model.textDidChange("옛 시트의 글", token: model.loadToken - 1)
        check(model.text == before && !model.dirty, "stale-token edit ignored")

        // qa1: renumber numbers every sheet; "published up to here"; text-folder import reports skipped files.
        model.renumberEpisodes()
        let serial = model.folders.first?.sheets ?? []
        check(!serial.isEmpty && serial.enumerated().allSatisfy { $0.element.episode?.number == $0.offset + 1 }, "renumber numbered all \(serial.count) sheets")
        if let first = serial.first {
            model.markPublishedThrough(first.id)
            check(model.folders.first?.sheets.first?.episode?.status == .published, "marked published through the first sheet")
        }
        // r3: release date, next release, excluded sheets, folder stats, platform goal, Claude settings.
        if let pid = model.projectId, let folder = model.folders.first, folder.sheets.count >= 2 {
            let last = folder.sheets.last!
            model.openSheet(last.id)
            model.setEpisodeStatus(.scheduled)
            let when = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
            model.setPublishAt(when)
            let saved = model.sheet?.episode?.publishAt
            check(saved.map { abs($0 - Int64(when.timeIntervalSince1970 * 1000)) < 1000 } == true, "publish date saved (\(saved.map(String.init) ?? "nil"))")
            let next = model.nextRelease(model.folders.first!)
            check(next == saved, "next release = the scheduled date")
            check(model.episodeLabel(model.sheet!.episode!).contains(model.releaseDate(saved ?? 0, time: true)), "row label shows the date: \(model.episodeLabel(model.sheet!.episode!))")
            let firstId = folder.sheets.first!.id
            model.toggleExcluded(firstId)
            model.renumberEpisodes()
            let after = model.folders.first!.sheets
            check(after.first?.episode?.excluded == true && after.first?.episode?.number == nil, "excluded sheet has no number")
            check(after.dropFirst().first?.episode?.number == 1, "next sheet renumbered from 1")
            if let st = model.folderStats(model.folders.first!) {
                check(st.sheets == after.count && st.episodes == after.count - 1, "folder stats: \(st.sheets) sheets, \(st.episodes) episodes")
                check(st.published + st.scheduled + st.drafts == st.episodes && st.scheduled == 1, "status split adds up (\(st.published)/\(st.scheduled)/\(st.drafts))")
                check(st.counts.chars == after.reduce(0) { $0 + $1.counts.chars }, "folder total = sum of sheets (\(st.counts.chars))")
                check(st.munpia > 0 && st.novelpia > 0, "platform totals \(st.munpia) / \(st.novelpia)")
            } else { check(false, "folder stats") }
            check(try! library.stock(project: pid, folder: folder.id) == after.count - 1 - after.filter { $0.episode?.status == .published && $0.episode?.excluded != true }.count, "stock leaves out the excluded sheet")
            model.toggleExcluded(firstId)
            check(model.folders.first!.sheets.first?.episode?.excluded == false, "excluded toggles back")
            check(library.goalCount(text: "# 제목\n\n**가 나**", basis: .munpia) > 0, "munpia goal count")
            let mcp = (try? library.setMcpSettings(McpSettings(enabled: true, projects: [pid]))) ?? McpSettings()
            check(mcp.enabled && mcp.projects == [pid] && library.mcpSettings() == mcp, "Claude settings round-trip")
            _ = try? library.setMcpSettings(McpSettings())
            check(library.mcpSettings().enabled == false, "Claude settings off again")
            model.openSheet(here)
        }

        // 2026-10-24 polish: posted counts, auto-numbering, schedule default, Korean core messages, Claude config merge.
        check(model.postedCounts("# 제목\n\n**가 나**").chars == 3, "posted count leaves out the title line and marks (\(model.postedCounts("# 제목\n\n**가 나**").chars))")
        if let first = model.folders.first {
            let lastNumber = first.sheets.compactMap { $0.episode?.excluded == true ? nil : $0.episode?.number }.max() ?? 0
            if let last = first.sheets.last, last.counts.chars == 0 { model.openSheet(last.id); model.textDidChange("# 채움\n\n글", token: model.loadToken); model.flushSave() }
            model.newSheet()
            check(model.sheet?.episode?.number == lastNumber + 1 && model.sheet?.episode?.status == .draft, "new sheet numbered \(lastNumber + 1) (got \(model.sheet?.episode?.number.map(String.init) ?? "nil"))")
            let scheduled = model.folders.first!.sheets.compactMap { $0.episode?.status == .scheduled ? $0.episode?.publishAt : nil }.max()
            model.setEpisodeStatus(.scheduled)
            if let scheduled, let at = model.sheet?.episode?.publishAt {
                let a = Calendar.current.dateComponents([.hour, .minute], from: scheduled.date), b = Calendar.current.dateComponents([.hour, .minute], from: at.date)
                check(a == b && Calendar.current.isDateInTomorrow(at.date), "schedule default: tomorrow at the last slot \(b.hour ?? -1):\(b.minute ?? -1)")
            } else { check(false, "schedule default set") }
            if let id = model.sheetId { model.trashSheet(id) }
        }
        let koIo = CoreMessages.problem("Project abc was skipped and left as it is on disk: oops", locale: .ko)
        check(koIo.contains("abc") && !koIo.contains("skipped"), "core problem in Korean: \(koIo)")
        let cfgDir = FileManager.default.temporaryDirectory.appendingPathComponent("ithaca-claude-\(stamp)")
        if ProcessInfo.processInfo.environment["ITHACA_CLAUDE_CONFIG_DIR"] == nil {
            print("  · Claude config merge skipped (set ITHACA_CLAUDE_CONFIG_DIR)")
        } else {
            let file = ClaudeDesktopConfig.file
            try? FileManager.default.createDirectory(at: ClaudeDesktopConfig.folder, withIntermediateDirectories: true)
            try? #"{"mcpServers":{"other":{"command":"/bin/echo"}},"theme":"dark"}"#.write(to: file, atomically: true, encoding: .utf8)
            let backup = try? ClaudeDesktopConfig.add(server: ["command": "/x/ithaca-mcp"])
            let root = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let servers = root?["mcpServers"] as? [String: Any]
            check(servers?["other"] != nil && servers?["ithaca"] != nil && root?["theme"] as? String == "dark" && ClaudeDesktopConfig.hasIthaca(), "Claude config merged, other entries kept")
            check(backup.flatMap { $0 }.map { FileManager.default.fileExists(atPath: ClaudeDesktopConfig.folder.appendingPathComponent($0).path) } == true, "Claude config backed up first")
            try? "{not json".write(to: file, atomically: true, encoding: .utf8)
            var refused = false
            do { try ClaudeDesktopConfig.add(server: [:]) } catch ClaudeDesktopConfig.Failure.invalidJSON { refused = true } catch {}
            check(refused && (try? String(contentsOf: file, encoding: .utf8)) == "{not json", "invalid config left untouched")
        }
        _ = cfgDir

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ithaca-selftest-\(stamp)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "1화\n\n첫 글".write(to: dir.appendingPathComponent("1화.txt"), atomically: true, encoding: .utf8)
        try? "10화\n\n열째 글".write(to: dir.appendingPathComponent("10화.txt"), atomically: true, encoding: .utf8)
        try? Data([0xff, 0xd8]).write(to: dir.appendingPathComponent("표지.jpg"))
        var report: Result<ImportReport, Error>?
        Task { @MainActor in
            do { report = .success(try await library.importTextFolder(path: dir.path, title: "Selftest import", language: nil)) } catch { report = .failure(error) }
        }
        while report == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if case .success(let r)? = report { check(r.sheets == 2 && r.skipped.count == 1, "text folder: \(r.sheets) sheets, skipped \(r.skipped)") }
        else { check(false, "text folder import: \(String(describing: report))") }
        if let p = library.projects().first(where: { $0.title == "Selftest import" }) { try? library.deleteProject(id: p.id) }
        try? FileManager.default.removeItem(at: dir)

        model.openSheet(here)
        model.textDidChange("# 왕복 시험\n\n한글 문장 \(stamp)", token: model.loadToken)
        model.flushSave()
        check(model.saveStatus == .saved, "saved \(stamp)")
        print(failures == 0 ? "✓ saved \(stamp) — run --selftest again to verify" : "✗ \(failures) failed (status \(model.saveStatus))")
        AppEnvironment.defaults.set(stamp, forKey: "ithaca.selftest.marker")
        exit(failures == 0 ? 0 : 1)
    }
}

enum AppEnvironment {
    /// `--library <path>` or ITHACA_LIBRARY_PATH: a test library, so automated runs never touch the real one.
    static let libraryOverride: String? = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--library"), i + 1 < args.count { return args[i + 1] }
        return ProcessInfo.processInfo.environment["ITHACA_LIBRARY_PATH"].flatMap { $0.isEmpty ? nil : $0 }
    }()

    static let libraryURL: URL = libraryOverride.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ithaca", isDirectory: true).appendingPathComponent("Library", isDirectory: true)

    /// ITHACA_DEFAULTS_SUITE: preferences (and the device id) for test runs, kept apart from the real app's.
    nonisolated(unsafe) static let defaults: UserDefaults = ProcessInfo.processInfo.environment["ITHACA_DEFAULTS_SUITE"]
        .flatMap { $0.isEmpty ? nil : UserDefaults(suiteName: $0) } ?? .standard

    static var isTestLibrary: Bool { libraryOverride != nil || defaults != .standard }
    /// ITHACA_DEFAULTS_SUITE is set: nothing may land in the real app's defaults domain (window frames, Sparkle, restoration).
    static let isolatedDefaults = !(ProcessInfo.processInfo.environment["ITHACA_DEFAULTS_SUITE"] ?? "").isEmpty

    /// One per install (ADR-0008 §6), kept in UserDefaults and handed to the core on open.
    static let deviceId: String = {
        if let id = AppEnvironment.defaults.string(forKey: "ithaca.deviceId") { return id }
        let id = UUID().uuidString.lowercased()
        AppEnvironment.defaults.set(id, forKey: "ithaca.deviceId")
        return id
    }()

    static let deviceName = Host.current().localizedName ?? "Mac"
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"

    static var useMock: Bool {
        CommandLine.arguments.contains("--mock") || ProcessInfo.processInfo.environment["ITHACA_MOCK"] == "1"
    }

    /// The core library, or why it couldn't be opened. Never falls back to the in-memory mock: edits there would vanish.
    /// The mock only on request (`--mock`).
    @MainActor static func makeLibrary() -> (LibraryAPI?, String?) {
        if useMock { return (MockLibrary(seeded: ProcessInfo.processInfo.environment["ITHACA_EMPTY"] != "1"), nil) }
        do {
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            return (try CoreLibrary(path: libraryURL.path(percentEncoded: false), deviceId: deviceId), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

/// Owns the model once the library is open; until then the window shows why it isn't (LibraryErrorView).
@MainActor
@Observable
final class AppHost {
    private(set) var model: AppModel?
    private(set) var openError: String?
    @ObservationIgnored let menu = MenuState()

    init() { open() }

    func open() {
        let (library, error) = AppEnvironment.makeLibrary()
        if let library {
            let m = AppModel(library: library, defaults: AppEnvironment.defaults, menu: menu)
            model = m
            openError = nil
            AppDelegate.model = m
        } else {
            openError = error ?? "?"
            menu.locale = locale
        }
    }

    var locale: L10nLocale { model?.locale ?? AppModel.locale(defaults: AppEnvironment.defaults) }
    func t(_ key: L10nKey, _ args: [String: String] = [:]) -> String { L10n.string(key, locale: locale, args) }
}

/// The library folder exists but couldn't be opened: say so, and don't let anyone write into a stand-in.
struct LibraryErrorView: View {
    let host: AppHost

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s200) {
            HStack(spacing: T.Space.s150) {
                Icon(.warning, size: T.Size.iconLg, color: .stateDanger)
                Text(host.t(.libraryOpenFailedTitle)).textStyle(.title)
            }
            Text(host.openError ?? "").textStyle(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(AppEnvironment.libraryURL.path(percentEncoded: false)).textStyle(.caption).foregroundStyle(Color.inkSecondary).textSelection(.enabled)
            Text(host.t(.libraryOpenFailedBody)).textStyle(.body).foregroundStyle(Color.inkSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: T.Space.s100) {
                KitButton(host.t(.backupReveal), icon: .folderOpen) {
                    let url = AppEnvironment.libraryURL
                    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent())
                    }
                }
                KitButton(host.t(.actionRetry), icon: .restore, variant: .primary) {
                    host.open()
                    if let m = host.model { AppDelegate.didOpen(m) }
                }
            }
        }
        .padding(T.Space.s600)
        .frame(maxWidth: T.Layout.Pane.dialogDefault, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceCanvas)
        .foregroundStyle(Color.inkPrimary)
    }
}

struct IthacaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var updater = UpdaterViewModel()
    @State private var host = AppHost()

    var body: some Scene {
        Window(host.t(.appName) + (AppEnvironment.isTestLibrary ? " — TEST LIBRARY" : ""), id: "main") {
            Group {
                if let model = host.model {
                    ShellView().environment(model)
                } else {
                    LibraryErrorView(host: host)
                }
            }
            .modifier(ReopenWindowHook())
            .defaultAppStorage(AppEnvironment.defaults)
            .environment(\.locale, Locale(identifier: host.locale.rawValue))
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            UpdateCommands(updater: updater, locale: host.locale)
            IthacaCommands(host: host, menu: host.menu)
        }

        Settings {
            Group {
                if let model = host.model {
                    SettingsView(updater: updater).environment(model)
                } else {
                    LibraryErrorView(host: host)
                }
            }
            .defaultAppStorage(AppEnvironment.defaults)
            .environment(\.locale, Locale(identifier: host.locale.rawValue))
        }
    }
}

/// Keeps a way to bring the main window back (quit cancelled after its window closed: the unsaved text lives on).
private struct ReopenWindowHook: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { AppDelegate.reopenMainWindow = { openWindow(id: "main") } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    static var reopenMainWindow: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppEnvironment.isolatedDefaults {
            // Test runs share the bundle id with the real app: keep window frames and restoration state out of its domain.
            NSWindow.allowsAutomaticWindowTabbing = false
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didUpdateNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                    let id = (n.object as? NSWindow).map(ObjectIdentifier.init)
                    MainActor.assumeIsolated { NSApp.windows.filter { ObjectIdentifier($0) == id }.forEach(Self.isolate) }
                }
            }
        }
        // ⌘Q while a sheet (the first-run welcome dialog…) is up: AppKit routes the key to the sheet, which can't quit.
        // Close the sheet and quit; applicationShouldTerminate still guards unsaved text.
        quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "q",
                  NSApp.windows.contains(where: { $0.attachedSheet != nil }) else { return event }
            MainActor.assumeIsolated { Self.quitClosingSheets() }
            return nil
        }
    }

    private var quitMonitor: Any?

    /// Quit Apple event (Dock → Quit, logout, `osascript … to quit`): same path as ⌘Q.
    @objc func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        Self.quitClosingSheets()
    }

    /// Dismiss any sheet first (SwiftUI refuses to quit under one it can't close), then quit normally:
    /// applicationShouldTerminate still guards unsaved text.
    static func quitClosingSheets() {
        let hadSheet = model?.overlay != nil || NSApp.windows.contains { $0.attachedSheet != nil }
        if let model, model.overlay != nil { model.overlay = nil }
        for w in NSApp.windows { if let sheet = w.attachedSheet { w.endSheet(sheet) } }
        if hadSheet {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }

    private static func isolate(_ w: NSWindow) {
        if !w.frameAutosaveName.isEmpty { w.setFrameAutosaveName("") }
        if w.isRestorable { w.isRestorable = false }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppEnvironment.isolatedDefaults { NSApp.windows.forEach(Self.isolate) }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuitEvent(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        startWindowSnapshots()
        // No model = the library didn't open; the window shows LibraryErrorView and "Try again" calls didOpen.
        guard let model = Self.model else { return }
        Self.didOpen(model)
    }

    /// After the library opened (at launch, or from LibraryErrorView's "Try again").
    static func didOpen(_ model: AppModel) {
        model.applyTheme()
        model.runAutoBackupIfDue()
        if let from = model.info.migratedFrom {
            model.showToast(Toast(message: model.t(.libraryMigrated, ["from": from, "path": model.info.backupPath ?? ""]), sticky: true))
        }
        // First launch only: an empty, writable library with nothing skipped → the welcome dialog (start fresh, or import).
        // It can be closed; afterwards the empty editor offers the same actions.
        if model.projects.isEmpty && !model.readOnly && model.info.problems.isEmpty,
           !AppEnvironment.defaults.bool(forKey: "ithaca.welcomeShown") {
            AppEnvironment.defaults.set(true, forKey: "ithaca.welcomeShown")
            model.overlay = .newProject(firstRun: true)
        }
        // Sparkle can't replace an app running from a translocated (quarantined, unmoved) copy.
        if Bundle.main.bundlePath.contains("/AppTranslocation/"), !AppEnvironment.defaults.bool(forKey: "ithaca.translocationNoticeShown") {
            AppEnvironment.defaults.set(true, forKey: "ithaca.translocationNoticeShown")
            let alert = NSAlert()
            alert.messageText = model.t(.appMoveToApplications)
            alert.informativeText = model.t(.appMoveToApplicationsHint)
            alert.runModal()
        }
    }

    /// ITHACA_WINDOW_SNAPSHOT=<dir>: every 2 s, write each visible window of the running app to <dir>/window-N.png
    /// (no screen-recording permission needed). For QA of the real app, not just `--snapshot` scenes.
    private var snapshotTimer: Timer?
    func startWindowSnapshots() {
        guard let dir = ProcessInfo.processInfo.environment["ITHACA_WINDOW_SNAPSHOT"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("window-\(i).png"))
                }
            }
        }
    }

    /// Quit only once the open sheet is saved, or the writer chose (twice) to quit without it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A sheet (welcome dialog that can't be dismissed interactively, export, history) must not hold up the quit.
        if let model = Self.model, model.overlay != nil, model.busy == nil { model.overlay = nil }
        for w in NSApp.windows { if let sheet = w.attachedSheet { w.endSheet(sheet) } }
        guard let model = Self.model, !model.ensureSaved(quitting: true) else { return .terminateNow }
        // Closing the last window started this quit; bring the window (and the unsaved text) back.
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { Self.reopenMainWindow?() }
        return .terminateCancel
    }

    func applicationWillResignActive(_ notification: Notification) {
        Self.model?.flushSave()
        Self.model?.runAutoBackupIfDue()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Menu bar from the same command list as the palette (app-shell spec, platform conventions).
struct IthacaCommands: Commands {
    let host: AppHost
    @ObservedObject var menu: MenuState

    private func t(_ k: L10nKey) -> String { L10n.string(k, locale: menu.locale) }
    /// Menu actions do nothing while the library isn't open (LibraryErrorView) — no stand-in library to write into.
    private func go(_ f: @escaping (AppModel) -> Void) -> () -> Void { { if let m = host.model { f(m) } } }

    var body: some Commands {
        // Our own Quit: SwiftUI cancels a quit while a sheet that can't be dismissed (the first-run welcome) is up.
        CommandGroup(replacing: .appTermination) {
            Button(t(.menuQuit)) { AppDelegate.quitClosingSheets() }.keyboardShortcut("q")
        }
        CommandGroup(replacing: .newItem) {
            Button(t(.sheetNew), action: go { model in AppCommand.newSheet.run(model) }).keyboardShortcut("n").disabled(!menu.hasProject || menu.readOnly)
            Button(t(.libraryNewProject) + "…", action: go { model in AppCommand.newProject.run(model) }).keyboardShortcut("n", modifiers: [.command, .shift]).disabled(menu.readOnly)
            Divider()
            Button(t(.exportTitle) + "…", action: go { model in AppCommand.export.run(model) }).keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!menu.hasProject)
            Button(t(.importWeb) + "…", action: go { model in AppCommand.importWeb.run(model) }).disabled(menu.readOnly)
            Button(t(.importTextFolder) + "…", action: go { model in model.importTextFolder() }).disabled(menu.readOnly)
        }
        CommandGroup(after: .saveItem) {
            // Saving is automatic; ⌘S saves right away instead of beeping.
            Button(t(.menuSaveNow), action: go { model in model.flushSave() }).keyboardShortcut("s").disabled(!menu.hasSheet || menu.readOnly)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(t(.menuFindInSheet), action: go { model in model.editor?.showFindBar() }).keyboardShortcut("f").disabled(!menu.hasSheet)
            Button(t(.menuFindNext), action: go { model in model.editor?.findNext(true) }).keyboardShortcut("g").disabled(!menu.hasSheet)
            Button(t(.menuFindPrevious), action: go { model in model.editor?.findNext(false) }).keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!menu.hasSheet)
            Button(t(.searchTitle) + "…", action: go { model in AppCommand.search.run(model) }).keyboardShortcut("f", modifiers: [.command, .shift])
        }
        // The system Format menu (fonts, rich-text bold) does nothing in a plain-text manuscript: Markdown marks instead.
        CommandGroup(replacing: .textFormatting) {
            let off = !menu.hasSheet || menu.readOnly
            Button(t(.shortcutsBold), action: go { model in model.editor?.format(.bold) }).keyboardShortcut("b").disabled(off)
            Button(t(.shortcutsItalic), action: go { model in model.editor?.format(.italic) }).keyboardShortcut("i").disabled(off)
            Button(t(.formatStrike), action: go { model in model.editor?.format(.strike) }).keyboardShortcut("x", modifiers: [.command, .shift]).disabled(off)
            Divider()
            Button(t(.formatHeading1), action: go { model in model.editor?.format(.heading(1)) }).keyboardShortcut("1", modifiers: [.command, .option]).disabled(off)
            Button(t(.formatHeading2), action: go { model in model.editor?.format(.heading(2)) }).keyboardShortcut("2", modifiers: [.command, .option]).disabled(off)
            Button(t(.formatHeading3), action: go { model in model.editor?.format(.heading(3)) }).keyboardShortcut("3", modifiers: [.command, .option]).disabled(off)
            Button(t(.formatBody), action: go { model in model.editor?.format(.body) }).keyboardShortcut("0", modifiers: [.command, .option]).disabled(off)
            Button(t(.formatQuote), action: go { model in model.editor?.format(.quote) }).keyboardShortcut("'", modifiers: [.command, .option]).disabled(off)
            Divider()
            Button(t(.formatSceneBreak), action: go { model in model.editor?.format(.sceneBreak) }).keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(off)
            Button(t(.formatSymbols), action: go { model in model.editor?.showSymbols() }).keyboardShortcut("/").disabled(off)
            Menu(t(.formatSymbols).replacingOccurrences(of: "…", with: "")) {
                ForEach(Symbols.all.indices, id: \.self) { i in
                    let s = Symbols.all[i]
                    Button(s.menuTitle(t(s.name)), action: go { model in model.editor?.insert(s.text, wrapping: s.close) })
                }
            }
            .disabled(off)
            Divider()
            Button(t(.menuTextBigger), action: go { model in model.stepTextSize(1) }).keyboardShortcut("+")
            Button(t(.menuTextSmaller), action: go { model in model.stepTextSize(-1) }).keyboardShortcut("-")
            Button(t(.menuTextReset), action: go { model in model.stepTextSize(0) }).keyboardShortcut("0")
        }
        CommandGroup(before: .toolbar) {
            Button(t(.shortcutsShowLibrary), action: go { model in
                model.focusMode = false
                if !model.dockedLibrary { model.libraryOverlay.toggle() }
            }).keyboardShortcut("1")
            Button(t(.shortcutsShowList), action: go { model in
                model.focusMode = false
                if !model.dockedList { model.libraryOverlay.toggle() }
            }).keyboardShortcut("2")
            Button(t(.shortcutsEditorOnly), action: go { model in model.toggleFocus() }).keyboardShortcut("3")
            Divider()
            Button(t(.inspectorTitle), action: go { model in model.toggleInspector() }).keyboardShortcut("i", modifiers: [.command, .option])
            Button(t(.focusTitle), action: go { model in model.toggleFocus() }).keyboardShortcut("d", modifiers: [.command, .shift])
            Button(t(.paletteTitle), action: go { model in model.show(.palette(search: false)) }).keyboardShortcut("k")
            Divider()
        }
        CommandMenu(t(.shortcutsGroupSheet)) {
            Button(t(.sheetPrevious), action: go { model in model.openAdjacentSheet(-1) }).keyboardShortcut("[").disabled(!menu.hasSheet)
            Button(t(.sheetNext), action: go { model in model.openAdjacentSheet(1) }).keyboardShortcut("]").disabled(!menu.hasSheet)
            Divider()
            Button(t(.sheetMoveUp), action: go { model in AppCommand.moveUp.run(model) }).keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(!menu.hasSheet || menu.readOnly)
            Button(t(.sheetMoveDown), action: go { model in AppCommand.moveDown.run(model) }).keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(!menu.hasSheet || menu.readOnly)
            Divider()
            Button(t(.sheetCopyForPaste), action: go { model in AppCommand.copyForPaste.run(model) }).keyboardShortcut("c", modifiers: [.command, .option]).disabled(!menu.hasSheet)
            Divider()
            Button(t(.episodePublishedThrough), action: go { model in model.markPublishedThrough() }).disabled(!menu.hasSheet || menu.readOnly)
            Button(t(.episodeRenumber), action: go { model in model.renumberEpisodes() }).disabled(!menu.hasProject || menu.readOnly)
            Divider()
            Button(t(.historyTitle) + "…", action: go { model in AppCommand.history.run(model) }).keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!menu.hasSheet)
            Button(t(.paletteSheetInfo), action: go { model in AppCommand.sheetInfo.run(model) }).disabled(!menu.hasSheet)
            Button(t(.projectSettingsTitle) + "…", action: go { model in AppCommand.projectSettings.run(model) }).disabled(!menu.hasProject)
            Divider()
            Button(t(.trashTitle), action: go { model in AppCommand.showTrash.run(model) }).disabled(!menu.hasProject)
            Button(t(.sheetTrash), action: go { model in AppCommand.trashSheet.run(model) }).keyboardShortcut(.delete, modifiers: .command).disabled(!menu.hasSheet || menu.readOnly)
        }
    }
}
