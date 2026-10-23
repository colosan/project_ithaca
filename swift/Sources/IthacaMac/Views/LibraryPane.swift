// Library pane: projects → folders (open project only), new folder, trash, new project, settings.
import IthacaDesign
import SwiftUI

struct LibraryPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: String?  // folder id being renamed, or "new"
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

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
                    LibraryRow(active: model.showingTrash, muted: true) {
                        model.showingTrash = true
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
                KitButton(model.t(.libraryNewProject), icon: .add, variant: .ghost) { model.show(.newProject(firstRun: false)) }
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

    @ViewBuilder
    private func projectRows(_ p: ProjectSummary) -> some View {
        let open = p.id == model.projectId
        VStack(alignment: .leading, spacing: 0) {
            LibraryRow(active: false, muted: !open) {
                if !open { model.selectProject(p.id) }
            } content: {
                Icon(open ? .expanded : .collapsed, size: T.Size.iconSm, color: .inkTertiary)
                Text(p.title).textStyle(.label, weight: T.Typography.heading.weight).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contextMenu {
                Button(model.t(.projectSettingsTitle)) { if !open { model.selectProject(p.id) }; model.show(.projectSettings) }
            }
            if open {
                ForEach(model.folders) { f in
                    if editing == f.id { field } else { folderRow(f) }
                }
                if editing == "new" { field } else {
                    LibraryRow(active: false, muted: true, indent: true) {
                        draft = ""; editing = "new"; fieldFocused = true
                    } content: {
                        Icon(.add, size: T.Size.iconSm)
                        Text(model.t(.folderNew)).textStyle(.caption)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.bottom, T.Space.s150)
    }

    private func folderRow(_ f: FolderInfo) -> some View {
        let active = f.id == model.folderId && !model.showingTrash
        return LibraryRow(active: active, indent: true) {
            model.selectFolder(f.id)
            // When the sheet list lives in the same overlay, keep it open so a sheet can be picked.
            if model.dockedList { model.libraryOverlay = false }
        } content: {
            Icon(.folder, size: T.Size.iconSm, color: active ? .accentPrimary : .inkTertiary)
            Text(f.name).lineLimit(1)
            Spacer(minLength: 0)
            Caption(model.number(f.sheets.count))
        }
        .contextMenu {
            Button(model.t(.folderInfo)) { model.showFolderInfo(f.id) }
            Divider()
            Button(model.t(.folderRename)) { draft = f.name; editing = f.id; fieldFocused = true }
            Button(model.t(.folderDelete), role: .destructive) { model.deleteFolder(f.id) }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            model.move(sheet: id, to: f.id, before: nil)
            return true
        }
    }

    private var field: some View {
        TextField(model.t(.folderNamePlaceholder), text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onSubmit(commit)
            .onExitCommand { editing = nil }
            .onChange(of: fieldFocused) { _, f in if !f { commit() } }
            .padding(.leading, T.Space.s300)
            .padding(.trailing, T.Space.s100)
            .padding(.vertical, T.Space.s25)
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        if let e = editing, !name.isEmpty {
            if e == "new" { model.createFolder(name) } else { model.renameFolder(e, name) }
        }
        editing = nil
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
