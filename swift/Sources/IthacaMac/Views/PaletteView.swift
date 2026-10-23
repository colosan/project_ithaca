// Command palette (⌘K) and search (⌘⇧F) in one box: recent sheets / every match, folders, projects, commands.
import AppKit
import IthacaDesign
import SwiftUI

/// The one command list the menu bar and the palette share (app-shell spec: same source).
enum AppCommand: CaseIterable {
    case newSheet, newProject, search, focus, sheetInfo, history, export, projectSettings, settings, moveUp, moveDown, showTrash, trashSheet, importWeb

    var label: L10nKey {
        switch self {
        case .newSheet: .sheetNew
        case .newProject: .libraryNewProject
        case .search: .searchTitle
        case .focus: .focusTitle
        case .sheetInfo: .paletteSheetInfo
        case .history: .historyTitle
        case .export: .exportTitle
        case .projectSettings: .projectSettingsTitle
        case .settings: .prefsTitle
        case .moveUp: .sheetMoveUp
        case .moveDown: .sheetMoveDown
        case .showTrash: .trashTitle
        case .trashSheet: .sheetTrash
        case .importWeb: .importWeb
        }
    }

    var icon: IthacaIcon {
        switch self {
        case .newSheet: .add
        case .newProject: .folder
        case .search: .search
        case .focus: .focus
        case .sheetInfo: .stats
        case .history: .history
        case .export: .export
        case .projectSettings, .settings: .settings
        case .moveUp: .collapsed
        case .moveDown: .expanded
        case .showTrash: .trash
        case .trashSheet: .delete
        case .importWeb: .backup
        }
    }

    /// Same rule as the menu bar's disabled items: sheet commands need an open sheet, project commands a project.
    @MainActor func available(_ m: AppModel) -> Bool {
        // Read-only library: nothing that writes.
        if m.readOnly, [.newSheet, .newProject, .moveUp, .moveDown, .trashSheet, .importWeb].contains(self) { return false }
        return switch self {
        case .sheetInfo, .history, .moveUp, .moveDown, .trashSheet: m.sheetId != nil
        case .export, .projectSettings, .showTrash, .newSheet: m.projectId != nil
        default: true
        }
    }

    @MainActor func run(_ m: AppModel) {
        switch self {
        case .newSheet: m.newSheet()
        case .newProject: m.show(.newProject(firstRun: false))
        case .search: m.overlay = .palette(search: true)
        case .focus: m.toggleFocus()
        case .sheetInfo: m.inspectorOpen = true; AppEnvironment.defaults.set(InspectorTab.info.rawValue, forKey: "ithaca.inspectorTab")
        case .history: if m.sheetId != nil { m.show(.history) }
        case .export: if m.projectId != nil { m.show(.export) }
        case .projectSettings: if m.projectId != nil { m.show(.projectSettings) }
        case .settings: openSettingsWindow()
        case .moveUp: m.moveSheet(-1)
        case .moveDown: m.moveSheet(1)
        case .showTrash: m.showingTrash = true; if !m.dockedList { m.libraryOverlay = true }
        case .trashSheet: m.trashSheet()
        case .importWeb: m.importWebBackup()
        }
    }
}

@MainActor func openSettingsWindow() {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}

struct PaletteView: View {
    @Environment(AppModel.self) private var model
    let searchMode: Bool
    let compact: Bool
    @State private var query: String

    init(searchMode: Bool, compact: Bool, initialQuery: String = "") {
        self.searchMode = searchMode
        self.compact = compact
        _query = State(initialValue: initialQuery)
    }
    @State private var index = 0
    @FocusState private var focused: Bool

    struct Hit: Identifiable {
        enum Group { case sheet, folder, project, command }
        let id: String
        let group: Group
        let icon: IthacaIcon
        let title: String
        var detail: AttributedString?
        var meta: String?
        let run: () -> Void
    }

