// The one command list the menu bar, the palette (⌘K) and Settings → Shortcuts share (app-shell spec: same source).
// Each command has its label, its key equivalent (one place, so the menu, the palette row and the list can't disagree),
// when it's available and what it does.
import AppKit
import IthacaCore
import IthacaDesign
import SwiftUI

enum AppCommand: CaseIterable {
    case newSheet, newPage, newProject, search, focus, sheetInfo, history, export, copyForPaste, projectSettings, settings, moveUp, moveDown, showTrash, trashSheet, importWeb
    // Episodes (2026-10-24 review): the daily serial steps without the context menu.
    case publishedThrough, renumber, toggleExclude, statusDraft, statusRevising, statusScheduled, statusPublished
    // The menu bar's editing and view commands, so the palette finds them by name too.
    case importTextFolder, saveNow, previousSheet, nextSheet, findInSheet, findNext, findPrevious
    case bold, italic, strike, heading1, heading2, heading3, body, quote, sceneBreak, symbols
    case showLibrary, showList, editorOnly, mini, inspector, palette, textBigger, textSmaller, textReset
    // Story bible (design/screens/story-bible §1 · §6): new entries, an entry from the selection, a field, the import.
    case newCharacter, newPlace, newGroup, newTerm, entryCharacter, entryPlace, entryGroup, entryTerm, addField, importBible
    // Story bible (story-bible spec §2 · §3).
    case completeName, entryCard
    // author's note (app-shell spec section on manuscripts and blank pages).
    case copyNote

    var label: L10nKey {
        switch self {
        case .newSheet: .sheetNew
        case .newPage: .newSheetPage
        case .copyNote: .noteCopy
        case .newProject: .libraryNewProject
        case .search: .searchTitle
        case .focus: .focusTitle
        case .sheetInfo: .paletteSheetInfo
        case .history: .historyTitle
        case .export: .exportTitle
        case .projectSettings: .projectSettingsTitle
        case .settings: .prefsTitle
        case .moveUp: .sheetMoveUp
        case .moveDown: .sheetMoveDown
        case .showTrash: .trashTitle
        case .trashSheet: .sheetTrash
        case .importWeb: .importWeb
        case .copyForPaste: .sheetCopyForPaste
        case .publishedThrough: .episodePublishedThrough
        case .renumber: .episodeRenumber
        case .toggleExclude: .episodeExclude
        case .statusDraft: .episodeStatusDraft
        case .statusRevising: .episodeStatusRevising
        case .statusScheduled: .episodeStatusScheduled
        case .statusPublished: .episodeStatusPublished
        case .importTextFolder: .importTextFolder
        case .saveNow: .menuSaveNow
        case .previousSheet: .sheetPrevious
        case .nextSheet: .sheetNext
        case .findInSheet: .menuFindInSheet
        case .findNext: .menuFindNext
        case .findPrevious: .menuFindPrevious
        case .bold: .shortcutsBold
        case .italic: .shortcutsItalic
        case .strike: .formatStrike
        case .heading1: .formatHeading1
        case .heading2: .formatHeading2
        case .heading3: .formatHeading3
        case .body: .formatBody
        case .quote: .formatQuote
        case .sceneBreak: .formatSceneBreak
        case .symbols: .formatSymbols
        case .showLibrary: .shortcutsShowLibrary
        case .showList: .shortcutsShowList
        case .editorOnly: .shortcutsEditorOnly
        case .mini: .miniTitle
        case .inspector: .inspectorTitle
        case .palette: .paletteTitle
        case .textBigger: .menuTextBigger
        case .textSmaller: .menuTextSmaller
        case .textReset: .menuTextReset
        case .newCharacter, .newPlace, .newGroup, .newTerm: entryKind!.newLabel
        case .entryCharacter, .entryPlace, .entryGroup, .entryTerm: .entryFromSelection
        case .addField: .entryAddField
        case .importBible: .importBibleTitle
        case .completeName: .bibleCompleteName
        case .entryCard: .bibleCardTitle
        }
    }

    /// The kind a story bible command creates (new entry, or one from the selection).
    var entryKind: EntryKind? {
        switch self {
        case .newCharacter, .entryCharacter: .character
        case .newPlace, .entryPlace: .place
        case .newGroup, .entryGroup: .group
        case .newTerm, .entryTerm: .term
        default: nil
        }
    }

