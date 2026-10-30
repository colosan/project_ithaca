// App state over LibraryAPI: selection, the open sheet's buffer and its saving, panes, dialogs, toasts, preferences.
// Behavior is ported from the web app that went through three rounds of user testing (app-web/src).
import AppKit
import IthacaDesign
import Observation
import SwiftUI

enum Overlay: Identifiable, Equatable {
    case palette(search: Bool)
    case export
    case history
    case newProject(firstRun: Bool)
    case projectSettings
    /// Files a text-folder import left out (`AppModel.importSkipped`).
    case importSkipped
    /// File → Import Story Bible: the kind picker and preview of a Notion .md file or folder.
    case importBible(path: String)
    var id: String {
        switch self {
        case .palette: "palette"
        case .export: "export"
        case .history: "history"
        case .newProject: "newProject"
        case .projectSettings: "projectSettings"
        case .importSkipped: "importSkipped"
        case .importBible: "importBible"
        }
    }
}

enum InspectorScope: String, CaseIterable { case sheet, folder }

enum SaveStatus: Equatable { case saved, pending, failed(String) }

/// What to do when the open sheet can't be saved and something wants to replace it (switch, close, quit).
enum SaveFailureChoice { case retry, copy, export, quitAnyway, cancel }

/// The pauses the app waits for (autosave, retry, mention refresh, undo break). The editor self-test shortens them all
/// alike so its checks wait for the same things in a fraction of the time.
enum Wait {
    nonisolated(unsafe) static var scale = 1.0
    static func ms(_ n: Double) -> Duration { .milliseconds(n * scale) }
}

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var undo: (() -> Void)?
    var sticky = false
    /// The button's label when it isn't "Undo" (e.g. "Open" for an entry made from the selection).
    var action: String? = nil
}

enum TextSize: String, CaseIterable { case small, normal, large }
/// Editor line height = the text-size token's line height × this.
enum LineSpacing: String, CaseIterable {
    case normal, wide, wider
    var scale: Double { switch self { case .normal: 1; case .wide: 1.2; case .wider: 1.4 } }
}
/// Editor line length cap = `editor.measure` × this.
enum LineWidth: String, CaseIterable {
    case narrow, normal, wide
    var scale: Double { switch self { case .narrow: 0.85; case .normal: 1; case .wide: 1.2 } }
}
enum ThemePref: String, CaseIterable { case system, light, dark }
enum MarkupMode: String, CaseIterable { case show, dim, hide }
enum FocusScope: String, CaseIterable { case sentence, paragraph }
/// `...` typed in the manuscript: left alone, or turned into `…` / `……` (editor conveniences).
enum EllipsisMode: String, CaseIterable {
    case off, single, double
    var replacement: String? { switch self { case .off: nil; case .single: "…"; case .double: "……" } }
}

/// What the model needs from the text view without owning it (ManuscriptView's coordinator implements it).
@MainActor
protocol EditorBridge: AnyObject {
    var isComposing: Bool { get }
    /// Ends any IME composition so the text can be saved or replaced safely.
    func commitComposition()
    func select(_ range: NSRange, center: Bool)
    func focus()
    func showFindBar()
    var caretLocation: Int { get }
    /// Markdown formatting and symbol insertion on the selection, as one undo step each.
    func format(_ f: TextFormat)
    func insert(_ text: String, wrapping close: String?)
    func showSymbols()
    func findNext(_ forward: Bool)
    // Story bible (EditorEntries.swift)
    /// The selected text ("" when nothing is selected).
    var selectedText: String { get }
    /// Appends a `## title` section at the end of the sheet as one undo step, caret on the line below it.
    func appendSection(_ title: String)
    /// "Add Field" as a menu at the caret (the palette's command).
    func showAddFieldMenu()
    /// ⌥Esc (Edit › Insert Name): word completion with the story bible's names first.
    func completeName()
    /// ⌥⌘R (View › Story Bible Card): the card of the name at the caret. False when the caret isn't on a name.
    @discardableResult func showEntryCard() -> Bool
}

enum NewSheetKind { case manuscript, page }

enum TextFormat { case bold, italic, strike, heading(Int), body, quote, sceneBreak }

@MainActor
@Observable
final class AppModel {
    nonisolated static let editorMin: Double = 600

    let library: LibraryAPI
    private(set) var info: LibraryInfo
    /// The open-time problems banner (skipped projects…) was closed; Settings → Backup still lists them.
    var problemsDismissed = false

    // MARK: Data
    private(set) var projects: [ProjectSummary] = []
    private(set) var outline: Outline?
    private(set) var projectId: String?
    private(set) var folderId: String?
    private(set) var sheetId: String?
    var showingTrash = false

    // MARK: Open sheet buffer
    /// The text view owns the live text; this is the last copy it handed over (not observed per keystroke).
    /// While typing the editor only says "changed" (`textDidChange(token:pull:)`); the copy is made when something reads
    /// it (save, counts, export) — copying, normalizing and comparing 100k+ characters per keystroke was the typing lag.
    private(set) var text: String {
        get {
            if let pull = pendingPull { pendingPull = nil; buffer = pull().normalizedNewlines }
            return buffer
        }
        set { pendingPull = nil; buffer = newValue }
    }
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var pendingPull: (() -> String)?
    /// Bumped when the editor must load `text` (sheet switch, history restore). Never during typing.
    private(set) var loadToken = 0
    /// Debounced copy of the counts for the footer/inspector — counting 10k characters per keystroke is wasted work.
    private(set) var liveCounts = Counts()
    private(set) var liveText = ""
    private(set) var saveStatus: SaveStatus = .saved
    @ObservationIgnored private(set) var dirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Failed saves retry on a backoff (2 s, 5 s, 15 s, 30 s, then every 60 s) until one succeeds.
    @ObservationIgnored private var retryAttempt = 0
    nonisolated static let retryDelays: [Double] = [2, 5, 15, 30, 60]
    /// Selftests: when set, every save throws this message (simulates a disk that refuses writes).
    @ObservationIgnored var debugSaveError: String?
    /// Selftests: answers the save-failure alert instead of a modal NSAlert. Argument: quitting.
    @ObservationIgnored var saveFailurePrompt: ((Bool) -> SaveFailureChoice)?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var countGeneration = 0
    @ObservationIgnored private var caretTask: Task<Void, Never>?
    @ObservationIgnored weak var editor: EditorBridge?

    // MARK: View state
    var inspectorOpen = false
    /// Info tab: the open sheet, or totals of the open folder (folder header / "Folder info").
    var inspectorScope: InspectorScope = .sheet
    var focusMode = false
    /// ⌘3: side panes hidden without focus-mode dimming.
    var editorOnly = false
    /// ⌘4: the window becomes a small sticky note over other apps — just the sheet being written (`MiniWindow`).
    var mini: Bool { didSet { defaults.set(mini, forKey: "ithaca.mini") } }
    var panesHidden: Bool { focusMode || editorOnly || mini }
    /// Overlay request for panes that can't dock at this width (⌘1 / ⌘2, the library button).
    var libraryOverlay = false
    var overlay: Overlay?
    /// Text the palette opens with (snapshots; could serve "search for selection" later).
    @ObservationIgnored var paletteSeed = ""
    var toast: Toast?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Panes that are docked right now (set by the shell from the window width).
    var dockedLibrary = true
    var dockedList = true
    /// The inspector would dock at this width if open (false: it opens as an overlay over the editor).
    var inspectorDocks = true
    /// Bumped to move keyboard focus into the sheet list (the list observes it).
    var listFocusRequest = 0