    var body: some View {
        let hits = self.hits
        VStack(spacing: 0) {
            HStack(spacing: T.Space.s100) {
                Icon(.search, size: T.Size.iconSm, color: .inkTertiary)
                TextField(searchMode ? model.t(.searchPlaceholder) : model.t(.palettePlaceholder), text: $query)
                    .textFieldStyle(.plain)
                    .textStyle(.body)
                    .focused($focused)
                    .onSubmit { if hits.indices.contains(index) { hits[index].run() } }
                    .onKeyPress(.downArrow) { index = min(hits.count - 1, index + 1); return .handled }
                    .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
                    .onKeyPress(.tab) { index = min(hits.count - 1, index + 1); return .handled }
                    .onExitCommand { model.overlay = nil }
            }
            .padding(T.Space.s150)
            .hairline(.bottom)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in
                            if i == 0 || hits[i - 1].group != h.group {
                                Caption(heading(h.group))
                                    .padding(.horizontal, T.Space.s100)
                                    .padding(.top, T.Space.s100)
                                    .padding(.bottom, T.Space.s50)
                            }
                            row(h, selected: i == index).id(i).onHover { if $0 { index = i } }
                        }
                        if hits.isEmpty {
                            Caption(model.t(.paletteNone, ["query": query])).frame(maxWidth: .infinity).padding(T.Space.s300)
                        }
                    }
                    .padding(T.Space.s100)
                }
                .onChange(of: index) { _, i in proxy.scrollTo(i) }
            }
            if !compact {
                HStack(spacing: T.Space.s200) {
                    Caption(model.t(.paletteHintOpen))
                    Caption(model.t(.paletteHintClose))
                    Spacer()
                }
                .padding(.horizontal, T.Space.s200)
                .padding(.vertical, T.Space.s100)
                .hairline(.top)
            }
        }
        .frame(width: compact ? nil : T.Layout.Pane.dialogDefault)
        .frame(maxHeight: compact ? .infinity : 460)
        .background(Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 0 : T.Radius.sheet))
        .overlay { if !compact { RoundedRectangle(cornerRadius: T.Radius.sheet).strokeBorder(Color.lineSubtle) } }
        .tokenShadow(T.Shadow.dialog)
        .padding(.top, compact ? 0 : T.Space.s800)
        .padding(.horizontal, compact ? 0 : T.Space.s200)
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
    }

    private func heading(_ g: Hit.Group) -> String {
        switch g {
        case .sheet: query.isEmpty ? model.t(.paletteRecent) : model.t(.paletteSheets)
        case .folder: model.t(.paletteFolders)
        case .project: model.t(.paletteProjects)
        case .command: model.t(.paletteCommands)
        }
    }

    private func row(_ h: Hit, selected: Bool) -> some View {
        HStack(spacing: T.Space.s150) {
            Icon(h.icon, size: T.Size.iconSm, color: .inkTertiary)
            VStack(alignment: .leading, spacing: 0) {
                Text(h.title).textStyle(.body).lineLimit(1)
                if let d = h.detail { Text(d).textStyle(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let m = h.meta { Caption(m) }
        }
        .padding(.horizontal, T.Space.s100)
        .padding(.vertical, T.Space.s50)
        .frame(minHeight: T.Size.controlMd)
        .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(selected ? Color.surfaceSelected : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: h.run)
    }

    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let lower = q.lowercased()
        let m = model
        func open(_ sheet: String, _ range: NSRange? = nil, project: String? = nil) -> () -> Void {
            {
                m.overlay = nil; m.showingTrash = false; m.libraryOverlay = false
                // A hit in another project (searchAll): switch to it first.
                if let project, project != m.projectId { m.selectProject(project); guard m.projectId == project else { return } }
                m.openSheet(sheet, at: range); m.editor?.focus()
            }
        }
        var out: [Hit] = []
        let all = m.folders.flatMap { f in f.sheets.map { (f, $0) } }
        if q.isEmpty {
            for (f, s) in all.sorted(by: { $0.1.modified > $1.1.modified }).prefix(searchMode ? 0 : 3) {
                out.append(Hit(id: s.id, group: .sheet, icon: .sheet, title: s.title.isEmpty ? m.t(.sheetUntitled) : s.title, meta: f.name, run: open(s.id)))
            }
        } else {
            // Every match is its own result (core search, up to 5 per sheet), titles first.
            var seen = Set<String>()
            for (f, s) in all where s.title.lowercased().contains(lower) || f.name.lowercased() == lower {
                seen.insert(s.id)
                out.append(Hit(id: "t:" + s.id, group: .sheet, icon: .sheet, title: s.title.isEmpty ? m.t(.sheetUntitled) : s.title, meta: f.name, run: open(s.id)))
            }
            // Every project, the open one first (core search_all).
            let found = m.library.searchAll(query: q, current: m.projectId)
            let counts = Dictionary(grouping: found, by: \.sheet).mapValues(\.count)
            var n: [String: Int] = [:]
            for h in found.prefix(30) {
                n[h.sheet, default: 0] += 1
                var detail = AttributedString((h.before.count > 20 ? "…" : "") + h.before.replacingOccurrences(of: "\n", with: " "))
                var match = AttributedString(h.match)
                match.backgroundColor = .accentSoft
                match.foregroundColor = .inkPrimary
                detail += match
                detail += AttributedString(h.after.replacingOccurrences(of: "\n", with: " "))
                let total = counts[h.sheet] ?? 1
                let title = (h.title.isEmpty ? m.t(.sheetUntitled) : h.title) + (total > 1 ? " (\(n[h.sheet]!)/\(total))" : "")
                let place = h.project == m.projectId ? all.first { $0.1.id == h.sheet }?.0.name : m.projects.first { $0.id == h.project }?.title
                out.append(Hit(id: h.id, group: .sheet, icon: .sheet, title: title, detail: detail, meta: place, run: open(h.sheet, NSRange(location: h.offset, length: h.length), project: h.project)))
            }
            _ = seen
            for f in m.folders where f.name.lowercased().contains(lower) {
                out.append(Hit(id: "f:" + f.id, group: .folder, icon: .folder, title: f.name, meta: m.t(.paletteFolder)) {
                    m.overlay = nil; m.selectFolder(f.id); if !m.dockedList { m.libraryOverlay = true }
                })
            }
            for p in m.projects where p.id != m.projectId && p.title.lowercased().contains(lower) {
                out.append(Hit(id: "p:" + p.id, group: .project, icon: .library, title: p.title, meta: m.t(.paletteProject)) {
                    m.overlay = nil; m.selectProject(p.id)
                })
            }
        }
        if !searchMode || !q.isEmpty {
            for c in AppCommand.allCases where c.available(m) && (q.isEmpty || m.t(c.label).lowercased().contains(lower)) {
                out.append(Hit(id: "c:\(c)", group: .command, icon: c.icon, title: m.t(c.label)) { m.overlay = nil; c.run(m) })
            }
        }
        return out
    }
}
