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
        func settings(_ tab: SettingsSection) -> Scene {
            Scene(name: "settings-\(tab.rawValue)", size: CGSize(width: 640, height: 560),
                  setup: { _, d in d.set(tab.rawValue, forKey: "ithaca.settingsTab") },
                  view: { _ in AnyView(SettingsView(updater: updater)) })
        }
        func claude(_ locale: LocalePref) -> Scene {
            Scene(name: "settings-claude-on-\(locale.rawValue)", size: CGSize(width: 640, height: 760), locale: locale,
                  setup: { m, d in
                      d.set(SettingsSection.claude.rawValue, forKey: "ithaca.settingsTab")
                      _ = try? m.library.setMcpSettings(McpSettings(enabled: true, projects: m.projects.prefix(1).map(\.id)))
                  },
                  view: { _ in AnyView(SettingsView(updater: updater)) })
        }
        return [
            Scene(name: "shell-ko-light", size: wide),
            Scene(name: "shell-ko-dark", size: wide, dark: true),
            Scene(name: "shell-en-light", size: wide, locale: .en),
            Scene(name: "shell-900", size: CGSize(width: 900, height: 700)),
            Scene(name: "shell-700-library-overlay", size: CGSize(width: 700, height: 700), setup: { m, _ in m.libraryOverlay = true }),
            Scene(name: "shell-1240-inspector-info", size: wide, setup: { m, d in m.inspectorOpen = true; d.set("info", forKey: "ithaca.inspectorTab") }),
            Scene(name: "shell-1240-inspector-reference-dark", size: wide, dark: true, setup: { m, d in m.inspectorOpen = true; d.set("reference", forKey: "ithaca.inspectorTab") }),
            Scene(name: "shell-inspector-outline-1000", size: CGSize(width: 1000, height: 700), setup: { m, d in m.inspectorOpen = true; d.set("outline", forKey: "ithaca.inspectorTab") }),
            Scene(name: "shell-focus", size: wide, setup: { m, _ in m.focusMode = true }),
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
            Scene(name: "new-project-first-run", size: CGSize(width: 560, height: 640), view: { _ in AnyView(NewProjectView(firstRun: true)) }),
            Scene(name: "new-project-en", size: CGSize(width: 560, height: 480), locale: .en, view: { _ in AnyView(NewProjectView(firstRun: false)) }),
            Scene(name: "project-settings", size: CGSize(width: 560, height: 560), view: { _ in AnyView(ProjectSettingsView()) }),
            settings(.general), settings(.editor), settings(.backup), settings(.about),
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
            Scene(name: "icons", size: CGSize(width: 720, height: 300), view: { _ in AnyView(IconSheet()) }),
        ]
    }

    private static func render(_ s: Scene, to url: URL) {
        let suite = "io.github.colosan.ithaca.snapshot"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(s.locale.rawValue, forKey: "ithaca.locale")
        let model = AppModel(library: MockLibrary(seeded: true, device: AppEnvironment.deviceName), defaults: defaults)
        s.setup(model, defaults)
        let appearance = NSAppearance(named: s.dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let root = s.view(model)
            .environment(model)
            .environment(\.locale, Locale(identifier: model.locale.rawValue))
            .defaultAppStorage(defaults)
            .frame(width: s.size.width, height: s.size.height)
            .background(Color.surfaceCanvas)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: s.size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = appearance
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: s.size)
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