    // MARK: Preferences (UserDefaults)
    var theme: ThemePref { didSet { defaults.set(theme.rawValue, forKey: "ithaca.theme"); applyTheme() } }
    var textSize: TextSize { didSet { defaults.set(textSize.rawValue, forKey: "ithaca.textSize") } }
    var lineSpacing: LineSpacing { didSet { defaults.set(lineSpacing.rawValue, forKey: "ithaca.lineSpacing") } }
    var lineWidth: LineWidth { didSet { defaults.set(lineWidth.rawValue, forKey: "ithaca.lineWidth") } }
    var markup: MarkupMode { didSet { defaults.set(markup.rawValue, forKey: "ithaca.markup") } }
    var focusScope: FocusScope { didSet { defaults.set(focusScope.rawValue, forKey: "ithaca.focusScope") } }
    var typewriter: Bool { didSet { defaults.set(typewriter, forKey: "ithaca.typewriter") } }
    // Editor conveniences (story-bible spec §7), all off by default.
    var firstLineIndent: Bool { didSet { defaults.set(firstLineIndent, forKey: "ithaca.firstLineIndent") } }
    var autoPairs: Bool { didSet { defaults.set(autoPairs, forKey: "ithaca.autoPairs") } }
    var ellipsis: EllipsisMode { didSet { defaults.set(ellipsis.rawValue, forKey: "ithaca.ellipsis") } }
    var textReplacement: Bool { didSet { defaults.set(textReplacement, forKey: "ithaca.textReplacement") } }
    // Story bible display (spec §3 · §5), both off by default.
    var underlineNames: Bool { didSet { defaults.set(underlineNames, forKey: "ithaca.underlineNames") } }
    var hoverCard: Bool { didSet { defaults.set(hoverCard, forKey: "ithaca.hoverCard") } }

    // MARK: Story bible (AppModel+Bible.swift)
    /// The open project's entries, most recently seen first. Written only by AppModel+Bible.swift.
    var bible: [BibleEntry] = []
    /// Mentions in the open sheet's text (inspector, underline), 1 s after typing stops. Written only by AppModel+Bible.swift.
    var sheetMentions: [Mention] = []
    /// Bumped whenever `sheetMentions` is recomputed (the editor redraws underlines once per bump).
    var mentionsGeneration = 0
    @ObservationIgnored var bibleProject: String?
    @ObservationIgnored var bibleTask: Task<Void, Never>?
    @ObservationIgnored var mentionsTask: Task<Void, Never>?
    /// The ⌘/ symbol menu, in the writer's order. Stored only while it differs from the defaults.
    var symbols: [Symbol] {
        didSet {
            if symbols == Symbols.defaults { defaults.removeObject(forKey: "ithaca.symbols") } else { defaults.set(Symbols.encode(symbols), forKey: "ithaca.symbols") }
            menu.symbols = symbols
        }
    }
    var confirmDelete: Bool { didSet { defaults.set(confirmDelete, forKey: "ithaca.confirmDelete") } }
    /// nil = follow the manuscript language (on for English, off for Korean — the system checker flags ordinary Korean).
    var spellCheck: Bool? { didSet { defaults.set(spellCheck.map { $0 ? "on" : "off" } ?? "auto", forKey: "ithaca.spell") } }

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let menu: MenuState
    @ObservationIgnored private var carets: [String: Int]

    init(library: LibraryAPI, defaults: UserDefaults = .standard, menu: MenuState = MenuState()) {
        self.library = library
        self.defaults = defaults
        self.menu = menu
        info = library.info()
        theme = ThemePref(rawValue: defaults.string(forKey: "ithaca.theme") ?? "") ?? .system
        textSize = TextSize(rawValue: defaults.string(forKey: "ithaca.textSize") ?? "") ?? .normal
        lineSpacing = LineSpacing(rawValue: defaults.string(forKey: "ithaca.lineSpacing") ?? "") ?? .normal
        lineWidth = LineWidth(rawValue: defaults.string(forKey: "ithaca.lineWidth") ?? "") ?? .normal
        markup = MarkupMode(rawValue: defaults.string(forKey: "ithaca.markup") ?? "") ?? .dim
        focusScope = FocusScope(rawValue: defaults.string(forKey: "ithaca.focusScope") ?? "") ?? .paragraph
        typewriter = defaults.object(forKey: "ithaca.typewriter") as? Bool ?? false
        firstLineIndent = defaults.object(forKey: "ithaca.firstLineIndent") as? Bool ?? false
        autoPairs = defaults.object(forKey: "ithaca.autoPairs") as? Bool ?? false
        ellipsis = EllipsisMode(rawValue: defaults.string(forKey: "ithaca.ellipsis") ?? "") ?? .off
        textReplacement = defaults.object(forKey: "ithaca.textReplacement") as? Bool ?? false
        underlineNames = defaults.object(forKey: "ithaca.underlineNames") as? Bool ?? false
        hoverCard = defaults.object(forKey: "ithaca.hoverCard") as? Bool ?? false
        mini = defaults.object(forKey: "ithaca.mini") as? Bool ?? false
        symbols = Symbols.decode(defaults.array(forKey: "ithaca.symbols")) ?? Symbols.defaults
        confirmDelete = defaults.object(forKey: "ithaca.confirmDelete") as? Bool ?? true
        switch defaults.string(forKey: "ithaca.spell") { case "on": spellCheck = true; case "off": spellCheck = false; default: spellCheck = nil }
        carets = (defaults.dictionary(forKey: "ithaca.carets") as? [String: Int]) ?? [:]
        menu.locale = locale
        menu.symbols = symbols
        menu.readOnly = info.readOnly || info.lockedByOther
        refreshProjects()
        restoreSelection()
        refreshLastBackup()
    }

    // MARK: Locale

    /// Korean only (ADR-0011).
    var locale: L10nLocale { .ko }

    func t(_ key: L10nKey, _ args: [String: Any] = [:], count: Int? = nil) -> String {
        L10n.string(key, locale: locale, args.mapValues { v in (v as? Int).map(number) ?? "\(v)" }, count: count)
    }

    func number(_ n: Int) -> String { n.formatted(.number.locale(Locale(identifier: locale.rawValue))) }

