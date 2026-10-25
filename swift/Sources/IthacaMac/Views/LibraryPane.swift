// Library pane: projects → folders (open project only), new folder, trash, new project, settings.
// Folders and projects are managed here only: rename in place (double-click a folder, or the context menu), delete, new.
import IthacaDesign
import SwiftUI

struct LibraryPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: String?  // folder id being renamed, "new", or "project:<id>"
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    /// The open project's folders folded away (clicking the open project toggles it).
    @AppStorage("ithaca.libraryFolded") private var folded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption(model.t(.libraryTitle))
                .textStyle(.label)
                .padding(.horizontal, T.Space.s200)
                .padding(.top, T.Space.s200)
                .padding(.bottom, T.Space.s100)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.projects) { p in projectRows(p) }
                    Spacer().frame(height: lastExpanded ? 0 : T.Space.s150)
                    LibraryRow(active: model.showingTrash, muted: true) {
                        model.showingTrash = true
                        // Like a folder: the overlay closes when the list it fills is docked beside it.
                        if model.dockedList { model.libraryOverlay = false }
                    } content: {
                        Icon(.trash, size: T.Size.iconSm)
                        Text(model.t(.trashTitle))
                        Spacer(minLength: 0)
                        if !model.trash.isEmpty { Caption(model.number(model.trash.count)) }
                    }
                }
                .padding(.horizontal, T.Space.s100)
            }
            if model.info.inMemory {
                HStack(alignment: .top, spacing: T.Space.s100) {
                    Icon(.warning, size: T.Size.iconSm)
                    Text(model.t(.libraryInMemory)).textStyle(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.stateWarning)
                .padding(T.Space.s150)
                .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.accentSoft))
                .padding(.horizontal, T.Space.s100)
                .padding(.bottom, T.Space.s100)
            }
            HStack(spacing: T.Space.s100) {
                if !model.readOnly {
                    KitButton(model.t(.libraryNewProject), icon: .add, variant: .ghost) { model.show(.newProject(firstRun: false)) }
                }
                Spacer(minLength: 0)
                SettingsLink {
                    Icon(.settings, size: T.Size.iconMd, color: .inkSecondary).frame(width: T.Size.controlSm, height: T.Size.controlSm)
                }
                .buttonStyle(.plain)
                .help(model.t(.prefsTitle))
            }
            .padding(T.Space.s100)
            .hairline(.top)
        }
        .frame(maxHeight: .infinity)
        .background(Color.surfaceSidebar)
        .hairline(.trailing)
    }

    /// The last project is unfolded: its own bottom room already separates it from the trash.
    private var lastExpanded: Bool { !folded && model.projects.last?.id == model.projectId }

    @ViewBuilder
    private func projectRows(_ p: ProjectSummary) -> some View {
        let open = p.id == model.projectId
        let expanded = open && !folded
        VStack(alignment: .leading, spacing: 0) {
            if editing == "project:" + p.id { field(indent: false) } else {
            LibraryRow(active: false, muted: !open) {
                if open { folded.toggle() } else { folded = false; model.selectProject(p.id) }
            } content: {
                Icon(expanded ? .expanded : .collapsed, size: T.Size.iconSm, color: .inkTertiary)
                Text(p.title).textStyle(.label, weight: T.Typography.heading.weight).lineLimit(1)
                Spacer(minLength: 0)
            }
            .help(p.title)
            .contextMenu {
                if !model.readOnly {
                    Button(model.t(.folderRename)) { startEditing("project:" + p.id, p.title) }
                    if open { Button(model.t(.folderNew)) { startEditing("new", "") } }
                }
                // Settings belong to the open project: only switch when the switch happened (a failed save cancels it).
                Button(model.t(.projectSettingsTitle) + "…") {
                    if !open { model.selectProject(p.id) }
                    if model.projectId == p.id { model.show(.projectSettings) }
                }
                if !model.readOnly {
                    Divider()
                    Button(model.t(.projectSettingsDelete) + "…", role: .destructive) { model.deleteProject(p.id) }
                }
            }
            }
            if expanded {
                ForEach(model.folders) { f in
                    if editing == f.id { field() } else { FolderRow(folder: f, rename: { startEditing(f.id, f.name) }, newFolder: { startEditing("new", "") }) }
                }
                if model.readOnly {
                    // Read-only library: no new folder.
                } else if editing == "new" { field() } else {
                    LibraryRow(active: false, muted: true, indent: true) {
                        startEditing("new", "")
                    } content: {
                        Icon(.add, size: T.Size.iconSm)
                        Text(model.t(.folderNew)).textStyle(.caption)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        // Room below an unfolded project only: folded projects stack like rows.
        .padding(.bottom, expanded ? T.Space.s150 : 0)
    }

    private func startEditing(_ id: String, _ text: String) {
        draft = text
        editing = id
    }

    private func field(indent: Bool = true) -> some View {
        let project = editing?.hasPrefix("project:") == true
        return TextField(project ? model.t(.newProjectTitlePlaceholder) : model.t(.folderNamePlaceholder), text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onSubmit(commit)
            .onExitCommand { editing = nil }
            .onChange(of: fieldFocused) { _, f in if !f { commit() } }
            // Focus once the field exists: set in the same tick as `editing` it was dropped (a context menu was
            // still closing), and the field then never committed or closed when you clicked elsewhere.
            .onAppear { DispatchQueue.main.async { fieldFocused = true } }
            .padding(.leading, indent ? T.Space.s300 : T.Space.s100)
            .padding(.trailing, T.Space.s100)
            .padding(.vertical, T.Space.s25)
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        if let e = editing, !name.isEmpty {
            if e == "new" { model.createFolder(name) }
            else if e.hasPrefix("project:") { model.renameProject(String(e.dropFirst("project:".count)), name) }
            else if model.folders.first(where: { $0.id == e })?.name != name { model.renameFolder(e, name) }
        }
        editing = nil
    }
}

/// A folder of the open project: click to show its sheets, double-click to rename, drop a sheet to move it here.
private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: FolderInfo
    let rename: () -> Void
    let newFolder: () -> Void
    @State private var dropTarget = false

    var body: some View {
        let f = folder
        let active = f.id == model.folderId && !model.showingTrash
        LibraryRow(active: active || dropTarget, indent: true) {
            model.selectFolder(f.id)
            // When the sheet list lives in the same overlay, keep it open so a sheet can be picked.
            if model.dockedList { model.libraryOverlay = false }
        } content: {
            Icon(.folder, size: T.Size.iconSm, color: active || dropTarget ? .accentPrimary : .inkTertiary)
            Text(f.name).lineLimit(1)
            Spacer(minLength: 0)
            Caption(model.number(f.sheets.count))
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !model.readOnly { rename() } })
        .help(f.name)
        .contextMenu {
            if !model.readOnly { Button(model.t(.sheetNew)) { model.newSheet(in: f.id) } }
            Button(model.t(.folderInfo)) { model.showFolderInfo(f.id) }
            if !model.readOnly {
                Divider()
                Button(model.t(.folderRename)) { rename() }
                Button(model.t(.folderNew)) { newFolder() }
                // The last folder can't be deleted (the core refuses; trash spec).
                if model.folders.count > 1 {
                    Divider()
                    Button(model.t(.folderDelete) + "…", role: .destructive) { model.deleteFolder(f.id) }
                }
            }
        }
        .dropDestination(for: SheetDrag.self) { items, _ in
            guard !model.readOnly, let id = items.first?.id else { return false }
            model.move(sheet: id, to: f.id, before: nil)
            return true
        } isTargeted: { dropTarget = $0 && !model.readOnly }
    }
}

struct LibraryRow<Content: View>: View {
    var active = false
    var muted = false
    var indent = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        HStack(spacing: T.Space.s100, content: content)
            .textStyle(.body)
            .foregroundStyle(muted ? Color.inkTertiary : active ? .inkPrimary : .inkSecondary)
            .padding(.leading, indent ? T.Space.s300 : T.Space.s100)
            .padding(.trailing, T.Space.s100)
            .frame(minHeight: T.Size.controlMd)
            .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(active ? Color.surfaceSelected : hover ? .surfaceList : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}
