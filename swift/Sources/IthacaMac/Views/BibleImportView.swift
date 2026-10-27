// File → Import Story Bible (design/screens/story-bible §6): a Notion export (.md file or folder) → kind → preview
// (source · name · fields · sections, from core `bible_import_preview`) → [Import] into the lore folder, all or nothing.
import IthacaCore
import IthacaDesign
import SwiftUI

struct BibleImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let path: String

    @State private var kind: EntryKind = .character
    @State private var entries: [ImportedEntry] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s200) {
            VStack(alignment: .leading, spacing: T.Space.s50) {
                Text(model.t(.importBibleTitle)).textStyle(.title)
                Text(model.t(.importBibleHint)).textStyle(.label, weight: 400).foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Caption(path).lineLimit(1).truncationMode(.middle).help(path)
            }
            VStack(alignment: .leading, spacing: T.Space.s50) {
                Text(model.t(.importBibleKind)).textStyle(.label)
                FillSegmented(items: EntryKind.all.map { ($0, model.t($0.label)) }, selection: $kind)
                    // Its own height (an NSView has none until laid out; the sheet sizes to its content).
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(model.t(.importBibleKind))
            }
            preview
            // One status line, always there (empty until the preview is read) so the sheet doesn't change height.
            Group {
                if let error {
                    Text(error).textStyle(.label, weight: 400).foregroundStyle(Color.stateDanger)
                } else if let lore = model.loreFolder, !entries.isEmpty {
                    Caption(model.t(.importBibleInto, ["folder": lore.name, "count": entries.count], count: entries.count))
                } else {
                    Caption(" ")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                KitButton(model.t(.actionCancel), variant: .ghost) { dismiss() }.keyboardShortcut(.cancelAction)
                KitButton(model.t(.importBibleImport), variant: .primary) {
                    if model.importBible(entries) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entries.isEmpty || error != nil || model.readOnly)
            }
        }
        .padding(T.Space.s300)
        .frame(width: T.Layout.Pane.dialogMax)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.surfaceCanvas)
        .onAppear(perform: refresh)
        .onChange(of: kind) { refresh() }
    }

    /// The table: one row per file, numbers right-aligned.
    private var preview: some View {
        VStack(spacing: 0) {
            row(model.t(.importBibleColSource), model.t(.importBibleColName), model.t(.importBibleColFields), model.t(.importBibleColSections), header: true)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        row(e.source, e.name, model.number(Int(e.fields)), model.number(Int(e.sections)))
                    }
                    if entries.isEmpty && error == nil {
                        Caption(model.t(.importBibleEmpty)).frame(maxWidth: .infinity).padding(T.Space.s300)
                    }
                }
            }
            // A fixed height: the sheet sizes to its content, and a ScrollView has no fixed ideal height.
            .frame(height: 220)
        }
        .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: T.Radius.panel).strokeBorder(Color.lineSubtle))
        .clipShape(RoundedRectangle(cornerRadius: T.Radius.panel))
    }

    private func row(_ source: String, _ name: String, _ fields: String, _ sections: String, header: Bool = false) -> some View {
        HStack(spacing: T.Space.s150) {
            Text(source).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(source)
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text(fields).frame(width: 72, alignment: .trailing)
            Text(sections).frame(width: 56, alignment: .trailing)
        }
        .lineLimit(1)
        .textStyle(header ? .caption : .label, weight: header ? T.Typography.label.weight : 400)
        .foregroundStyle(header ? Color.inkTertiary : .inkPrimary)
        .padding(.horizontal, T.Space.s150)
        .padding(.vertical, T.Space.s100)
        .frame(minHeight: T.Size.controlMd)
        .hairline(.bottom)
    }

    private func refresh() {
        do {
            entries = try StoryBible.importPreview(path: path, kind: kind, language: model.language)
            error = nil
        } catch {
            entries = []
            self.error = model.t(.importWebFailed, ["message": error.localizedDescription])
        }
    }
}