    func applyTheme() {
        NSApp?.appearance = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Derived

    var project: ProjectSummary? { outline?.project }
    var folders: [FolderInfo] { outline?.folders ?? [] }
    var folder: FolderInfo? { folders.first { $0.id == folderId } }
    var sheet: SheetSummary? { folders.lazy.flatMap(\.sheets).first { $0.id == sheetId } }
    var trash: [SheetSummary] { outline?.trash ?? [] }
    var language: ManuscriptLanguage { project?.language ?? (locale == .ko ? .ko : .en) }
    /// Newer-format library, or another Ithaca holds the library's lock: nothing may be written.
    var readOnly: Bool { info.readOnly || info.lockedByOther }
    /// The open sheet can't be typed into: read-only library, or a damaged sheet (shown as its last intact text).
    var editorLocked: Bool { readOnly || sheet?.damaged == true }
    var readOnlyMessage: String {
        switch readOnlyCause {
        case .lockedByOther: t(.libraryLockedByOther)
        case .problems: t(.libraryReadOnlyProblems)
        case .newerFormat, nil: t(.libraryReadOnly)
        }
    }
    /// Why nothing may be written: another Ithaca holds the lock, the core opened it read-only because of
    /// problems it found (missing library.json, failed update…), or — read-only with nothing to report — a newer format.
    enum ReadOnlyCause { case lockedByOther, newerFormat, problems }
    var readOnlyCause: ReadOnlyCause? {
        guard readOnly else { return nil }
        if info.lockedByOther { return .lockedByOther }
        return info.problems.isEmpty ? .newerFormat : .problems
    }

    /// Dates in the app's language: 24-hour clock for Korean, the locale's own clock for English.
    var dateLocale: Locale {
        guard locale == .ko else { return Locale(identifier: locale.rawValue) }
        var c = Locale.Components(identifier: locale.rawValue)
        c.hourCycle = .zeroToTwentyThree
        return Locale(components: c)
    }

    /// "10월 4일 17:49" / "Oct 4, 5:49 PM"; the year only when it isn't this year (or `year`).
    func dateTime(_ d: Date, year: Bool = false) -> String {
        let showYear = year || Calendar.current.component(.year, from: d) != Calendar.current.component(.year, from: Date())
        func fmt(_ template: String) -> String {
            let f = DateFormatter()
            f.locale = dateLocale
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: d)
        }
        // Date and time formatted apart: the joined English template reads "Oct 4 at 7:00 AM" (too long for a row).
        return locale == .ko ? fmt((showYear ? "y" : "") + "MMMd") + " " + fmt("HHmm")
                             : fmt((showYear ? "y" : "") + "MMMd") + ", " + fmt("jmm")
    }
    var spellCheckActive: Bool { spellCheck ?? (language == .en) }

    func folderName(_ id: String) -> String? { folders.first { $0.id == id }?.name }

    // MARK: Loading

    func refreshProjects() {
        projects = library.projects()
        menu.hasProject = !projects.isEmpty
    }

    func reloadOutline() {
        guard let projectId else { outline = nil; return }
        do { outline = try library.outline(project: projectId) } catch { outline = nil }
        menu.hasSheet = sheetId != nil
        outlineDidReload()
    }

    private func restoreSelection() {
        let last = defaults.dictionary(forKey: "ithaca.last") as? [String: String] ?? [:]
        let pid = projects.first { $0.id == last["project"] }?.id ?? projects.first?.id
        guard let pid else { return }
        selectProject(pid, remember: false)
        if let f = last["folder"], folders.contains(where: { $0.id == f }) { folderId = f }
        if let s = last["sheet"], folders.contains(where: { $0.sheets.contains { $0.id == s } }) { openSheet(s) }
    }

    private func rememberSelection() {
        var d: [String: String] = [:]
        d["project"] = projectId; d["folder"] = folderId; d["sheet"] = sheetId
        defaults.set(d, forKey: "ithaca.last")
        // Per project, so switching back returns to the same sheet.
        if let projectId { defaults.set(d, forKey: "ithaca.last.\(projectId)") }
    }

    // MARK: Selection

    func selectProject(_ id: String, remember: Bool = true) {
        guard ensureSaved() else { return }
        projectId = id
        showingTrash = false
        reloadOutline()
        let last = defaults.dictionary(forKey: "ithaca.last.\(id)") as? [String: String] ?? [:]
        folderId = folders.first { $0.id == last["folder"] }?.id ?? folders.first?.id
        let s = last["sheet"].flatMap { s in folders.flatMap(\.sheets).first { $0.id == s }?.id } ?? folder?.sheets.first?.id
        if let s { openSheet(s) } else { closeSheet() }
        if remember { rememberSelection() }
    }

    /// ⌘[ / ⌘]: the sheet above or below in the current folder's list.
    func openAdjacentSheet(_ offset: Int) {
        guard let sheets = folder?.sheets, let i = sheets.firstIndex(where: { $0.id == sheetId }),
              sheets.indices.contains(i + offset) else { return }
        openSheet(sheets[i + offset].id)
    }

    /// ⌘+ / ⌘− / ⌘0 step through the editor text sizes (Settings, Editor).
    func stepTextSize(_ step: Int) {
        let all = TextSize.allCases
        guard step != 0 else { textSize = .normal; return }
        let i = all.firstIndex(of: textSize) ?? 1
        textSize = all[max(0, min(all.count - 1, i + step))]
    }

    func selectFolder(_ id: String) {
        folderId = id
        showingTrash = false
        rememberSelection()
    }

    func openSheet(_ id: String, at range: NSRange? = nil) {
        // Also for the same sheet (search hit, restore): reloading it from disk would drop unsaved typing.
        guard ensureSaved() else { return }
        guard let projectId else { return }
        if let f = folders.first(where: { $0.sheets.contains { $0.id == id } }) { folderId = f.id }
        do {
            text = try library.sheetText(project: projectId, sheet: id).normalizedNewlines
        } catch {
            showToast(Toast(message: "\(error.localizedDescription)"))
            return
        }
        if let range { carets[id] = range.location }
        sheetId = id
        dirty = false
        saveStatus = .saved
        updateCounts(now: true)
        loadToken += 1
        pendingSelection = range
        menu.hasSheet = true
        rememberSelection()
        refreshMentions()
    }

    /// Where the editor should put the selection after the next load (search hits); otherwise the remembered caret.
    @ObservationIgnored var pendingSelection: NSRange?

    func caret(for sheet: String) -> Int? { carets[sheet] }

