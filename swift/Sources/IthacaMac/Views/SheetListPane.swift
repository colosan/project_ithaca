// Sheet list: the open folder's sheets in serial order (drag to reorder, ⌥⌘↑↓), or the trash.
// Keyboard (once a row is clicked): ↑↓ open the sheet above/below, Return · Tab · → go to the editor,
// Delete trashes, typing a title's first letters (or a Korean initial consonant) jumps to it.
import IthacaDesign
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A sheet being dragged inside Ithaca. Not plain text: dropped into the manuscript or another app it must not
    /// paste the sheet's id (a String payload did). Declared in Info.plist (UTExportedTypeDeclarations).
    static let ithacaSheet = UTType(exportedAs: "io.github.colosan.ithaca.sheet")
}

struct SheetDrag: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .ithacaSheet) }
}

struct SheetListPane: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    /// The editor takes the keyboard whenever it loads a sheet; a switch made from the list (click, ↑↓, type-select)
    /// hands it back to the list afterwards.
    @State private var keepFocus = false

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
                        VStack(spacing: T.Space.s150) {
                            Caption(trash ? model.t(.trashEmptyState) : model.t(.sheetListEmpty))
                            if !trash, let f = model.folder, !model.readOnly {
                                KitButton(model.t(.sheetNew), icon: .add) { model.newSheet(in: f.id) }
                            }
                        }
                        .padding(T.Space.s300)
                    }
                    ForEach(sheets) { s in
                        SheetRow(sheet: s, trash: trash, active: !trash && s.id == model.sheetId, listFocused: listFocused) {
                            keepFocus = true
                            listFocused = true
                        }
                        .id(s.id)
                    }
                    // Dropping below the last row moves a sheet to the end.
                    Color.clear.frame(height: T.Size.rowSheet)
                        .dropDestination(for: SheetDrag.self) { items, _ in
                            guard !trash, !model.readOnly, let id = items.first?.id, let f = model.folder else { return false }
                            model.move(sheet: id, to: f.id, before: nil)
                            return true
                        }
                }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in key(press, sheets: sheets) ? .handled : .ignored }
            .onChange(of: model.listFocusRequest) { listFocused = true }
            .onChange(of: model.loadToken) {
                guard keepFocus else { return }
                keepFocus = false
                DispatchQueue.main.async { listFocused = true }
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

    /// The list's keyboard. Modified keys go on to the menus (⌘⌫ trash, ⌥⌘↑↓ move, ⌘[ ⌘]).
    private func key(_ press: KeyPress, sheets: [SheetSummary]) -> Bool {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]), !model.showingTrash else { return false }
        let i = sheets.firstIndex { $0.id == model.sheetId }
        func open(_ j: Int) {
            guard sheets.indices.contains(j), sheets[j].id != model.sheetId else { return }
            keepFocus = true
            model.openSheet(sheets[j].id)
        }
        switch press.key {
        case .upArrow: open(i.map { $0 - 1 } ?? 0); return true
        case .downArrow: open(i.map { $0 + 1 } ?? 0); return true
        case .home: open(0); return true
        case .end: open(sheets.count - 1); return true
        case .return, .tab, .rightArrow:
            guard model.sheetId != nil else { return false }
            model.libraryOverlay = false
            model.editor?.focus()
            return true
        // Backspace arrives as U+007F (KeyEquivalent.delete is U+0008).
        case .delete, .deleteForward, KeyEquivalent("\u{7f}"):
            if model.sheetId != nil { model.trashSheet() }
            return true
        case .escape: return false
        default: break
        }
        // Type-select: letters typed within a second add up; a typed Hangul initial consonant matches syllables starting with it.
        let chars = press.characters
        // Function keys (F1, Page Up…) come as private-use characters: not text.
        guard !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
                                                               && !(0xF700...0xF8FF).contains($0.value) }),
              !(typed.isEmpty && chars == " ") else { return false }
        let now = Date()
        typed = now.timeIntervalSince(typedAt) < 1 ? typed + chars : chars
        typedAt = now
        if let hit = sheets.firstIndex(where: { Self.typeSelectMatches(typed, $0.title) }) { open(hit) }
        return true
    }

    /// Case-insensitive title prefix; a typed Hangul consonant (ㄱ…ㅎ) also matches a syllable that starts with it.
    nonisolated static func typeSelectMatches(_ typed: String, _ title: String) -> Bool {
        let t = Array(title.lowercased()), q = Array(typed.lowercased())
        guard !q.isEmpty, t.count >= q.count else { return false }
        return zip(q, t).allSatisfy { c, x in c == x || initialConsonant(x) == c }
    }

    nonisolated static func initialConsonant(_ c: Character) -> Character? {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(v) else { return nil }
        return Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")[Int((v - 0xAC00) / 588)]
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
    /// The list has keyboard focus: the open row shows the accent selection, like a focused Mac list.
    var listFocused = false
    /// A click takes keyboard focus into the list (↑↓ · Return · Delete · type-select).
    var focusList: () -> Void = {}
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
        .background(active ? (listFocused ? Color.accentSoft : .surfaceSelected) : hover && !trash ? Color.surfaceSelected.opacity(0.5) : .clear)
        .overlay(alignment: .top) { if dropAbove { Rectangle().fill(Color.accentPrimary).frame(height: T.Size.strokeFocus) } }
        .hairline(.bottom)
        .contentShape(Rectangle())
        .help(trash ? "" : rowHelp)
        .onHover { hover = $0 }
        .onTapGesture {
            guard !trash else { return }
            // The open row again: don't reload it from disk (that reset the editor for nothing).
            if sheet.id != model.sheetId { model.openSheet(sheet.id) }
            model.inspectorScope = .sheet
            model.libraryOverlay = false
            focusList()
        }
        // Double-click: open and start writing.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !trash, sheet.id == model.sheetId else { return }
            model.editor?.focus()
        })
        .contextMenu { if !trash { menu } }
        .draggable(SheetDrag(id: sheet.id)) {
            Text(sheet.title.isEmpty ? model.t(.sheetUntitled) : sheet.title).padding(T.Space.s100).background(Color.surfaceRaised)
        }
        .dropDestination(for: SheetDrag.self) { items, _ in
            guard !trash, !model.readOnly, let id = items.first?.id, id != sheet.id else { return false }
            model.move(sheet: id, to: sheet.folder, before: sheet.id)
            return true
        } isTargeted: { dropAbove = $0 && !trash && !model.readOnly }
    }

    @ViewBuilder private var menu: some View {
        if !model.readOnly {
            Button(model.t(.sheetNew)) { model.newSheet(in: sheet.folder) }
            Button(model.t(.sheetDuplicate)) { model.duplicateSheet(sheet.id) }
            Divider()
            Button(model.t(.sheetMoveUp)) { model.openSheet(sheet.id); model.moveSheet(-1) }
            Button(model.t(.sheetMoveDown)) { model.openSheet(sheet.id); model.moveSheet(1) }
        }
        let others = model.readOnly ? [] : model.folders.filter { $0.id != sheet.folder }
        if !others.isEmpty {
            Menu(model.t(.sheetMove)) {
                ForEach(others) { f in Button(f.name) { model.move(sheet: sheet.id, to: f.id, before: nil) } }
            }
        }
        if !model.readOnly {
            Divider()
            Picker(model.t(.episodeStatus), selection: Binding(get: { sheet.episode?.status }, set: { model.setEpisodeStatus($0, sheet: sheet.id) })) {
                Text(model.t(.episodeNone)).tag(EpisodeStatus?.none)
                ForEach(EpisodeStatus.allCases, id: \.self) { s in Text(model.t(model.statusKey(s))).tag(EpisodeStatus?.some(s)) }
            }
            .pickerStyle(.menu)
        }
        if !model.readOnly && (sheet.episode != nil || sheet.folder == model.folders.first?.id) {
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