    /// From the selection: "Make Story Bible Entry · Character" (the context menu nests the kinds instead).
    var fromSelection: Bool { [.entryCharacter, .entryPlace, .entryGroup, .entryTerm].contains(self) }

    /// The key equivalent. Checked for clashes in Settings → Shortcuts (every one listed there once).
    var keys: KeyboardShortcut? {
        switch self {
        case .newSheet: KeyboardShortcut("n")
        case .newProject: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .export: KeyboardShortcut("e", modifiers: [.command, .shift])
        case .saveNow: KeyboardShortcut("s")
        case .findInSheet: KeyboardShortcut("f")
        case .findNext: KeyboardShortcut("g")
        case .findPrevious: KeyboardShortcut("g", modifiers: [.command, .shift])
        case .search: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .bold: KeyboardShortcut("b")
        case .italic: KeyboardShortcut("i")
        case .strike: KeyboardShortcut("x", modifiers: [.command, .shift])
        case .heading1: KeyboardShortcut("1", modifiers: [.command, .option])
        case .heading2: KeyboardShortcut("2", modifiers: [.command, .option])
        case .heading3: KeyboardShortcut("3", modifiers: [.command, .option])
        case .body: KeyboardShortcut("0", modifiers: [.command, .option])
        case .quote: KeyboardShortcut("'", modifiers: [.command, .option])
        case .sceneBreak: KeyboardShortcut(.return, modifiers: [.command, .shift])
        case .symbols: KeyboardShortcut("/")
        // ⌘= works too (AppDelegate's key monitor), as in other Mac apps that show ⌘+.
        case .textBigger: KeyboardShortcut("+")
        case .textSmaller: KeyboardShortcut("-")
        case .textReset: KeyboardShortcut("0")
        case .showLibrary: KeyboardShortcut("1")
        case .showList: KeyboardShortcut("2")
        case .editorOnly: KeyboardShortcut("3")
        case .mini: KeyboardShortcut("4")
        case .inspector: KeyboardShortcut("i", modifiers: [.command, .option])
        case .focus: KeyboardShortcut("d", modifiers: [.command, .shift])
        case .palette: KeyboardShortcut("k")
        case .previousSheet: KeyboardShortcut("[")
        case .nextSheet: KeyboardShortcut("]")
        case .moveUp: KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .moveDown: KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .copyForPaste: KeyboardShortcut("c", modifiers: [.command, .option])
        case .history: KeyboardShortcut("h", modifiers: [.command, .shift])
        // Inside a text (the manuscript, any field) ⌘⌫ still deletes to the line start: AppDelegate hands it to the text.
        case .trashSheet: KeyboardShortcut(.delete, modifiers: .command)
        // The Settings scene's own menu item; listed here for the palette row and the shortcut list.
        case .settings: KeyboardShortcut(",")
        // NSTextView's own `complete:` key; the menu item makes it findable (Edit › Insert Name).
        case .completeName: KeyboardShortcut(.escape, modifiers: .option)
        case .entryCard: KeyboardShortcut("r", modifiers: [.command, .option])
        default: nil
        }
    }

    /// "⌥⌘1", "⇧⌘↩": the Mac menu notation (modifiers in ⌃⌥⇧⌘ order, then the key).
    var keysLabel: String? { keys.map(Self.label) }

    static func label(_ k: KeyboardShortcut) -> String {
        var s = ""
        if k.modifiers.contains(.control) { s += "⌃" }
        if k.modifiers.contains(.option) { s += "⌥" }
        if k.modifiers.contains(.shift) { s += "⇧" }
        if k.modifiers.contains(.command) { s += "⌘" }
        switch k.key {
        case .return: s += "↩"
        case .delete: s += "⌫"
        case .upArrow: s += "↑"
        case .downArrow: s += "↓"
        case .escape: s += "⎋"
        default: s += String(k.key.character).uppercased()
        }
        return s
    }

    /// Listed in the palette only once something is typed, so the empty list stays short: episode status, and the
    /// editing · view keys the writer already has under the fingers.
    var typedOnly: Bool {
        if status != nil || format != nil || entryKind != nil { return true }
        return switch self {
        case .symbols, .findNext, .findPrevious, .textBigger, .textSmaller, .textReset, .showLibrary, .showList, .editorOnly, .completeName: true
        default: false
        }
    }

