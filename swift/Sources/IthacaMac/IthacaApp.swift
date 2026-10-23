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
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot") {
            let dir = i + 1 < args.count ? args[i + 1] : FileManager.default.currentDirectoryPath + "/snapshots"
            MainActor.assumeIsolated { Snapshot.run(to: URL(fileURLWithPath: dir)) }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        // First run: an empty, writable library with nothing skipped → the welcome dialog (start fresh, or import).
        if model.projects.isEmpty && !model.readOnly && model.info.problems.isEmpty { model.overlay = .newProject(firstRun: true) }
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
        CommandGroup(replacing: .newItem) {
            Button(t(.sheetNew), action: go { model in AppCommand.newSheet.run(model) }).keyboardShortcut("n").disabled(!menu.hasProject)
            Button(t(.libraryNewProject) + "…", action: go { model in AppCommand.newProject.run(model) }).keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(t(.exportTitle) + "…", action: go { model in AppCommand.export.run(model) }).keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!menu.hasProject)
            Button(t(.importWeb) + "…", action: go { model in AppCommand.importWeb.run(model) })
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(t(.menuFindInSheet), action: go { model in model.editor?.showFindBar() }).keyboardShortcut("f").disabled(!menu.hasSheet)
            Button(t(.searchTitle) + "…", action: go { model in AppCommand.search.run(model) }).keyboardShortcut("f", modifiers: [.command, .shift])
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
            Button(t(.sheetMoveUp), action: go { model in AppCommand.moveUp.run(model) }).keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(!menu.hasSheet)
            Button(t(.sheetMoveDown), action: go { model in AppCommand.moveDown.run(model) }).keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(!menu.hasSheet)
            Divider()
            Button(t(.episodeRenumber), action: go { model in model.renumberEpisodes() }).disabled(!menu.hasProject)
            Divider()
            Button(t(.historyTitle) + "…", action: go { model in AppCommand.history.run(model) }).keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!menu.hasSheet)
            Button(t(.paletteSheetInfo), action: go { model in AppCommand.sheetInfo.run(model) })
            Button(t(.projectSettingsTitle) + "…", action: go { model in AppCommand.projectSettings.run(model) }).disabled(!menu.hasProject)
            Divider()
            Button(t(.trashTitle), action: go { model in AppCommand.showTrash.run(model) }).disabled(!menu.hasProject)
            Button(t(.sheetTrash), action: go { model in AppCommand.trashSheet.run(model) }).keyboardShortcut(.delete, modifiers: .command).disabled(!menu.hasSheet)
        }
    }
}
