// Export (design/screens/export): paste-ready text for serial platforms, or a .txt / .md file. Text comes from core export_text.
import AppKit
import IthacaDesign
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, Codable, CaseIterable { case sheet, folder, project }
    enum Target: String, Codable { case paste, file }
    enum Ext: String, Codable { case txt, md }
    /// The last choices, so a writer who exports every episode the same way sets it once.
    struct Saved: Codable { var scope = Scope.sheet; var target = Target.paste; var ext = Ext.txt; var opts = ExportOptions() }

    @State private var saved = Self.load()
    @State private var done = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.t(.exportTitle)).textStyle(.title)
                Spacer()
                IconButton(.close, label: model.t(.actionClose)) { dismiss() }
            }
            .padding(.horizontal, T.Space.s300)
            .padding(.vertical, T.Space.s150)
            .hairline(.bottom)
            HStack(alignment: .top, spacing: T.Space.s300) {
                VStack(alignment: .leading, spacing: T.Space.s200) {
                    Picker(model.t(.exportScope), selection: $saved.scope) {
                        Text(model.t(.exportScopeSheet)).tag(Scope.sheet)
                        Text(model.t(.exportScopeFolder)).tag(Scope.folder)
                        Text(model.t(.exportScopeProject)).tag(Scope.project)
                    }
                    .pickerStyle(.segmented)
                    Picker("", selection: $saved.target) {
                        Text(model.t(.exportTargetPaste)).tag(Target.paste)
                        Text(model.t(.exportTargetFile)).tag(Target.file)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if saved.target == .file {
                        Picker(model.t(.exportFormat), selection: $saved.ext) {
                            Text(model.t(.exportFormatTxt)).tag(Ext.txt)
                            Text(model.t(.exportFormatMd)).tag(Ext.md)
                        }
                        .pickerStyle(.radioGroup)
                    }
                    if !markdownFile {
                        VStack(alignment: .leading, spacing: T.Space.s100) {
                            Toggle(model.t(.exportOptBlankLine), isOn: $saved.opts.blankLine)
                            Toggle(model.t(.exportOptIndent), isOn: $saved.opts.indent)
                            Toggle(model.t(.exportOptStripMarkdown), isOn: $saved.opts.stripMarkdown)
                            Toggle(model.t(.exportOptIncludeTitle), isOn: $saved.opts.includeTitle)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Spacer(minLength: 0)
                    KitButton(primaryLabel, icon: done ? .check : saved.target == .paste ? .copy : .save, variant: .primary, action: go)
                        .disabled(text.isEmpty)
                }
                .frame(width: T.Layout.Pane.sheetListDefault - T.Space.s300 * 2)
                .textStyle(.body)
                VStack(alignment: .leading, spacing: T.Space.s100) {
                    Caption("\(model.t(.exportPreview)) · \(model.t(.exportCount, ["count": TextMetrics.counts(text).chars], count: TextMetrics.counts(text).chars))")
                    ScrollView {
                        Text(text)
                            .textStyle(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(T.Space.s200)
                    }
                    .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: T.Radius.panel).strokeBorder(Color.lineSubtle))
                }
            }
            .padding(T.Space.s300)
        }
        .frame(width: T.Layout.Pane.dialogMax + T.Layout.Pane.sheetListDefault, height: 560)
        .background(Color.surfaceCanvas)
        .onChange(of: saved.scope) { done = false; persist() }
        .onChange(of: saved.target) { done = false; persist() }
        .onChange(of: saved.ext) { done = false; persist() }
        .onChange(of: saved.opts) { done = false; persist() }
    }

    private var markdownFile: Bool { saved.target == .file && saved.ext == .md }

    private var primaryLabel: String {
        if done { return saved.target == .paste ? model.t(.exportCopied) : model.t(.exportSaved) }
        return saved.target == .paste ? model.t(.exportCopy) : model.t(.exportSave) + "…"
    }

    private var sheetIds: [String]? {
        switch saved.scope {
        case .sheet: model.sheetId.map { [$0] }
        case .folder: model.folder?.sheets.map(\.id)
        case .project: []  // empty = whole project in reading order (API.md)
        }
    }

    private var text: String {
        guard let p = model.projectId, let ids = sheetIds else { return "" }
        if saved.scope == .folder && ids.isEmpty { return "" }
        var o = saved.opts
        o.markdown = markdownFile
        return (try? model.library.exportText(project: p, sheets: ids, options: o)) ?? ""
    }

    private var fileName: String {
        let name: String? = switch saved.scope {
        case .sheet: model.sheet?.title
        case .folder: model.folder?.name
        case .project: model.project?.title
        }
        let base = (name?.isEmpty == false ? name! : model.t(.sheetUntitled)).replacingOccurrences(of: #"[\\/:*?"<>|]"#, with: "_", options: .regularExpression)
        return "\(base).\(saved.ext.rawValue)"
    }

    private func go() {
        let text = self.text
        if saved.target == .paste {
            // Plain string only: RTF/HTML on the clipboard turns into doubled blank lines on serial platforms.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = fileName
            panel.allowedContentTypes = [saved.ext == .md ? UTType(filenameExtension: "md") ?? .plainText : .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
                model.showToast(Toast(message: error.localizedDescription, sticky: true)); return
            }
        }
        done = true
    }

    private static func load() -> Saved {
        guard let d = AppEnvironment.defaults.data(forKey: "ithaca.export"), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return Saved() }
        return s
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(saved) { AppEnvironment.defaults.set(d, forKey: "ithaca.export") }
    }
}
