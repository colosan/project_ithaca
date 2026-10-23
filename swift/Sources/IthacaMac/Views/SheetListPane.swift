// Sheet list: the open folder's sheets in serial order (drag to reorder, ⌥⌘↑↓), or the trash.
import IthacaDesign
import SwiftUI

struct SheetListPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let trash = model.showingTrash
        let sheets = trash ? model.trash : (model.folder?.sheets ?? [])
        VStack(spacing: 0) {
            header(trash: trash, sheets: sheets)
            if trash && !sheets.isEmpty {
                HStack(spacing: T.Space.s100) {
                    Caption(model.t(.trashHint)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    KitButton(model.t(.trashRestoreAll), icon: .restore, variant: .ghost) { model.restoreAll() }
                    KitButton(model.t(.trashEmpty), variant: .danger) { model.emptyTrash() }
                }
                .padding(.horizontal, T.Space.s200)
                .padding(.vertical, T.Space.s100)
                .hairline(.bottom)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if sheets.isEmpty {
                        Caption(trash ? model.t(.trashEmptyState) : model.t(.sheetListEmpty)).padding(T.Space.s300)
                    }
                    ForEach(sheets) { s in
                        SheetRow(sheet: s, trash: trash, active: !trash && s.id == model.sheetId)
                    }
                    // Dropping below the last row moves a sheet to the end.
                    Color.clear.frame(height: T.Size.rowSheet)
                        .dropDestination(for: String.self) { ids, _ in
                            guard !trash, let id = ids.first, let f = model.folder else { return false }
                            model.move(sheet: id, to: f.id, before: nil)
                            return true
                        }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.surfaceList)
        .hairline(.trailing)
    }

    private func header(trash: Bool, sheets: [SheetSummary]) -> some View {
        let total = sheets.reduce(0) { $0 + (model.language == .ko ? $1.counts.chars : $1.counts.words) }
        let unit = model.language == .ko ? model.t(.countWithSpaces, ["count": total]) : model.t(.countWords, ["count": total], count: total)
        return HStack(spacing: T.Space.s50) {
            if !model.dockedLibrary && !model.libraryOverlay {
                IconButton(.library, label: model.t(.libraryShow)) { model.libraryOverlay = true }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(trash ? model.t(.trashTitle) : model.folder?.name ?? "").textStyle(.heading).lineLimit(1)
                HStack(spacing: 0) {
                    Caption(model.t(.sheetListCount, ["count": sheets.count], count: sheets.count) + (!trash && !sheets.isEmpty ? " · \(unit)" : ""))
                    if !trash, let f = model.folder, let stock = model.stock(f) {
                        Caption(" · " + model.t(.episodeStock, ["count": stock])).help(model.t(.episodeStockHint))
                    }
                }
            }
            Spacer(minLength: 0)
            IconButton(.search, label: model.t(.searchTitle)) { model.show(.palette(search: true)) }
            if !trash && model.folder != nil && !model.readOnly {
                IconButton(.add, label: model.t(.sheetNew)) { model.newSheet() }
            }
        }
        .padding(.leading, T.Space.s200)
        .padding(.trailing, T.Space.s100)
        .frame(minHeight: T.Size.barTop)
        .hairline(.bottom)
    }
}

struct SheetRow: View {
    @Environment(AppModel.self) private var model
    let sheet: SheetSummary
    let trash: Bool
    let active: Bool
    @State private var hover = false
    @State private var dropAbove = false

    var body: some View {
        let length = model.language == .ko ? model.t(.countWithSpaces, ["count": sheet.counts.chars])
                                           : model.t(.countWords, ["count": sheet.counts.words], count: sheet.counts.words)
        HStack(alignment: .top, spacing: T.Space.s100) {
            VStack(alignment: .leading, spacing: T.Space.s25) {
                HStack(spacing: T.Space.s50) {
                    Text(sheet.title.isEmpty ? model.t(.sheetUntitled) : sheet.title)
                        .textStyle(.body, weight: T.Typography.heading.weight)
                        .foregroundStyle(sheet.title.isEmpty ? Color.inkTertiary : .inkPrimary)
                        .lineLimit(1)
                    if sheet.branched { Icon(.warning, size: T.Size.iconSm, color: .stateWarning).help(model.t(.sheetBranched)) }
                }
                if !sheet.excerpt.isEmpty {
                    Text(sheet.excerpt).textStyle(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1)
                }
                HStack(spacing: T.Space.s100) {
                    if let e = sheet.episode {
                        Text(model.episodeLabel(e)).foregroundStyle(e.status == .published ? Color.inkTertiary : .accentPrimary)
                    }
                    Text(length)
                    Text(trash ? (model.folderName(sheet.folder) ?? "") : sheet.modified.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(Locale(identifier: model.locale.rawValue))))
                }
                .lineLimit(1)
                .textStyle(.caption)
                .foregroundStyle(Color.inkTertiary)
                .padding(.top, T.Space.s25)
            }
            Spacer(minLength: 0)
            if trash {
                IconButton(.restore, label: model.t(.trashRestore)) { model.restoreSheet(sheet.id) }
                IconButton(.delete, label: model.t(.trashDeleteForever)) { model.deleteForever(sheet.id) }
            } else if hover || active {
                IconButton(.delete, label: model.t(.sheetTrash)) { model.trashSheet(sheet.id) }
            }
        }
        .padding(.horizontal, T.Space.s200)
        .padding(.vertical, T.Space.s150)
        .frame(minHeight: T.Size.rowSheet, alignment: .top)
        .background(active ? Color.surfaceSelected : .clear)
        .overlay(alignment: .top) { if dropAbove { Rectangle().fill(Color.accentPrimary).frame(height: T.Size.strokeFocus) } }
        .hairline(.bottom)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            guard !trash else { return }
            model.openSheet(sheet.id)
            model.libraryOverlay = false
        }
        .contextMenu { if !trash { menu } }
        .draggable(sheet.id) {
            Text(sheet.title.isEmpty ? model.t(.sheetUntitled) : sheet.title).padding(T.Space.s100).background(Color.surfaceRaised)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard !trash, let id = ids.first, id != sheet.id else { return false }
            model.move(sheet: id, to: sheet.folder, before: sheet.id)
            return true
        } isTargeted: { dropAbove = $0 && !trash }
    }

    @ViewBuilder private var menu: some View {
        Button(model.t(.sheetMoveUp)) { model.openSheet(sheet.id); model.moveSheet(-1) }
        Button(model.t(.sheetMoveDown)) { model.openSheet(sheet.id); model.moveSheet(1) }
        let others = model.folders.filter { $0.id != sheet.folder }
        if !others.isEmpty {
            Menu(model.t(.sheetMove)) {
                ForEach(others) { f in Button(f.name) { model.move(sheet: sheet.id, to: f.id, before: nil) } }
            }
        }
        Divider()
        Button(model.t(.navHistory)) { model.openSheet(sheet.id); model.show(.history) }
        Button(model.t(.exportTitle) + "…") { model.openSheet(sheet.id); model.show(.export) }
        Divider()
        Button(model.t(.sheetTrash), role: .destructive) { model.trashSheet(sheet.id) }
    }
}
