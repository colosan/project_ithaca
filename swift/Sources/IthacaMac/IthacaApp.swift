// Ithaca for Mac (ADR-0004, 0008). One main window, native menu bar, Settings scene.
//   Ithaca                    the real library (Rust core) in ~/Library/Application Support/Ithaca/Library
//   Ithaca --mock             in-memory sample library (ITHACA_MOCK=1 too); ITHACA_EMPTY=1 starts it empty
//   Ithaca --snapshot <dir>   renders key screens to PNGs and exits (see Snapshot.swift)
import AppKit
import IthacaCore
import IthacaDesign
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
        let (library, error) = AppEnvironment.makeLibrary()
        if let error { print("✗ open failed: \(error)"); exit(1) }
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
        model.textDidChange("# 왕복 시험\n\n한글 문장 \(stamp)")
        model.flushSave()
        print(model.saveStatus == .saved ? "✓ saved \(stamp) — run --selftest again to verify" : "✗ save status \(model.saveStatus)")
        AppEnvironment.defaults.set(stamp, forKey: "ithaca.selftest.marker")
        exit(model.saveStatus == .saved ? 0 : 1)
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

    /// The core library; the in-memory mock only on request or when the folder can't be opened (said so in the UI).
    @MainActor static func makeLibrary() -> (LibraryAPI, String?) {
        if useMock { return (MockLibrary(seeded: ProcessInfo.processInfo.environment["ITHACA_EMPTY"] != "1"), nil) }
        do {
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            return (try CoreLibrary(path: libraryURL.path(percentEncoded: false), deviceId: deviceId), nil)
        } catch {
            return (MockLibrary(seeded: false), error.localizedDescription)
        }
    }
}

struct IthacaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var updater = UpdaterViewModel()
    @State private var model: AppModel

    init() {
        let (library, error) = AppEnvironment.makeLibrary()
        let m = AppModel(library: library, openError: error, defaults: AppEnvironment.defaults)
        _model = State(initialValue: m)
        AppDelegate.model = m
    }

    var body: some Scene {
        Window(model.t(.appName) + (AppEnvironment.isTestLibrary ? " — TEST LIBRARY" : ""), id: "main") {
            ShellView()
                .environment(model)
                .defaultAppStorage(AppEnvironment.defaults)
                .environment(\.locale, Locale(identifier: model.locale.rawValue))
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            UpdateCommands(updater: updater, locale: model.locale)
            IthacaCommands(model: model, menu: model.menu)
        }

        Settings {
            SettingsView(updater: updater)
                .environment(model)
                .defaultAppStorage(AppEnvironment.defaults)
                .environment(\.locale, Locale(identifier: model.locale.rawValue))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model = Self.model else { return }
        model.applyTheme()
        startWindowSnapshots()
        model.runAutoBackupIfDue()
        if let error = model.openError {
            model.showToast(Toast(message: model.t(.libraryOpenFailed, ["message": error]), sticky: true))
        } else if let from = model.info.migratedFrom {
            model.showToast(Toast(message: model.t(.libraryMigrated, ["from": from, "path": model.info.backupPath ?? ""]), sticky: true))
        }
        // First run: no projects → the welcome dialog (start fresh, or bring the web version's backup).
        if model.projects.isEmpty && !model.readOnly { model.overlay = .newProject(firstRun: true) }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.model?.flushSave()
        return .terminateNow
    }

    func applicationWillResignActive(_ notification: Notification) {
        Self.model?.flushSave()
        Self.model?.runAutoBackupIfDue()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Menu bar from the same command list as the palette (app-shell spec, platform conventions).
struct IthacaCommands: Commands {
    let model: AppModel
    @ObservedObject var menu: MenuState

    private func t(_ k: L10nKey) -> String { L10n.string(k, locale: menu.locale) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(t(.sheetNew)) { AppCommand.newSheet.run(model) }.keyboardShortcut("n").disabled(!menu.hasProject)
            Button(t(.libraryNewProject) + "…") { AppCommand.newProject.run(model) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(t(.exportTitle) + "…") { AppCommand.export.run(model) }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!menu.hasProject)
            Button(t(.importWeb) + "…") { AppCommand.importWeb.run(model) }
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(t(.menuFindInSheet)) { model.editor?.showFindBar() }.keyboardShortcut("f").disabled(!menu.hasSheet)
            Button(t(.searchTitle) + "…") { AppCommand.search.run(model) }.keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Button(t(.shortcutsShowLibrary)) {
                model.focusMode = false
                if !model.dockedLibrary { model.libraryOverlay.toggle() }
            }.keyboardShortcut("1")
            Button(t(.shortcutsShowList)) {
                model.focusMode = false
                if !model.dockedList { model.libraryOverlay.toggle() }
            }.keyboardShortcut("2")
            Button(t(.shortcutsEditorOnly)) { model.toggleFocus() }.keyboardShortcut("3")
            Divider()
            Button(t(.inspectorTitle)) { model.toggleInspector() }.keyboardShortcut("i", modifiers: [.command, .option])
            Button(t(.focusTitle)) { model.toggleFocus() }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button(t(.paletteTitle)) { model.show(.palette(search: false)) }.keyboardShortcut("k")
            Divider()
        }
        CommandMenu(t(.shortcutsGroupSheet)) {
            Button(t(.sheetMoveUp)) { AppCommand.moveUp.run(model) }.keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(!menu.hasSheet)
            Button(t(.sheetMoveDown)) { AppCommand.moveDown.run(model) }.keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(!menu.hasSheet)
            Divider()
            Button(t(.episodeRenumber)) { model.renumberEpisodes() }.disabled(!menu.hasProject)
            Divider()
            Button(t(.historyTitle) + "…") { AppCommand.history.run(model) }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!menu.hasSheet)
            Button(t(.paletteSheetInfo)) { AppCommand.sheetInfo.run(model) }
            Button(t(.projectSettingsTitle) + "…") { AppCommand.projectSettings.run(model) }.disabled(!menu.hasProject)
            Divider()
            Button(t(.trashTitle)) { AppCommand.showTrash.run(model) }.disabled(!menu.hasProject)
            Button(t(.sheetTrash)) { AppCommand.trashSheet.run(model) }.keyboardShortcut(.delete, modifiers: .command).disabled(!menu.hasSheet)
        }
    }
}
