// App shell (design/screens/app-shell): library · sheet list · editor · inspector.
// Pane rule validated in the web app (App.tsx panesFor): a pane docks only while the editor keeps ≥ 600 pt;
// priority editor → (open) inspector → sheet list → library; the inspector may squeeze the editor to 580.
// Panes that can't dock open as overlays that close when you click outside.
import IthacaDesign
import SwiftUI

struct Panes: Equatable {
    var compact = false, list = false, library = false, inspector = false

    static func forWidth(_ width: Double, inspectorOpen: Bool) -> Panes {
        if T.Layout.SizeClass.forWidth(width) == .compact { return Panes(compact: true) }
        var room = width - AppModel.editorMin
        func take(_ w: Double) -> Bool { if room >= w { room -= w; return true }; return false }
        room += 20
        let inspector = inspectorOpen && take(T.Layout.Pane.inspectorDefault)
        room -= 20
        let list = take(T.Layout.Pane.sheetListDefault)
        let library = list && take(T.Layout.Pane.libraryDefault)
        return Panes(compact: false, list: list, library: library, inspector: inspector)
    }
}

struct ShellView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let panes = Panes.forWidth(geo.size.width, inspectorOpen: model.inspectorOpen)
            let sizeClass = T.Layout.SizeClass.forWidth(geo.size.width)
            let focus = model.focusMode
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if !focus && panes.library { LibraryPane().frame(width: T.Layout.Pane.libraryDefault) }
                    if !focus && panes.list { SheetListPane().frame(width: T.Layout.Pane.sheetListDefault) }
                    EditorPane(sizeClass: sizeClass, panes: panes)
                    if !focus && model.inspectorOpen && panes.inspector {
                        InspectorPane().frame(width: T.Layout.Pane.inspectorDefault).hairline(.leading)
                    }
                }
                if !focus && model.inspectorOpen && !panes.inspector {
                    Scrim { model.inspectorOpen = false }
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        InspectorPane().frame(width: min(T.Layout.Pane.inspectorDefault, geo.size.width)).tokenShadow(T.Shadow.dialog)
                    }
                }
                if !focus && model.libraryOverlay && !(panes.library && panes.list) {
                    Scrim { model.libraryOverlay = false }
                    HStack(spacing: 0) {
                        if !panes.library { LibraryPane().frame(width: T.Layout.Pane.libraryDefault) }
                        if !panes.list { SheetListPane().frame(width: min(T.Layout.Pane.sheetListDefault, geo.size.width - T.Layout.Pane.libraryDefault)) }
                    }
                    .tokenShadow(T.Shadow.dialog)
                }
                if case .palette(let search) = model.overlay {
                    Scrim { model.overlay = nil }
                    PaletteView(searchMode: search, compact: panes.compact, initialQuery: model.paletteSeed).frame(maxWidth: .infinity)
                }
                if let toast = model.toast {
                    VStack { Spacer(); ToastBar(toast: toast) }.frame(maxWidth: .infinity).padding(.bottom, T.Space.s600)
                }
            }
            .onAppear { sync(panes) }
            .onChange(of: panes) { _, p in sync(p) }
        }
        .background(Color.surfaceCanvas)
        .foregroundStyle(Color.inkPrimary)
        .frame(minWidth: T.Layout.Window.minWidth, minHeight: T.Layout.Window.minHeight)
        .sheet(item: dialogBinding) { o in
            Group {
                switch o {
                case .export: ExportView()
                case .history: HistoryView()
                case .newProject(let firstRun): NewProjectView(firstRun: firstRun)
                case .projectSettings: ProjectSettingsView()
                case .palette: EmptyView()
                }
            }
            .environment(model)
        }
    }

    private func sync(_ p: Panes) {
        model.dockedLibrary = p.library
        model.dockedList = p.list
        if p.library && p.list { model.libraryOverlay = false }
    }

    /// The palette floats over the window; every other overlay is a native sheet.
    private var dialogBinding: Binding<Overlay?> {
        Binding(
            get: { if case .palette = model.overlay { return nil }; return model.overlay },
            set: { model.overlay = $0 }
        )
    }
}

struct Scrim: View {
    let close: () -> Void
    var body: some View {
        Color.surfaceScrim.ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: close)
    }
}

struct ToastBar: View {
    @Environment(AppModel.self) private var model
    let toast: Toast

    var body: some View {
        HStack(spacing: T.Space.s150) {
            Text(toast.message).textStyle(.label).fixedSize(horizontal: false, vertical: true)
            if let undo = toast.undo {
                Button(model.t(.actionUndo)) { undo(); model.toast = nil }
                    .buttonStyle(.plain)
                    .font(Fonts.swiftUI(.label, weight: T.Typography.heading.weight))
                    .foregroundStyle(Color.accentSoft)
            }
            if toast.sticky || toast.undo == nil {
                Button { model.toast = nil } label: { Icon(.close, size: T.Size.iconSm, color: .surfaceCanvas) }
                    .buttonStyle(.plain)
                    .help(model.t(.actionClose))
            }
        }
        .padding(.vertical, T.Space.s100)
        .padding(.leading, T.Space.s200)
        .padding(.trailing, T.Space.s150)
        .foregroundStyle(Color.surfaceCanvas)
        .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.inkPrimary))
        .tokenShadow(T.Shadow.popover)
        .frame(maxWidth: T.Layout.Pane.dialogDefault)
        .onHover { model.holdToast($0) }
    }
}
