// Export (design/screens/export): paste-ready text for serial platforms, or a .txt / .md / .docx file.
// Text comes from core export_text; the Word file from core export_docx.
import AppKit
import IthacaDesign
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, Codable, CaseIterable { case sheet, folder, project }
    enum Target: String, Codable { case paste, file }
    enum Ext: String, Codable { case txt, md, docx }
    /// The last choices, so a writer who exports every episode the same way sets it once.
    struct Saved: Codable {
        var scope = Scope.sheet; var target = Target.paste; var ext = Ext.txt; var opts = ExportOptions()
        var docx = DocxOptions()
        init() {}
        /// Field by field, so choices saved by an older build (no `docx`, or an unknown format) survive.
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            scope = (try? c.decode(Scope.self, forKey: .scope)) ?? scope
            target = (try? c.decode(Target.self, forKey: .target)) ?? target
            ext = (try? c.decode(Ext.self, forKey: .ext)) ?? ext
            opts = (try? c.decode(ExportOptions.self, forKey: .opts)) ?? opts
            docx = (try? c.decode(DocxOptions.self, forKey: .docx)) ?? docx
        }
    }
    /// Fonts a Korean manuscript is usually asked for; Word substitutes when one is missing.
    static let docxFonts = ["맑은 고딕", "바탕", "굴림", "돋움", "나눔명조", "나눔고딕", "Times New Roman"]
    static let lineSpacings = [100, 130, 150, 160, 180, 200]

    @State private var saved = Self.load()
    @State private var done = false
    /// The export text and its count, recomputed only when an input changes (not on every render).
    @State private var text = ""
    @State private var textCount = 0
    @State private var pageSetupOpen = false

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
                    ScrollView {
                        options.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    KitButton(primaryLabel, icon: done ? .check : saved.target == .paste ? .copy : .save, variant: .primary, action: go)
                        .disabled(text.isEmpty)
                }
                // Wide enough for the English scope segments ("This sheet · Whole folder · Whole project").
                .frame(width: T.Layout.Pane.sheetListDefault, alignment: .leading)
                .textStyle(.body)
                VStack(alignment: .leading, spacing: T.Space.s100) {
                    Caption("\(model.t(.exportPreview)) · \(model.t(.exportCount, ["count": textCount], count: textCount))")
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
        .onAppear(perform: refresh)
        .onChange(of: saved.scope) { done = false; persist(); refresh() }
        .onChange(of: saved.target) { done = false; persist(); refresh() }
        .onChange(of: saved.ext) { done = false; persist(); refresh() }
        .onChange(of: saved.opts) { done = false; persist(); refresh() }
        .onChange(of: saved.docx) { done = false; persist(); refresh() }
        .onChange(of: inputs) { refresh() }
    }

    /// Scope, target, format and the format's options; scrolls when Word's options don't fit.
    private var options: some View {
        VStack(alignment: .leading, spacing: T.Space.s200) {
            Picker(model.t(.exportScope), selection: $saved.scope) {
                Text(model.t(.exportScopeSheet)).tag(Scope.sheet)
                Text(model.t(.exportScopeFolder)).tag(Scope.folder)
                Text(model.t(.exportScopeProject)).tag(Scope.project)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                    Text(model.t(.exportFormatDocx)).tag(Ext.docx)
                }
                .pickerStyle(.radioGroup)
            }
            if wordFile {
                docxOptions
            } else if !markdownFile {
                VStack(alignment: .leading, spacing: T.Space.s100) {
                    Toggle(model.t(.exportOptBlankLine), isOn: $saved.opts.blankLine)
                    Toggle(model.t(.exportOptIndent), isOn: $saved.opts.indent)
                    Toggle(model.t(.exportOptStripMarkdown), isOn: $saved.opts.stripMarkdown)
                    Toggle(model.t(.exportOptIncludeTitle), isOn: $saved.opts.includeTitle)
                }
                .toggleStyle(.checkbox)
            }
        }
    }
    private var markdownFile: Bool { saved.target == .file && saved.ext == .md }
    private var wordFile: Bool { saved.target == .file && saved.ext == .docx }

    /// Word options: what a submission guideline names (font · size · line spacing) in view; margins folded.
    @ViewBuilder private var docxOptions: some View {
        VStack(alignment: .leading, spacing: T.Space.s100) {
            Toggle(model.t(.exportOptIndent), isOn: $saved.docx.firstLineIndent)
            Toggle(model.t(.exportDocxTitles), isOn: $saved.docx.includeTitles)
            Toggle(model.t(.exportDocxPageBreak), isOn: $saved.docx.pageBreak)
        }
        .toggleStyle(.checkbox)
        Grid(alignment: .leading, horizontalSpacing: T.Space.s100, verticalSpacing: T.Space.s100) {
            GridRow {
                Text(model.t(.exportDocxFont))
                Picker("", selection: $saved.docx.font) {
                    ForEach(Self.docxFonts + (Self.docxFonts.contains(saved.docx.font) ? [] : [saved.docx.font]), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                Text(model.t(.exportDocxSize))
                Stepper(value: $saved.docx.fontSize, in: 8...20, step: 0.5) {
                    Text(saved.docx.fontSize.formatted(.number.precision(.fractionLength(0...1)))).monospacedDigit()
                }
            }
            GridRow {
                Text(model.t(.exportDocxLineSpacing))
                Picker("", selection: $saved.docx.lineSpacing) {
                    ForEach(Self.lineSpacings + (Self.lineSpacings.contains(saved.docx.lineSpacing) ? [] : [saved.docx.lineSpacing]), id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
            }
        }
        DisclosureGroup(model.t(.exportDocxPage), isExpanded: $pageSetupOpen) {
            VStack(alignment: .leading, spacing: T.Space.s100) {
                Caption(model.t(.exportDocxPaper))
                Grid(alignment: .leading, horizontalSpacing: T.Space.s100, verticalSpacing: T.Space.s100) {
                    GridRow {
                        marginField(.exportDocxMarginTop, $saved.docx.marginTop)
                        marginField(.exportDocxMarginBottom, $saved.docx.marginBottom)
                    }
                    GridRow {
                        marginField(.exportDocxMarginLeft, $saved.docx.marginLeft)
                        marginField(.exportDocxMarginRight, $saved.docx.marginRight)
                    }
                }
                KitButton(model.t(.exportDocxReset), variant: .ghost) { saved.docx = DocxOptions() }
                    .disabled(saved.docx == DocxOptions())
            }
            .padding(.top, T.Space.s100)
        }
    }

    private func marginField(_ key: L10nKey, _ value: Binding<Double>) -> some View {
        HStack(spacing: T.Space.s50) {
            Text(model.t(key))
            TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, 0), 80) }),
                      format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: T.Space.s600)
        }
    }

    /// The Word file's text as the paste rules would show it: what the preview and count use.
    private var docxPreviewOptions: ExportOptions {
        ExportOptions(blankLine: true, indent: saved.docx.firstLineIndent, stripMarkdown: true, includeTitle: saved.docx.includeTitles)
    }

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

    /// What else the text depends on: the project, the selection and the sheets' content (modified stamps).
    private var inputs: [String] {
        [model.projectId ?? "", model.sheetId ?? "", model.folderId ?? ""] + model.folders.flatMap(\.sheets).map { "\($0.id):\($0.modified)" }
    }

    private func refresh() {
        text = exportText()
        textCount = TextMetrics.counts(text).chars
    }

    private func exportText() -> String {
        guard let p = model.projectId, let ids = sheetIds else { return "" }
        if saved.scope == .folder && ids.isEmpty { return "" }
        var o = wordFile ? docxPreviewOptions : saved.opts
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
        if saved.target == .paste {
            // Plain string only: RTF/HTML on the clipboard turns into doubled blank lines on serial platforms.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = fileName
            let type: UTType = switch saved.ext {
            case .md: UTType(filenameExtension: "md") ?? .plainText
            case .docx: UTType(filenameExtension: "docx") ?? .data
            case .txt: .plainText
            }
            panel.allowedContentTypes = [type]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if saved.ext == .docx {
                guard let p = model.projectId, let ids = sheetIds else { return }
                let data: Data
                do { data = try model.library.exportDocx(project: p, sheets: ids, options: saved.docx) } catch {
                    model.showToast(Toast(message: model.t(.exportDocxFailed, ["reason": error.localizedDescription]), sticky: true)); return
                }
                do { try data.write(to: url, options: .atomic) } catch {
                    model.showToast(Toast(message: error.localizedDescription, sticky: true)); return
                }
            } else {
                do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
                    model.showToast(Toast(message: error.localizedDescription, sticky: true)); return
                }
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
