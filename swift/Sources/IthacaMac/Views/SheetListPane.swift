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
            if trash && !sheets.isEmpty && !model.readOnly {
                // Hint on its own line, buttons below: side by side they clipped in a 280 pt list (English worst).
                VStack(alignment: .leading, spacing: T.Space.s100) {
                    Caption(model.t(.trashHint)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: T.Space.s100) {
                        KitButton(model.t(.trashRestoreAll), icon: .restore) { model.restoreAll() }.help(model.t(.trashRestoreAll))
                        KitButton(model.t(.trashEmpty), icon: .delete, variant: .danger) { model.emptyTrash() }.help(model.t(.trashEmpty))
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, T.Space.s200)
                .padding(.vertical, T.Space.s100)
                .hairline(.bottom)
            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if sheets.isEmpty {
                        Caption(trash ? model.t(.trashEmptyState) : model.t(.sheetListEmpty)).padding(T.Space.s300)
                    }
                    ForEach(sheets) { s in
                        SheetRow(sheet: s, trash: trash, active: !trash && s.id == model.sheetId).id(s.id)
                    }
                    // Dropping below the last row moves a sheet to the end.
                    Color.clear.frame(height: T.Size.rowSheet)
                        .dropDestination(for: String.self) { ids, _ in
                            guard !trash, !model.readOnly, let id = ids.first, let f = model.folder else { return false }
                            model.move(sheet: id, to: f.id, before: nil)
                            return true
                        }
                }
            }
            // New sheet, reorder (⌥⌘↑↓, drag), search hit: keep the open sheet in view.
            .onChange(of: model.sheetId) { reveal(proxy) }
            .onChange(of: sheets.map(\.id)) { reveal(proxy) }
            .onAppear { reveal(proxy) }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.surfaceList)
        .hairline(.trailing)
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard !model.showingTrash, let id = model.sheetId, model.folder?.sheets.contains(where: { $0.id == id }) == true else { return }
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
    }

    private func header(trash: Bool, sheets: [SheetSummary]) -> some View {
        let ko = model.language == .ko
        // The body as posted, like the rows and the footer (PRODUCT "글자수 정의").
        let total = trash ? 0 : sheets.reduce(0) { let c = model.postedCounts(of: $1); return $0 + (ko ? c.chars : c.words) }
        // Short in the header ("29,822 chars"), the full wording in the tooltip: the long form wrapped to 3 lines in English.
        let short = ko ? model.t(.countCharsShort, ["count": total], count: total) : model.t(.countWords, ["count": total], count: total)
        let full = ko ? model.t(.countWithSpaces, ["count": total], count: total) : model.t(.countWords, ["count": total], count: total)
        let stock = trash ? nil : model.folder.flatMap { model.stock($0) }
        let next = trash ? nil : model.folder.flatMap { model.nextRelease($0) }
        let line = model.t(.sheetListCount, ["count": sheets.count], count: sheets.count)
            + (!trash && !sheets.isEmpty ? " · \(short)" : "")
        // Serial folders: "비축 3화 · 다음 연재 10/26" on its own line so neither gets cut off in a 280 pt list.
        let serial = [stock.map { model.t(.episodeStock, ["count": $0]) },
                      next.map { model.t(.episodeNextRelease, ["date": model.releaseDate($0, time: false)]) }].compactMap { $0 }.joined(separator: " · ")
        let tip = [model.t(.sheetListCount, ["count": sheets.count], count: sheets.count), trash || sheets.isEmpty ? nil : full,
                   stock.map { model.t(.episodeStock, ["count": $0]) + " — " + model.t(.episodeStockHint) },
                   next.map { model.t(.folderStatsNextRelease) + " " + model.releaseDate($0, time: true) },
                   trash ? nil : model.t(.folderInfo)].compactMap { $0 }.joined(separator: "\n")
        return HStack(spacing: T.Space.s50) {
            if !model.dockedLibrary && !model.libraryOverlay {
                IconButton(.library, label: model.t(.libraryShow)) { model.libraryOverlay = true }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(trash ? model.t(.trashTitle) : model.folder?.name ?? "").textStyle(.heading).lineLimit(1)
                Caption(line).lineLimit(1).truncationMode(.tail)
                if !serial.isEmpty { Caption(serial).lineLimit(1).truncationMode(.tail) }
            }
            .padding(.vertical, T.Space.s50)
            .contentShape(Rectangle())
            .help(tip)
            // Clicking the folder header shows its totals in the inspector (FolderStats).
            .onTapGesture { if !trash, model.folder != nil { model.showFolderInfo() } }
            .accessibilityAddTraits(trash ? [] : .isButton)
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
        let ko = model.language == .ko
        // The body as posted (no title line, no Markdown marks); trashed rows keep the stored counts.
        let c = trash ? sheet.counts : model.postedCounts(of: sheet)
        let length = ko ? model.t(.countCharsShort, ["count": c.chars], count: c.chars)
                        : model.t(.countWords, ["count": c.words], count: c.words)
        let lengthFull = ko ? model.t(.countWithSpaces, ["count": c.chars], count: c.chars) : model.t(.countWithSpaces, ["count": c.chars], count: c.chars)
        // The modified time left the row (2026-10-24 review): it lives in this tooltip and the inspector.
        let rowHelp = [model.t(.countPostedHint, ["raw": sheet.counts.chars]), model.t(.infoModified) + " " + model.dateTime(sheet.modified.date)].joined(separator: "\n")
        HStack(alignment: .top, spacing: T.Space.s100) {
            VStack(alignment: .leading, spacing: T.Space.s25) {
                HStack(spacing: T.Space.s50) {
                    Text(sheet.title.isEmpty ? model.t(.sheetUntitled) : sheet.title)
                        .textStyle(.body, weight: T.Typography.heading.weight)
                        .foregroundStyle(sheet.title.isEmpty ? Color.inkTertiary : .inkPrimary)
                        .lineLimit(1)
                    // Two shapes, not only two colours: damaged = file with a warning mark, branched = a branch.
                    if sheet.damaged { Icon(.damaged, size: T.Size.iconSm, color: .stateDanger).help(model.t(.sheetDamagedHint)).accessibilityLabel(model.t(.sheetDamagedShort)) }
                    else if sheet.branched { Icon(.branched, size: T.Size.iconSm, color: .stateWarning).help(model.t(.sheetBranched)).accessibilityLabel(model.t(.sheetBranched)) }
                }
                if !sheet.excerpt.isEmpty {
                    Text(sheet.excerpt).textStyle(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1)
                }
                // One meta line, always (title · excerpt · meta = at most 3 lines in every language):
                // "4화 · 예약 10/26 18:00 · 4,812자". The length never truncates; a long episode label does.
                HStack(spacing: T.Space.s100) {
                    if let e = sheet.episode {
                        Text(model.episodeLabel(e)).foregroundStyle(e.status == .published ? Color.inkTertiary : .accentPrimary)
                            .truncationMode(.tail)
                    }
                    Text(length).help(lengthFull).fixedSize().layoutPriority(1)
                    if trash { Text(model.folderName(sheet.folder) ?? "").truncationMode(.tail) }
                }
                .lineLimit(1)
                .textStyle(.caption)
                .foregroundStyle(Color.inkTertiary)
                .padding(.top, T.Space.s25)
            }
            Spacer(minLength: 0)
            if model.readOnly {
                // Read-only library: no trash, restore or delete buttons.
            } else if trash {
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
        .help(trash ? "" : rowHelp)
        .onHover { hover = $0 }
        .onTapGesture {
            guard !trash else { return }
            model.openSheet(sheet.id)
            model.inspectorScope = .sheet
            model.libraryOverlay = false
        }
        .contextMenu { if !trash { menu } }
        .draggable(sheet.id) {
            Text(sheet.title.isEmpty ? model.t(.sheetUntitled) : sheet.title).padding(T.Space.s100).background(Color.surfaceRaised)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard !trash, !model.readOnly, let id = ids.first, id != sheet.id else { return false }
            model.move(sheet: id, to: sheet.folder, before: sheet.id)
            return true
        } isTargeted: { dropAbove = $0 && !trash && !model.readOnly }
    }

    @ViewBuilder private var menu: some View {
        if !model.readOnly {
            Button(model.t(.sheetMoveUp)) { model.openSheet(sheet.id); model.moveSheet(-1) }
            Button(model.t(.sheetMoveDown)) { model.openSheet(sheet.id); model.moveSheet(1) }
        }
        let others = model.readOnly ? [] : model.folders.filter { $0.id != sheet.folder }
        if !others.isEmpty {
            Menu(model.t(.sheetMove)) {
                ForEach(others) { f in Button(f.name) { model.move(sheet: sheet.id, to: f.id, before: nil) } }
            }
        }
        if !model.readOnly && (sheet.episode != nil || sheet.folder == model.folders.first?.id) {
            Divider()
            if sheet.episode != nil {
                Button(model.t(.episodePublishedThrough)) { model.markPublishedThrough(sheet.id) }
            }
            Toggle(model.t(.episodeExclude), isOn: Binding(get: { sheet.episode?.excluded == true }, set: { _ in model.toggleExcluded(sheet.id) }))
        }
        Divider()
        Button(model.t(.navHistory)) { model.openSheet(sheet.id); model.show(.history) }
        Button(model.t(.sheetCopyForPaste)) { model.openSheet(sheet.id); model.copyForPaste() }
        Button(model.t(.exportTitle) + "…") { model.openSheet(sheet.id); model.show(.export) }
        if !model.readOnly {
            Divider()
            Button(model.t(.sheetTrash), role: .destructive) { model.trashSheet(sheet.id) }
        }
    }
}
