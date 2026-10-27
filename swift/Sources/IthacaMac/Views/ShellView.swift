// App shell (design/screens/app-shell): library · sheet list · editor · inspector.
// Pane rule validated in the web app (App.tsx panesFor): a pane docks only while the editor keeps ≥ 600 pt;
// priority editor → (open) inspector → sheet list → library; the inspector may squeeze the editor to 580.
// Panes that can't dock open as overlays that close when you click outside.
import AppKit
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
    @State private var escape: EscapeMonitor?
    @State private var window: NSWindow?

    var body: some View {
        GeometryReader { geo in
            let panes = Panes.forWidth(geo.size.width, inspectorOpen: model.inspectorOpen)
            let sizeClass = T.Layout.SizeClass.forWidth(geo.size.width)
            let focus = model.panesHidden
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
                // Top-right under the toolbar, inset: over the editor's margin, not over the line being written.
                if let toast = model.toast {
                    VStack {
                        HStack { Spacer(minLength: T.Space.s200); ToastBar(toast: toast) }
                        Spacer()
                    }
                    .padding(.top, T.Size.barTop + T.Space.s100)
                    .padding(.trailing, T.Space.s200)
                }
                if let busy = model.busy { BusyHUD(message: busy) }
            }
            .onAppear { sync(panes); model.inspectorDocks = Panes.forWidth(geo.size.width, inspectorOpen: true).inspector }
            .onChange(of: panes) { _, p in sync(p) }
            .onChange(of: Panes.forWidth(geo.size.width, inspectorOpen: true).inspector) { _, d in model.inspectorDocks = d }
        }
        .background(WindowReader { w in
            let m = escape ?? EscapeMonitor()
            if escape == nil { escape = m }
            m.window = w
            if w != nil { m.install(model) } else { m.remove() }
            if let w, window !== w { window = w; MiniWindow.apply(w, mini: model.mini) }
        })
        .background(Color.surfaceCanvas)
        .foregroundStyle(Color.inkPrimary)
        .frame(minWidth: model.mini ? MiniWindow.minSize.width : T.Layout.Window.minWidth,
               minHeight: model.mini ? MiniWindow.minSize.height : T.Layout.Window.minHeight)
        .onChange(of: model.mini) { _, mini in if let window { MiniWindow.toggle(window, mini: mini, defaults: model.defaults) } }
        .sheet(item: dialogBinding) { o in
            Group {
                switch o {
                case .export: ExportView()
                case .history: HistoryView()
                case .newProject(let firstRun): NewProjectView(firstRun: firstRun)
                case .projectSettings: ProjectSettingsView()
                case .importSkipped: ImportSkippedView()
                case .importBible(let path): BibleImportView(path: path)
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

/// Esc closes a pane shown as an overlay (library / list, then the inspector), like clicking the scrim.
/// A key monitor, not a keyboard shortcut: the manuscript text view takes Esc for itself (completion) before
/// SwiftUI shortcuts see it. Left alone: dialogs, the palette, IME composition, a text field being edited.
@MainActor
final class EscapeMonitor {
    weak var window: NSWindow?
    private var token: Any?

    func install(_ model: AppModel) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak model] event in
            nonisolated(unsafe) let e = event
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, let model else { return false }
                return Self.handle(e, model: model, window: self.window)
            }
            return swallow ? nil : event
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    /// True when Esc closed an overlay pane (the event is then swallowed).
    static func handle(_ event: NSEvent, model: AppModel, window: NSWindow?) -> Bool {
        guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
              let window, event.window === window, window.attachedSheet == nil,
              model.overlay == nil, !model.panesHidden, model.editor?.isComposing != true else { return false }
        if let tv = window.firstResponder as? NSTextView, tv.isFieldEditor { return false }
        if model.libraryOverlay && !(model.dockedLibrary && model.dockedList) { model.libraryOverlay = false; return true }
        if model.inspectorOpen && !model.inspectorDocks { model.inspectorOpen = false; return true }
        return false
    }
}

/// Hands over the window a SwiftUI view lives in.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { Probe(found) }
    func updateNSView(_ view: NSView, context: Context) {}
    final class Probe: NSView {
        let found: (NSWindow?) -> Void
        init(_ found: @escaping (NSWindow?) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); found(window) }
    }
}

struct Scrim: View {
    let close: () -> Void
    var body: some View {
        Color.surfaceScrim.ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: close)
    }
}

/// Files a text-folder import left out, one per line ("path (reason)").
struct ImportSkippedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s150) {
            Text(model.t(.importSkippedTitle)).textStyle(.title)
            Text(model.t(.importSkippedHint)).textStyle(.body).foregroundStyle(Color.inkSecondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: T.Space.s50) {
                    ForEach(Array(model.importSkipped.enumerated()), id: \.offset) { _, line in
                        Text(line).textStyle(.label).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(T.Space.s150)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: T.Radius.panel).strokeBorder(Color.lineSubtle))
            HStack {
                Spacer()
                KitButton(model.t(.actionClose), variant: .primary) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(T.Space.s300)
        .frame(width: T.Layout.Pane.dialogDefault)
        .background(Color.surfaceCanvas)
    }
}

/// Import / restore in progress: blocks the window (the work changes the project list) and says what's happening.
struct BusyHUD: View {
    let message: String
    var body: some View {
        ZStack {
            Color.surfaceScrim.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(spacing: T.Space.s150) {
                ProgressView().controlSize(.regular)
                Text(message).textStyle(.label).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(T.Space.s300)
            .frame(maxWidth: T.Layout.Pane.sheetListDefault)
            .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.surfaceRaised))
            .tokenShadow(T.Shadow.dialog)
        }
    }
}

struct ToastBar: View {
    @Environment(AppModel.self) private var model
    let toast: Toast

    var body: some View {
        HStack(spacing: T.Space.s150) {
            Text(toast.message).textStyle(.label).fixedSize(horizontal: false, vertical: true)
            if let undo = toast.undo {
                // A real button (ghost on the dark toast), not just bold text.
                Button { undo(); model.toast = nil } label: {
                    Text(toast.action ?? model.t(.actionUndo))
                        .font(Fonts.swiftUI(.label, weight: T.Typography.heading.weight))
                        .padding(.horizontal, T.Space.s100)
                        .padding(.vertical, T.Space.s25)
                        .overlay(RoundedRectangle(cornerRadius: T.Radius.control).strokeBorder(Color.surfaceCanvas, lineWidth: T.Size.strokeHairline))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.surfaceCanvas)
                .fixedSize()
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