    func rememberCaret(_ location: Int) {
        guard let sheetId else { return }
        guard carets[sheetId] != location else { return }
        carets[sheetId] = location
        // Every caret move while typing: write the defaults a moment later, not per keystroke.
        caretTask?.cancel()
        caretTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Wait.ms(1000))
            guard let self, !Task.isCancelled else { return }
            persistCarets()
        }
    }

    private func persistCarets() {
        caretTask?.cancel()
        caretTask = nil
        defaults.set(carets, forKey: "ithaca.carets")
    }

    /// Only after `ensureSaved()` succeeded — this drops the buffer.
    private func closeSheet() {
        assert(!dirty, "closeSheet with unsaved text")
        sheetId = nil
        text = ""
        loadToken += 1
        updateCounts(now: true)
        menu.hasSheet = false
        refreshMentions()
    }

    // MARK: Editing · saving

    /// Called by the text view after every change. Never writes back into the text view.
    /// `token` is the `loadToken` the editor last loaded: a change from a view still showing an older sheet
    /// (the switch already happened in the model) is ignored, so the old sheet's text never lands in the new one.
    func textDidChange(_ newText: String, token: Int) {
        guard token == loadToken, sheetId != nil, !editorLocked else { return }
        // The text view only ever holds \n line endings (paste / typing are normalized); normalize again so a stray \r
        // can never make the buffer differ from what the core saves back.
        let newText = newText.normalizedNewlines
        guard newText != text else { return }
        text = newText
        markEdited()
    }

    /// The per-keystroke path: the editor's text changed; `pull` hands over a copy when something needs it.
    /// No copy, normalization or comparison here — this runs inside every keystroke, marked-text steps included.
    func textDidChange(token: Int, pull: @escaping () -> String) {
        guard token == loadToken, sheetId != nil, !editorLocked else { return }
        pendingPull = pull
        markEdited()
    }

    private func markEdited() {
        dirty = true
        // A failure stays on screen until a save actually succeeds. (Observed: only set on an actual change.)
        switch saveStatus {
        case .failed, .pending: break
        case .saved: saveStatus = .pending
        }
        updateCounts(now: false)
        scheduleSave()
        scheduleMentions()
    }

    /// Counting is O(sheet) (graphemes, regex, words, and the core's platform_body + count_for for the posted counts):
    /// it runs off the main thread — after a 250 ms pause while typing, right away on open — and a result that a newer
    /// edit overtook is dropped. Short sheets on open are counted inline so the footer is right on the first frame.
    private func updateCounts(now: Bool) {
        countTask?.cancel()
        countGeneration += 1
        let generation = countGeneration
        if now, text.utf8.count <= 30_000 {
            liveText = text
            liveCounts = TextMetrics.counts(text)
            return
        }
        nonisolated(unsafe) let lib = library
        countTask = Task { @MainActor [weak self] in
            if !now { try? await Task.sleep(for: .milliseconds(250)) }
            guard let self, !Task.isCancelled else { return }
            let snapshot = text
            let (counts, posted) = await Task.detached(priority: .userInitiated) {
                let c = TextMetrics.counts(snapshot)
                return (c, Self.postedCounts(snapshot, paragraphs: c.paragraphs, library: lib))
            }.value
            guard !Task.isCancelled, generation == countGeneration else { return }
            postedLiveCache = (snapshot, posted)
            liveText = snapshot
            liveCounts = counts
        }
    }

    /// Autosave after 1.5 s without typing. While the IME is composing, wait for it to finish.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Wait.ms(1500))
            guard let self, !Task.isCancelled else { return }
            if editor?.isComposing == true { scheduleSave(); return }
            save()
        }
    }

    /// Sheet switch · quit · app deactivation: end composition, then save now. False = the text is still unsaved.
    @discardableResult
    func flushSave() -> Bool {
        saveTask?.cancel()
        // Composition belongs to the sheet that's loaded now: commit it into this buffer before anything moves on.
        editor?.commitComposition()
        if caretTask != nil { persistCarets() }
        guard dirty else { return true }
        save()
        return !dirty
    }

    private func save() {
        guard dirty, let projectId, let sheetId else { return }
        guard !readOnly else { saveStatus = .failed(readOnlyMessage); return }
        do {
            if let debugSaveError { throw LibraryError.io(debugSaveError) }
            let summary = try library.saveSheet(project: projectId, sheet: sheetId, text: text)
            dirty = false
            retryAttempt = 0
            saveStatus = .saved
            replaceSummary(summary)
            didSaveForBible(sheetId)
        } catch {
            saveStatus = .failed((error as? LibraryError) == .readOnly ? readOnlyMessage : error.localizedDescription)
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        saveTask?.cancel()
        let delay = Self.retryDelays[min(retryAttempt, Self.retryDelays.count - 1)]
        retryAttempt += 1
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Wait.ms(delay * 1000))
            guard let self, !Task.isCancelled else { return }
            if editor?.isComposing == true { scheduleSave(); return }
            save()
        }
    }

    /// Footer "try again": save now.
    func retrySave() { _ = flushSave() }

    /// Before anything replaces or drops the open sheet's buffer (switch, close, trash, quit): save now, and if that
    /// fails ask what to do. False = the caller must stop; the text stays in the editor, still marked unsaved.
    func ensureSaved(quitting: Bool = false) -> Bool {
        if flushSave() { return true }
        while true {
            switch saveFailurePrompt?(quitting) ?? promptSaveFailure(quitting: quitting) {
            case .retry: if flushSave() { return true }
            case .copy: copyUnsavedText()
            case .export: exportUnsavedText()
            case .quitAnyway: if confirmQuitWithoutSaving() { return true }
            case .cancel: return false
            }
        }
    }

    private func promptSaveFailure(quitting: Bool) -> SaveFailureChoice {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = t(.saveFailedTitle)
        let message: String = if case .failed(let m) = saveStatus { m } else { "" }
        alert.informativeText = (message.isEmpty ? "" : message + "\n\n") + t(.saveFailedBody)
        var choices: [SaveFailureChoice] = [.retry, .copy, .export]
        alert.addButton(withTitle: t(.actionRetry))
        alert.addButton(withTitle: t(.saveCopyText))
        alert.addButton(withTitle: t(.saveExportFile) + "…")
        if quitting {
            alert.addButton(withTitle: t(.saveQuitAnyway)).hasDestructiveAction = true
            choices.append(.quitAnyway)
        }
        alert.addButton(withTitle: t(.actionCancel)).keyEquivalent = "\u{1b}"
        choices.append(.cancel)
        let i = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(i) ? choices[i] : .cancel
    }

    private func confirmQuitWithoutSaving() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = t(.saveQuitConfirmTitle)
        alert.informativeText = t(.saveQuitConfirmBody)
        alert.addButton(withTitle: t(.actionCancel))
        alert.addButton(withTitle: t(.saveQuitAnyway)).hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    func copyUnsavedText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(Toast(message: t(.saveCopied)))
    }

    func exportUnsavedText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let title = sheet?.title ?? ""
        panel.nameFieldStringValue = (title.isEmpty ? t(.sheetUntitled) : title) + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            showToast(Toast(message: t(.saveExported, ["path": url.path(percentEncoded: false)]), sticky: true))
        } catch {
            showToast(Toast(message: error.localizedDescription, sticky: true))
        }
    }

    /// Update one sheet row (title/excerpt/counts) without reloading the whole outline.
    private func replaceSummary(_ s: SheetSummary) {
        guard var o = outline else { return }
        for fi in o.folders.indices {
            if let si = o.folders[fi].sheets.firstIndex(where: { $0.id == s.id }) { o.folders[fi].sheets[si] = s }
        }
        outline = o
    }

    // MARK: Posted counts (PRODUCT "글자수 정의", 2026-10-24)

    /// The footer / inspector / goal number: the open sheet's body as it would be posted (core platform_body — no title
    /// line, no Markdown marks, scene breaks normalized) counted with count_for. `liveCounts` stays the text as written
    /// ("manuscript sheet 전체"). Recounted only when the debounced `liveText` changes.
    var livePostedCounts: Counts {
        let t = liveText
        if let c = postedLiveCache, c.text == t { return c.counts }
        let c = postedCounts(t, paragraphs: liveCounts.paragraphs)
        postedLiveCache = (t, c)
        return c
    }
    @ObservationIgnored private var postedLiveCache: (text: String, counts: Counts)?

    /// Counts of what goes up on a platform. Paragraphs stay those of the text as written.
    func postedCounts(_ text: String, paragraphs: Int? = nil) -> Counts { Self.postedCounts(text, paragraphs: paragraphs, library: library) }

    /// Pure (core free functions / mock text helpers): the live count task runs it off the main thread.
    nonisolated static func postedCounts(_ text: String, paragraphs: Int?, library: LibraryAPI) -> Counts {
        let body = library.platformBody(text: text)
        return Counts(chars: library.countFor(text: body, rule: .withSpaces), charsNoSpace: library.countFor(text: body, rule: .withoutSpaces),
                      words: library.countFor(text: body, rule: .words), paragraphs: paragraphs ?? TextMetrics.counts(text).paragraphs)
    }

    /// List rows, folder header and folder totals: a sheet's posted counts (the open sheet's live ones), cached per saved version.
    @ObservationIgnored private var postedCache: [String: (version: Int64, counts: Counts)] = [:]
    func postedCounts(of s: SheetSummary) -> Counts {
        if s.id == sheetId && s.trashed == nil { return livePostedCounts }
        if let c = postedCache[s.id], c.version == s.modified { return c.counts }
        guard let projectId, let text = try? library.sheetText(project: projectId, sheet: s.id) else { return s.counts }
        let c = postedCounts(text.normalizedNewlines, paragraphs: s.counts.paragraphs)
        postedCache[s.id] = (s.modified, c)
        return c
    }

    // MARK: Actions

    /// ⌘N and the picker's first row make a `manuscript sheet` (an episode: number, status, the author's note box);
    /// `.page` is a blank page with no episode metadata (notes, plans).
    func newSheet(_ kind: NewSheetKind = .manuscript) {
        guard let projectId, !readOnly else { return }
        let fid = folderId ?? folders.first?.id
        guard let fid else { return }
        guard ensureSaved() else { return }
        showingTrash = false
        libraryOverlay = false
        // Reuse an untouched empty sheet at the end instead of piling up blanks.
        if let last = folders.first(where: { $0.id == fid })?.sheets.last, last.counts.chars == 0, (last.episode != nil) == (kind == .manuscript) {
            openSheet(last.id)
        } else {
            do {
                let s = try library.createSheet(project: projectId, folder: fid, text: "")
                // A manuscript sheet of the serial (first) folder is the next episode: last number + 1, Draft (PRODUCT 2026-10-24).
                // Elsewhere it is a Draft with no number.
                if kind == .manuscript {
                    try library.setEpisode(project: projectId, sheet: s.id, info: EpisodeInfo(number: nextEpisodeNumber(in: fid), status: .draft))
                }
                reloadOutline()
                openSheet(s.id)
            } catch { fail(error) }
        }
        editor?.focus()
    }

    func moveSheet(_ delta: Int) {
        guard let projectId, let sheetId, let folder, !readOnly else { return }
        let list = folder.sheets
        guard let i = list.firstIndex(where: { $0.id == sheetId }) else { return }
        let j = i + delta
        guard j >= 0, j < list.count else { return }
        let before = delta < 0 ? list[j].id : (j + 1 < list.count ? list[j + 1].id : nil)
        perform { try library.moveSheet(project: projectId, sheet: sheetId, folder: folder.id, before: before) }
    }

    /// Drag-and-drop reorder inside the list, or a move to another folder (`before == nil` → end).
    func move(sheet: String, to folder: String, before: String?) {
        guard let projectId, sheet != before, !readOnly, folders.contains(where: { $0.id == folder }),
              folders.contains(where: { $0.sheets.contains { $0.id == sheet } }) else { return }
        flushSave()
        perform { try library.moveSheet(project: projectId, sheet: sheet, folder: folder, before: before) }
        if sheet == sheetId { folderId = folder }
    }

    func trashSheet(_ id: String? = nil) {
        // ⌘⌫ is the menu shortcut, but in the manuscript or any text field it means "delete to the start of the line"
        // (standard text editing): the menu's key equivalent fires before the text view sees the key, so hand it back.
        if id == nil, textTakesCommandDelete(NSApp?.currentEvent) { return }
        guard let projectId, let id = id ?? sheetId, !readOnly else { return }
        let title = folders.flatMap(\.sheets).first { $0.id == id }?.title ?? ""
        if id == sheetId { guard ensureSaved() else { return } }
        // Keep the position so the next sheet opens, like closing a tab.
        let list = folder?.sheets ?? []
        let idx = list.firstIndex { $0.id == id }
        perform { try library.trashSheet(project: projectId, sheet: id) }
        if id == sheetId {
            let rest = list.filter { $0.id != id }
            if let idx, !rest.isEmpty { openSheet(rest[min(idx, rest.count - 1)].id) } else { closeSheet() }
        }
        showToast(Toast(message: t(.sheetTrashed, ["title": title.isEmpty ? t(.sheetUntitled) : title])) { [weak self] in
            guard let self else { return }
            perform { try self.library.restoreSheet(project: projectId, sheet: id) }
            if self.projectId == projectId { openSheet(id) }
        })
    }

    /// ⌘⌫ pressed while a text view (manuscript, a text field) has the keyboard: it deletes to the line start there.
    func textTakesCommandDelete(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown, event.keyCode == 51, event.modifierFlags.contains(.command),
              let tv = (event.window ?? NSApp?.keyWindow)?.firstResponder as? NSTextView, tv.isEditable else { return false }
        tv.deleteToBeginningOfLine(nil)
        return true
    }

    /// Context menu "Duplicate": a copy of the text right below the original, opened. An episode copy gets no number.
    func duplicateSheet(_ id: String) {
        guard let projectId, !readOnly, let f = folders.first(where: { $0.sheets.contains { $0.id == id } }),
              let i = f.sheets.firstIndex(where: { $0.id == id }) else { return }
        guard ensureSaved() else { return }
        do {
            let text = try library.sheetText(project: projectId, sheet: id)
            let copy = try library.createSheet(project: projectId, folder: f.id, text: text)
            if i + 1 < f.sheets.count { try library.moveSheet(project: projectId, sheet: copy.id, folder: f.id, before: f.sheets[i + 1].id) }
            if let e = f.sheets[i].episode {
                try library.setEpisode(project: projectId, sheet: copy.id, info: EpisodeInfo(status: .draft, excluded: e.excluded))
            }
            reloadOutline()
            showingTrash = false
            openSheet(copy.id)
        } catch { fail(error); reloadOutline() }
    }

    /// Folder context menu / empty list: a new sheet at the end of `folder`.
    /// The number a new sheet in `folder` gets: only the serial (first) folder numbers its sheets.
    func nextEpisodeNumber(in folder: String) -> Int? {
        guard folder == folders.first?.id else { return nil }
        return (folders.first?.sheets.compactMap { $0.episode?.excluded == true ? nil : $0.episode?.number }.max() ?? 0) + 1
    }

    func newSheet(in folder: String, _ kind: NewSheetKind = .manuscript) {
        guard folders.contains(where: { $0.id == folder }) else { return }
        if folder != folderId { selectFolder(folder) }
        newSheet(kind)
    }

    func restoreSheet(_ id: String) {
        guard let projectId, !readOnly else { return }
        perform { try library.restoreSheet(project: projectId, sheet: id) }
        showingTrash = false
        openSheet(id)
    }

    func restoreAll() {
        guard let projectId, !readOnly else { return }
        for s in trash { try? library.restoreSheet(project: projectId, sheet: s.id) }
        reloadOutline()
        showingTrash = false
    }

    func deleteForever(_ id: String) {
        guard let projectId, !readOnly, confirm(t(.trashDeleteForeverConfirm)) else { return }
        perform { try library.deleteSheetForever(project: projectId, sheet: id) }
    }

    func emptyTrash() {
        guard let projectId, !readOnly, confirm(t(.trashEmptyConfirm)) else { return }
        perform { try library.emptyTrash(project: projectId) }
    }

    func createFolder(_ name: String) {
        guard let projectId, !name.isEmpty, !readOnly else { return }
        var created: String?
        perform { created = try library.createFolder(project: projectId, name: name).id }
        // A new folder is where the next sheet goes: select it, like Finder selects a new folder.
        if let created { selectFolder(created) }
    }

    func renameFolder(_ id: String, _ name: String) {
        guard let projectId, !name.isEmpty, !readOnly else { return }
        perform { try library.renameFolder(project: projectId, folder: id, name: name) }
    }

    func deleteFolder(_ id: String) {
        // The core refuses to delete the last folder; the menu hides it, this keeps a stray call from a toast.
        guard let projectId, !readOnly, folders.count > 1, let f = folders.first(where: { $0.id == id }) else { return }
        let ok = f.sheets.isEmpty ? confirm(t(.folderDeleteConfirmEmpty, ["name": f.name]))
                                  : confirm(t(.folderDeleteConfirm, ["name": f.name], count: f.sheets.count))
        guard ok else { return }
        if f.sheets.contains(where: { $0.id == sheetId }) {
            guard ensureSaved() else { return }
            closeSheet()
        }
        let closedOpenSheet = sheetId == nil
        perform { try library.deleteFolder(project: projectId, folder: id) }
        if folderId == id || !folders.contains(where: { $0.id == folderId }) {
            folderId = folders.first?.id
            // The open sheet went with the folder: open the first sheet of the folder now shown, not an empty editor.
            if closedOpenSheet, let s = folder?.sheets.first { openSheet(s.id) }
            rememberSelection()
        }
        showToast(Toast(message: t(.folderDeleted, ["name": f.name])) { [weak self] in
            guard let self, self.projectId == projectId else { return }
            self.perform { try self.library.restoreFolder(project: projectId, folder: id) }
            self.selectFolder(id)
        })
    }

    func createProject(title: String, language: ManuscriptLanguage, folders names: [String], goal: Goal?) {
        guard !readOnly, ensureSaved() else { return }
        do {
            let p = try library.createProject(title: title, language: language, folders: names.isEmpty ? [defaultFolderName(.folderDefaultSerial)] : names)
            if let goal { _ = try library.updateProject(id: p.id, patch: ProjectPatch(goal: .some(goal))) }
            refreshProjects()
            selectProject(p.id)
            // The core creates one empty sheet in the first folder (API.md); open it.
            if let s = folders.first?.sheets.first {
                try library.setEpisode(project: p.id, sheet: s.id, info: EpisodeInfo(number: 1, status: .draft))
                reloadOutline()
                openSheet(s.id)
            }
            overlay = nil
            editor?.focus()
        } catch { fail(error) }
    }

    func defaultFolderName(_ key: L10nKey) -> String { t(key) }

    /// Library context menu "Rename": any project, in place.
    func renameProject(_ id: String, _ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !readOnly, projects.first(where: { $0.id == id })?.title != title else { return }
        do { _ = try library.updateProject(id: id, patch: ProjectPatch(title: title)) } catch { fail(error) }
        refreshProjects()
        if id == projectId { reloadOutline() }
    }

    func updateProject(_ patch: ProjectPatch) {
        guard let projectId, !readOnly else { return }
        perform { _ = try library.updateProject(id: projectId, patch: patch) }
        refreshProjects()
    }

    /// Soft delete (kept 30 days) with an undo that stays until dismissed.
    /// `id` nil = the open project (project settings); the library's context menu passes any project.
    func deleteProject(_ id: String? = nil) {
        guard let p = id.flatMap({ id in projects.first { $0.id == id } }) ?? project, !readOnly,
              confirm(t(.projectSettingsDeleteConfirm, ["name": p.title])) else { return }
        let open = p.id == projectId
        if open { guard ensureSaved() else { return } }
        do { try library.deleteProject(id: p.id) } catch { fail(error); return }
        overlay = nil
        refreshProjects()
        if !open {
            // Another project went: the open one stays as it is.
        } else if let next = projects.first { selectProject(next.id) } else { projectId = nil; outline = nil; folderId = nil; closeSheet() }
        showToast(Toast(message: t(.projectSettingsDeleted, ["name": p.title]), undo: { [weak self] in
            guard let self else { return }
            perform { try self.library.restoreProject(id: p.id) }
            refreshProjects()
            selectProject(p.id)
        }, sticky: true))
    }

    /// Long work in flight (import, restore): the window shows a progress HUD with this message and blocks a second run.
    var busy: String?

    func importWebBackup() {
        guard busy == nil, !readOnly else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = t(.importWebHint)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let before = Set(projects.map(\.id))
        busy = t(.busyImportWeb)
        Task { @MainActor in
            defer { busy = nil }
            do {
                // Reading and parsing a large backup also stays off the main thread.
                let json = try await Task.detached(priority: .userInitiated) { try String(contentsOf: url, encoding: .utf8) }.value
                let r = try await library.importWebBackup(json: json, suffix: "")
                let added = adopt(newProjectsSince: before)
                if case .newProject = overlay { overlay = nil }
                showToast(Toast(message: t(.importWebDone, ["projects": r.projects, "sheets": r.sheets, "names": names(added)]), sticky: true))
            } catch {
                showToast(Toast(message: t(.importWebFailed, ["message": error.localizedDescription]), sticky: true))
            }
        }
    }

    /// What the last text-folder import skipped ("path (reason)"), listed in a sheet.
    var importSkipped: [String] = []

    /// File → Import Text Folder…: a folder of .txt/.md manuscripts becomes one new project.
    func importTextFolder() {
        guard busy == nil, !readOnly else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = t(.importTextFolderHint)
        panel.prompt = t(.importTextFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let before = Set(projects.map(\.id))
        busy = t(.busyImportTextFolder)
        Task { @MainActor in
            defer { busy = nil }
            do {
                let r = try await library.importTextFolder(path: url.path(percentEncoded: false), title: nil, language: nil)
                let added = adopt(newProjectsSince: before)
                if case .newProject = overlay { overlay = nil }
                var message = t(.importTextFolderDone, ["sheets": r.sheets, "names": names(added)])
                if !r.skipped.isEmpty { message += " " + t(.importSkippedCount, ["count": r.skipped.count], count: r.skipped.count) }
                showToast(Toast(message: message, sticky: true))
                if !r.skipped.isEmpty {
                    importSkipped = r.skipped
                    // After the welcome sheet (if any) has gone: two sheets swapping in one tick can drop the second.
                    try? await Task.sleep(for: .milliseconds(400))
                    if overlay == nil { overlay = .importSkipped }
                }
            } catch {
                showToast(Toast(message: t(.importWebFailed, ["message": error.localizedDescription]), sticky: true))
            }
        }
    }

    /// Settings → Backup → "Restore as copies": never overwrites; the backup's projects come back as new ones.
    /// The finished message goes to `done` (the settings pane) and to a toast in the main window.
    func restoreBackupAsCopies(_ b: BackupInfo, done: @escaping (String) -> Void = { _ in }) {
        guard busy == nil, !readOnly else { return }
        guard ensureSaved() else { return }
        let before = Set(projects.map(\.id))
        busy = t(.busyRestoreBackup)
        Task { @MainActor in
            defer { busy = nil }
            do {
                // Titles say where the copy came from: "등대지기의 딸 (백업 10월 24일)".
                let date = b.at.date.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: locale.rawValue)))
                let added = try await library.restoreBackupAsCopies(path: b.path, suffix: " " + t(.backupCopySuffix, ["date": date]))
                _ = adopt(newProjectsSince: before)
                let message = t(.backupRestoredCopies, ["count": added.count, "names": names(added)], count: added.count)
                showToast(Toast(message: message, sticky: true))
                done(message)
            } catch {
                showToast(Toast(message: error.localizedDescription, sticky: true))
                done(error.localizedDescription)
            }
        }
    }

    /// After an import/restore: reload the project list and open the first new project. Returns the new projects.
    private func adopt(newProjectsSince before: Set<String>) -> [ProjectSummary] {
        refreshProjects()
        let added = projects.filter { !before.contains($0.id) }
        if let first = added.first { selectProject(first.id) }
        return added
    }

    private func names(_ ps: [ProjectSummary]) -> String {
        let titles = ps.map { "‘\($0.title)’" }
        return titles.count > 3 ? titles.prefix(3).joined(separator: ", ") + " …" : titles.joined(separator: ", ")
    }

    // MARK: Episodes

    func episodeLabel(_ e: EpisodeInfo) -> String {
        var status = t(statusKey(e.status))
        if e.status == .scheduled, let at = e.publishAt { status = t(.episodeScheduledAt, ["date": releaseDate(at, time: true)]) }
        if e.excluded { return t(.episodeExcluded) + " · " + status }
        guard let n = e.number else { return status }
        return t(.episodeNumber, ["number": n]) + " · " + status
    }

    /// "10/26 18:00" (rows, inspector) or "10/26" (folder header): short enough for a 280 pt list.
    func releaseDate(_ at: Int64, time: Bool) -> String {
        let f = DateFormatter()
        f.locale = dateLocale
        if !time { f.dateFormat = "M/d" } else if locale == .ko { f.dateFormat = "M/d HH:mm" } else { f.setLocalizedDateFormatFromTemplate("Mdjmm") }
        return f.string(from: at.date)
    }

    /// Earliest scheduled release of a folder.
    func nextRelease(_ folder: FolderInfo) -> Int64? {
        guard let projectId, folder.sheets.contains(where: { $0.episode?.status == .scheduled }) else { return nil }
        return (try? library.nextRelease(project: projectId, folder: folder.id)) ?? nil
    }

    func folderStats(_ folder: FolderInfo) -> FolderStats? {
        guard let projectId else { return nil }
        return try? library.folderStats(project: projectId, folder: folder.id)
    }

    /// Scheduled episodes: when it goes up on the platform (nil clears it).
    func setPublishAt(_ date: Date?) {
        guard let projectId, let sheet, var info = sheet.episode, !readOnly else { return }
        info.publishAt = date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        perform { try library.setEpisode(project: projectId, sheet: sheet.id, info: info) }
    }

    /// The platform the last episode was set to go up on: the default for the next one.
    var lastPlatform: String? {
        get { defaults.string(forKey: "ithaca.lastPlatform").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "ithaca.lastPlatform") }
    }

    /// Inspector platform field. Empty clears it.
    func setPlatform(_ platform: String) {
        guard let projectId, let sheet, var info = sheet.episode, !readOnly else { return }
        let p = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (info.platform ?? "") != p else { return }
        info.platform = p.isEmpty ? nil : p
        if !p.isEmpty { lastPlatform = p }
        perform { try library.setEpisode(project: projectId, sheet: sheet.id, info: info) }
    }

    /// Sheet menu ⌥⌘C / palette: the open sheet as the last paste settings of Export make it, plain text, no dialog.
    func copyForPaste() {
        guard let projectId, let sheetId else { return }
        flushSave()
        var o = ExportView.lastPasteOptions()
        o.markdown = false
        do {
            let text = try library.exportText(project: projectId, sheets: [sheetId], options: o)
            // Plain string only: RTF/HTML on the clipboard turns into doubled blank lines on serial platforms.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let n = library.countFor(text: text, rule: .withSpaces)
            showToast(Toast(message: t(.sheetCopiedForPaste, ["count": n], count: n)))
        } catch { fail(error) }
    }

    /// Sheet menu "author's note 복사" / the box's copy button: the open sheet's note, plain text (paste rules), no dialog.
    func copyAuthorNote() {
        guard sheetId != nil else { return }
        guard let note = library.authorNote(text: text), !note.isEmpty else { return showToast(Toast(message: t(.noteEmpty))) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note, forType: .string)
        let n = library.countFor(text: note, rule: .withSpaces)
        showToast(Toast(message: t(.noteCopied, ["count": n], count: n)))
    }

    /// Side story / notice: stays in the folder, not numbered (its number is cleared; renumber skips it).
    func toggleExcluded(_ id: String) {
        guard let projectId, !readOnly, let s = folders.lazy.flatMap(\.sheets).first(where: { $0.id == id }) else { return }
        var info = s.episode ?? EpisodeInfo(status: .draft)
        info.excluded.toggle()
        if info.excluded { info.number = nil }
        perform { try library.setEpisode(project: projectId, sheet: id, info: info) }
    }

    /// Folder header click / "Folder info": the folder's totals in the inspector's Info tab.
    func showFolderInfo(_ id: String? = nil) {
        if let id, id != folderId { selectFolder(id) }
        inspectorScope = .folder
        defaults.set(InspectorTab.info.rawValue, forKey: "ithaca.inspectorTab")
        inspectorOpen = true
        showPanes()
    }

    /// Footer goal: the open sheet's count on the project's basis (platform bases count the text as pasted).
    func goalValue(_ basis: GoalBasis) -> Int {
        switch basis {
        case .munpia, .novelpia: library.goalCount(text: liveText, basis: basis)
        // Same basis as the footer numbers: the body as posted.
        default: TextMetrics.goalValue(livePostedCounts, basis)
        }
    }

    func statusKey(_ s: EpisodeStatus) -> L10nKey {
        switch s {
        case .draft: .episodeStatusDraft
        case .revising: .episodeStatusRevising
        case .scheduled: .episodeStatusScheduled
        case .published: .episodeStatusPublished
        }
    }

    /// Stock (unpublished episodes) of a folder that holds episodes; nil when the folder has none.
    func stock(_ folder: FolderInfo) -> Int? {
        guard let projectId, folder.sheets.contains(where: { $0.episode != nil }) else { return nil }
        return try? library.stock(project: projectId, folder: folder.id)
    }

    /// nil = not an episode (prologue, notice, notes).
    func setEpisodeStatus(_ status: EpisodeStatus?, sheet id: String? = nil) {
        guard let projectId, !readOnly,
              let sheet = id.flatMap({ id in folders.lazy.flatMap(\.sheets).first { $0.id == id } }) ?? sheet else { return }
        var info = sheet.episode ?? EpisodeInfo(status: .draft)
        if let status { info.status = status }
        // A new schedule starts tomorrow at the time of the last scheduled episode (else 18:00): serials keep one slot.
        if status == .scheduled, info.publishAt == nil {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            let lastAt = folders.flatMap(\.sheets).filter { $0.id != sheet.id && $0.episode?.status == .scheduled }
                .compactMap { $0.episode?.publishAt }.max()
            let time = lastAt.map { Calendar.current.dateComponents([.hour, .minute], from: $0.date) }
            let at = Calendar.current.date(bySettingHour: time?.hour ?? 18, minute: time?.minute ?? 0, second: 0, of: tomorrow) ?? tomorrow
            info.publishAt = Int64(at.timeIntervalSince1970 * 1000)
        }
        if status == .scheduled || status == .published, info.platform == nil, let p = lastPlatform { info.platform = p }
        perform { try library.setEpisode(project: projectId, sheet: sheet.id, info: status == nil ? nil : info) }
    }

    func renumberEpisodes() {
        guard let projectId, let folder, !readOnly else { return }
        guard ensureSaved() else { return }
        do {
            let n = try library.renumberEpisodes(project: projectId, folder: folder.id)
            reloadOutline()
            showToast(Toast(message: n == 0 ? t(.episodeRenumberedNone) : t(.episodeRenumbered, ["count": n], count: n)))
        } catch { fail(error) }
    }

    /// Sheet menu / context menu: this sheet and every episode before it in its folder become Published.
    func markPublishedThrough(_ id: String? = nil) {
        guard let projectId, let id = id ?? sheetId, !readOnly,
              let folder = folders.first(where: { $0.sheets.contains { $0.id == id } }) else { return }
        let title = folder.sheets.first { $0.id == id }?.title ?? ""
        do {
            _ = try library.setStatusThrough(project: projectId, folder: folder.id, sheet: id, status: .published)
            reloadOutline()
            showToast(Toast(message: t(.episodePublishedThroughDone, ["title": title.isEmpty ? t(.sheetUntitled) : title])))
        } catch { fail(error) }
    }

    // MARK: Damaged sheets

    /// Sheet for which no backup had an intact copy: the banner then offers "keep the last intact text".
    var noBackupForSheet: String?
    /// A project whose table of contents is damaged (changes → Corrupt): the editor shows a restore hint.
    var tocDamagedProject: String?

    /// The damaged sheet's text comes back from the newest backup that has it; the editor reloads it.
    func recoverDamagedSheet() {
        guard let projectId, let sheetId, !readOnly else { return }
        do {
            let s = try library.recoverSheetFromBackup(project: projectId, sheet: sheetId)
            replaceSummary(s)
            reloadOutline()
            openSheet(sheetId)
            showToast(Toast(message: t(.sheetRecovered, ["title": s.title.isEmpty ? t(.sheetUntitled) : s.title])))
        } catch LibraryError.notFound {
            noBackupForSheet = sheetId
        } catch {
            noBackupForSheet = sheetId
            showToast(Toast(message: t(.sheetRecoverFailed, ["message": error.localizedDescription]), sticky: true))
        }
    }

    /// No usable backup: go on from the text that's shown (the core keeps the broken files aside).
    func keepLastGoodText() {
        guard let projectId, let sheetId, !readOnly else { return }
        do {
            let s = try library.keepLastGoodText(project: projectId, sheet: sheetId)
            noBackupForSheet = nil
            replaceSummary(s)
            reloadOutline()
            openSheet(sheetId)
            showToast(Toast(message: t(.sheetKeptLastGood, ["title": s.title.isEmpty ? t(.sheetUntitled) : s.title])))
        } catch { fail(error) }
    }

    // MARK: Backups

    /// Launch and idle: one automatic backup a day, copied off the main thread (API.md backup_now).
    func runAutoBackupIfDue() {
        guard !info.inMemory, !readOnly, !backingUp, library.backupDue() else { return }
        backingUp = true
        Task { @MainActor in
            defer { backingUp = false }
            do { _ = try await library.backupNow() } catch LibraryError.invalidInput {
                // Nothing with text to back up yet (qa1): not worth a word.
            } catch {
                showToast(Toast(message: t(.backupFailed, ["message": error.localizedDescription])))
            }
        }
    }

    var backingUp = false { didSet { if !backingUp { refreshLastBackup() } } }

    /// Newest backup's time (footer save-state tooltip). nil = none yet.
    private(set) var lastBackupAt: Int64?
    func refreshLastBackup() { lastBackupAt = info.inMemory ? nil : library.backups().map(\.at).max() }

    // MARK: View

    func toggleInspector() { inspectorOpen.toggle(); showPanes() }
    func toggleFocus() { focusMode.toggle(); editorOnly = false; if focusMode { libraryOverlay = false } }
    func toggleEditorOnly() { editorOnly.toggle(); focusMode = false; if editorOnly { libraryOverlay = false } }
    func showPanes() { focusMode = false; editorOnly = false }
    func toggleMini() {
        mini.toggle()
        focusMode = false
        editorOnly = false
        libraryOverlay = false
        if mini { inspectorOpen = false; overlay = nil }
    }
    func show(_ o: Overlay) {
        if case .palette = o, case .palette = overlay { overlay = nil; return }
        // Export and history read the stored text: save what's typed first.
        if o == .export || o == .history { flushSave() }
        overlay = o
    }

    /// History → "restore this version": a new block with the old text; the editor reloads it.
    func restoreVersion(_ hash: String) {
        guard let projectId, let sheetId else { return }
        // Restoring replaces the editor's text: never over unsaved typing.
        guard ensureSaved() else { return }
        let caret = editor?.caretLocation
        do {
            let s = try library.restoreVersion(project: projectId, sheet: sheetId, hash: hash)
            replaceSummary(s)
            openSheet(sheetId, at: caret.map { NSRange(location: $0, length: 0) })
        } catch { fail(error) }
    }

    func showToast(_ toast: Toast) {
        toastTask?.cancel()
        self.toast = toast
        guard !toast.sticky else { return }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func holdToast(_ hold: Bool) {
        guard let toast, !toast.sticky else { return }
        toastTask?.cancel()
        if !hold { showToast(toast) }
    }

    // MARK: Helpers

    func confirm(_ message: String) -> Bool {
        guard confirmDelete else { return true }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: t(.folderDelete))
        alert.addButton(withTitle: t(.actionCancel))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func perform(_ f: () throws -> Void) {
        do { try f() } catch { fail(error) }
        reloadOutline()
    }

    func fail(_ error: Error) {
        // Corrupt from a change that isn't a damaged sheet's text → the project's table of contents is broken.
        if case .corrupt = error as? LibraryError, sheet?.damaged != true { tocDamagedProject = projectId }
        showToast(Toast(message: (error as? LibraryError) == .readOnly ? t(.libraryReadOnly) : error.localizedDescription, sticky: true))
    }
}

/// The few bits the menu bar needs. Commands observe this (ObservableObject is what Commands reliably track).
@MainActor
final class MenuState: ObservableObject {
    @Published var locale: L10nLocale = .ko
    @Published var hasSheet = false
    @Published var hasProject = false
    /// Read-only library: write commands are disabled.
    @Published var readOnly = false
    /// Format › Symbols follows the editor's symbol list.
    @Published var symbols: [Symbol] = Symbols.defaults
}