    var status: EpisodeStatus? {
        switch self {
        case .statusDraft: .draft
        case .statusRevising: .revising
        case .statusScheduled: .scheduled
        case .statusPublished: .published
        default: nil
        }
    }

    var format: TextFormat? {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .strike: .strike
        case .heading1: .heading(1)
        case .heading2: .heading(2)
        case .heading3: .heading(3)
        case .body: .body
        case .quote: .quote
        case .sceneBreak: .sceneBreak
        default: nil
        }
    }

    /// Commands that act on the manuscript view (it needs the focus back when run from the palette).
    var editing: Bool { format != nil || [.symbols, .findInSheet, .findNext, .findPrevious, .addField, .completeName, .entryCard].contains(self) }

    /// What the palette shows (some labels depend on the open sheet).
    @MainActor func title(_ m: AppModel) -> String {
        if status != nil { return m.t(.paletteSetStatus, ["status": m.t(label)]) }
        if self == .toggleExclude, m.sheet?.episode?.excluded == true { return m.t(.episodeInclude) }
        if fromSelection, let k = entryKind { return m.t(.entryFromSelectionAs, ["kind": m.t(k.label)]) }
        if self == .addField || self == .importBible { return m.t(label) + "…" }
        return m.t(label)
    }

    var icon: IthacaIcon {
        switch self {
        case .newSheet: .add
        case .newPage: .sheet
        case .copyNote: .copy
        case .newProject: .folder
        case .search, .findInSheet, .findNext, .findPrevious: .search
        case .focus, .editorOnly: .focus
        case .mini: .mini
        case .sheetInfo, .inspector: .stats
        case .history: .history
        case .export: .export
        case .projectSettings, .settings: .settings
        case .moveUp, .previousSheet: .collapsed
        case .moveDown, .nextSheet: .expanded
        case .showTrash: .trash
        case .trashSheet: .delete
        case .importWeb: .backup
        case .importTextFolder: .folderOpen
        case .copyForPaste: .copy
        case .publishedThrough, .saveNow: .check
        case .renumber: .reorder
        case .showLibrary, .showList: .library
        case .palette: .search
        case .toggleExclude, .bold, .italic, .strike, .heading1, .heading2, .heading3, .body, .quote, .sceneBreak, .symbols,
             .textBigger, .textSmaller, .textReset: .edit
        case .statusDraft, .statusRevising, .statusScheduled, .statusPublished: .sheet
        case .newCharacter, .newPlace, .newGroup, .newTerm, .entryCharacter, .entryPlace, .entryGroup, .entryTerm: entryKind!.icon
        case .addField: .add
        case .importBible: .folderOpen
        case .completeName, .entryCard: .entryCharacter
        }
    }

    /// Same rule as the menu bar's disabled items: sheet commands need an open sheet, project commands a project.
    @MainActor func available(_ m: AppModel) -> Bool {
        // Read-only library: nothing that writes.
        if m.readOnly, [.newSheet, .newPage, .newProject, .moveUp, .moveDown, .trashSheet, .importWeb, .importTextFolder, .publishedThrough,
                        .renumber, .toggleExclude, .saveNow, .addField, .importBible].contains(self) { return false }
        if m.readOnly, entryKind != nil { return false }
        if fromSelection { return m.sheetId != nil && !m.editorLocked && !StoryBible.name(fromSelection: m.editor?.selectedText ?? "").isEmpty }
        if entryKind != nil { return m.projectId != nil }
        if m.readOnly, status != nil { return false }
        if let status { return m.sheetId != nil && m.sheet?.episode?.status != status }
        if format != nil || self == .symbols || self == .completeName { return m.sheetId != nil && !m.editorLocked }
        if self == .entryCard { return m.sheetId != nil && !m.bible.isEmpty }
        return switch self {
        case .sheetInfo, .history, .moveUp, .moveDown, .trashSheet, .copyForPaste, .saveNow, .previousSheet, .nextSheet,
             .findInSheet, .findNext, .findPrevious, .copyNote: m.sheetId != nil
        case .publishedThrough: m.sheet?.episode != nil
        case .toggleExclude: m.sheet != nil && (m.sheet?.episode != nil || m.sheet?.folder == m.folders.first?.id)
        case .renumber: m.folder != nil
        case .export, .projectSettings, .showTrash, .newSheet, .newPage, .importBible: m.projectId != nil
        case .addField: !m.editorLocked && m.openEntryKind != nil
        case .palette: false  // already open when the palette asks
        default: true
        }
    }

    @MainActor func run(_ m: AppModel) {
        switch self {
        case .newSheet: m.newSheet()
        case .newPage: m.newSheet(.page)
        case .copyNote: m.copyAuthorNote()
        case .newProject: m.show(.newProject(firstRun: false))
        case .search: m.overlay = .palette(search: true)
        case .focus: m.toggleFocus()
        case .editorOnly: m.toggleEditorOnly()
        case .mini: m.toggleMini()
        case .sheetInfo: m.inspectorOpen = true; AppEnvironment.defaults.set(InspectorTab.info.rawValue, forKey: "ithaca.inspectorTab")
        case .history: if m.sheetId != nil { m.show(.history) }
        case .export: if m.projectId != nil { m.show(.export) }
        case .projectSettings: if m.projectId != nil { m.show(.projectSettings) }
        case .settings: openSettingsWindow()
        case .moveUp: m.moveSheet(-1)
        case .moveDown: m.moveSheet(1)
        case .showTrash: m.showingTrash = true; if !m.dockedList { m.libraryOverlay = true }
        case .trashSheet: m.trashSheet()
        case .importWeb: m.importWebBackup()
        case .importTextFolder: m.importTextFolder()
        case .copyForPaste: m.copyForPaste()
        case .publishedThrough: m.markPublishedThrough()
        case .renumber: m.renumberEpisodes()
        case .toggleExclude: if let id = m.sheetId { m.toggleExcluded(id) }
        case .statusDraft, .statusRevising, .statusScheduled, .statusPublished: m.setEpisodeStatus(status)
        case .saveNow: m.flushSave()
        case .previousSheet: m.openAdjacentSheet(-1)
        case .nextSheet: m.openAdjacentSheet(1)
        case .findInSheet: m.editor?.showFindBar()
        case .findNext: m.editor?.findNext(true)
        case .findPrevious: m.editor?.findNext(false)
        case .bold, .italic, .strike, .heading1, .heading2, .heading3, .body, .quote, .sceneBreak: if let f = format { m.editor?.format(f) }
        case .symbols: m.editor?.showSymbols()
        case .showLibrary:
            m.showPanes()
            if !m.dockedLibrary { m.libraryOverlay.toggle() }
        case .showList:
            m.showPanes()
            if !m.dockedList { m.libraryOverlay.toggle() }
        case .inspector: m.toggleInspector()
        case .palette: m.show(.palette(search: false))
        case .textBigger: m.stepTextSize(1)
        case .textSmaller: m.stepTextSize(-1)
        case .textReset: m.stepTextSize(0)
        case .newCharacter, .newPlace, .newGroup, .newTerm: m.newEntry(entryKind!)
        case .entryCharacter, .entryPlace, .entryGroup, .entryTerm: m.makeEntryFromSelection(entryKind!)
        case .addField: m.editor?.showAddFieldMenu()
        case .importBible: m.importBible()
        case .completeName: m.editor?.completeName()
        case .entryCard: m.editor?.showEntryCard()
        }
    }

    /// From the palette: it closes first; editing commands then wait a turn so the manuscript has the focus again
    /// (the symbol menu opens at the caret, formatting acts on the selection).
    @MainActor func runFromPalette(_ m: AppModel) {
        m.overlay = nil
        guard editing else { run(m); return }
        m.editor?.focus()
        DispatchQueue.main.async { run(m) }
    }

    /// Settings → Shortcuts: every key equivalent once, grouped like the menus.
    static let shortcutGroups: [(L10nKey, [AppCommand])] = [
        (.shortcutsGroupGeneral, [.newSheet, .newProject, .palette, .search, .saveNow, .export, .history, .settings]),
        (.shortcutsGroupView, [.showLibrary, .showList, .editorOnly, .mini, .focus, .inspector, .entryCard, .textBigger, .textSmaller, .textReset]),
        (.shortcutsGroupFormat, [.bold, .italic, .strike, .heading1, .heading2, .heading3, .body, .quote, .sceneBreak, .symbols, .completeName]),
        (.shortcutsGroupSheet, [.previousSheet, .nextSheet, .moveUp, .moveDown, .findInSheet, .findNext, .findPrevious, .copyForPaste, .trashSheet]),
    ]
}
