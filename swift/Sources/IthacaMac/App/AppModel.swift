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
    var id: String {
        switch self {
        case .palette: "palette"
        case .export: "export"
        case .history: "history"
        case .newProject: "newProject"
        case .projectSettings: "projectSettings"
        }
    }
}

enum SaveStatus: Equatable { case saved, pending, failed(String) }

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var undo: (() -> Void)?
    var sticky = false
}

enum TextSize: String, CaseIterable { case small, normal, large }
enum ThemePref: String, CaseIterable { case system, light, dark }
enum LocalePref: String, CaseIterable { case system, ko, en }
enum MarkupMode: String, CaseIterable { case show, dim, hide }
enum FocusScope: String, CaseIterable { case sentence, paragraph }

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
}

@MainActor
@Observable
final class AppModel {
    nonisolated static let editorMin: Double = 600

    let library: LibraryAPI
    private(set) var info: LibraryInfo
    var openError: String?

    // MARK: Data
    private(set) var projects: [ProjectSummary] = []
    private(set) var outline: Outline?
    private(set) var projectId: String?
    private(set) var folderId: String?
    private(set) var sheetId: String?
    var showingTrash = false

    // MARK: Open sheet buffer
    /// The text view owns the live text; this is the last copy it handed over (not observed per keystroke).
    @ObservationIgnored private(set) var text = ""
    /// Bumped when the editor must load `text` (sheet switch, history restore). Never during typing.
    private(set) var loadToken = 0
    /// Debounced copy of the counts for the footer/inspector — counting 10k characters per keystroke is wasted work.
    private(set) var liveCounts = Counts()
    private(set) var liveText = ""
    private(set) var saveStatus: SaveStatus = .saved
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored weak var editor: EditorBridge?

    // MARK: View state
    var inspectorOpen = false
    var focusMode = false
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

    // MARK: Preferences (UserDefaults)
    var localePref: LocalePref { didSet { defaults.set(localePref.rawValue, forKey: "ithaca.locale"); menu.locale = locale } }
    var theme: ThemePref { didSet { defaults.set(theme.rawValue, forKey: "ithaca.theme"); applyTheme() } }
    var textSize: TextSize { didSet { defaults.set(textSize.rawValue, forKey: "ithaca.textSize") } }
    var markup: MarkupMode { didSet { defaults.set(markup.rawValue, forKey: "ithaca.markup") } }
    var focusScope: FocusScope { didSet { defaults.set(focusScope.rawValue, forKey: "ithaca.focusScope") } }
    var typewriter: Bool { didSet { defaults.set(typewriter, forKey: "ithaca.typewriter") } }
    var confirmDelete: Bool { didSet { defaults.set(confirmDelete, forKey: "ithaca.confirmDelete") } }
    /// nil = follow the manuscript language (on for English, off for Korean — the system checker flags ordinary Korean).
    var spellCheck: Bool? { didSet { defaults.set(spellCheck.map { $0 ? "on" : "off" } ?? "auto", forKey: "ithaca.spell") } }

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let menu = MenuState()
    @ObservationIgnored private var carets: [String: Int]

    init(library: LibraryAPI, openError: String? = nil, defaults: UserDefaults = .standard) {
        self.library = library
        self.openError = openError
        self.defaults = defaults
        info = library.info()
        localePref = LocalePref(rawValue: defaults.string(forKey: "ithaca.locale") ?? "") ?? .system
        theme = ThemePref(rawValue: defaults.string(forKey: "ithaca.theme") ?? "") ?? .system
        textSize = TextSize(rawValue: defaults.string(forKey: "ithaca.textSize") ?? "") ?? .normal
        markup = MarkupMode(rawValue: defaults.string(forKey: "ithaca.markup") ?? "") ?? .dim
        focusScope = FocusScope(rawValue: defaults.string(forKey: "ithaca.focusScope") ?? "") ?? .paragraph
        typewriter = defaults.object(forKey: "ithaca.typewriter") as? Bool ?? false
        confirmDelete = defaults.object(forKey: "ithaca.confirmDelete") as? Bool ?? true
        switch defaults.string(forKey: "ithaca.spell") { case "on": spellCheck = true; case "off": spellCheck = false; default: spellCheck = nil }
        carets = (defaults.dictionary(forKey: "ithaca.carets") as? [String: Int]) ?? [:]
        menu.locale = locale
        refreshProjects()
        restoreSelection()
    }

    // MARK: Locale

    var locale: L10nLocale {
        switch localePref {
        case .ko: .ko
        case .en: .en
        case .system: (Locale.preferredLanguages.first ?? "en").hasPrefix("ko") ? .ko : .en
        }
    }

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
    var readOnly: Bool { info.readOnly }
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
        flushSave()
        projectId = id
        showingTrash = false
        reloadOutline()
        let last = defaults.dictionary(forKey: "ithaca.last.\(id)") as? [String: String] ?? [:]
        folderId = folders.first { $0.id == last["folder"] }?.id ?? folders.first?.id
        let s = last["sheet"].flatMap { s in folders.flatMap(\.sheets).first { $0.id == s }?.id } ?? folder?.sheets.first?.id
        if let s { openSheet(s) } else { closeSheet() }
        if remember { rememberSelection() }
    }

    func selectFolder(_ id: String) {
        folderId = id
        showingTrash = false
        rememberSelection()
    }

    func openSheet(_ id: String, at range: NSRange? = nil) {
        if id != sheetId { flushSave() }
        guard let projectId else { return }
        if let f = folders.first(where: { $0.sheets.contains { $0.id == id } }) { folderId = f.id }
        do {
            text = try library.sheetText(project: projectId, sheet: id)
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
    }

    /// Where the editor should put the selection after the next load (search hits); otherwise the remembered caret.
    @ObservationIgnored var pendingSelection: NSRange?

    func caret(for sheet: String) -> Int? { carets[sheet] }

    func rememberCaret(_ location: Int) {
        guard let sheetId else { return }
        carets[sheetId] = location
        defaults.set(carets, forKey: "ithaca.carets")
    }

    private func closeSheet() {
        sheetId = nil
        text = ""
        loadToken += 1
        updateCounts(now: true)
        menu.hasSheet = false
    }

    // MARK: Editing · saving

    /// Called by the text view after every change. Never writes back into the text view.
    func textDidChange(_ newText: String) {
        guard newText != text else { return }
        text = newText
        dirty = true
        saveStatus = .pending
        updateCounts(now: false)
        scheduleSave()
    }

    private func updateCounts(now: Bool) {
        countTask?.cancel()
        if now {
            liveText = text
            liveCounts = TextMetrics.counts(text)
            return
        }
        countTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            liveText = text
            liveCounts = TextMetrics.counts(text)
        }
    }

    /// Autosave after 1.5 s without typing. While the IME is composing, wait for it to finish.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled else { return }
            if editor?.isComposing == true { scheduleSave(); return }
            save()
        }
    }

    /// Sheet switch · quit · app deactivation: end composition, then save now.
    func flushSave() {
        saveTask?.cancel()
        guard dirty else { return }
        editor?.commitComposition()
        save()
    }

    private func save() {
        guard dirty, let projectId, let sheetId else { return }
        guard !readOnly else { saveStatus = .failed(t(.libraryReadOnly)); return }
        do {
            let summary = try library.saveSheet(project: projectId, sheet: sheetId, text: text)
            dirty = false
            saveStatus = .saved
            replaceSummary(summary)
        } catch {
            saveStatus = .failed(error.localizedDescription)
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

    // MARK: Actions

    func newSheet() {
        guard let projectId, !readOnly else { return }
        let fid = folderId ?? folders.first?.id
        guard let fid else { return }
        flushSave()
        showingTrash = false
        libraryOverlay = false
        // Reuse an untouched empty sheet at the end instead of piling up blanks.
        if let last = folders.first(where: { $0.id == fid })?.sheets.last, last.counts.chars == 0 {
            openSheet(last.id)
        } else {
            do {
                let s = try library.createSheet(project: projectId, folder: fid, text: "")
                // New sheets of the serial (first) folder are episodes, numbered when renumbered.
                if fid == folders.first?.id { try library.setEpisode(project: projectId, sheet: s.id, info: EpisodeInfo(status: .draft)) }
                reloadOutline()
                openSheet(s.id)
            } catch { fail(error) }
        }
        editor?.focus()
    }

    func moveSheet(_ delta: Int) {
        guard let projectId, let sheetId, let folder else { return }
        let list = folder.sheets
        guard let i = list.firstIndex(where: { $0.id == sheetId }) else { return }
        let j = i + delta
        guard j >= 0, j < list.count else { return }
        let before = delta < 0 ? list[j].id : (j + 1 < list.count ? list[j + 1].id : nil)
        perform { try library.moveSheet(project: projectId, sheet: sheetId, folder: folder.id, before: before) }
    }

    /// Drag-and-drop reorder inside the list, or a move to another folder (`before == nil` → end).
    func move(sheet: String, to folder: String, before: String?) {
        guard let projectId, sheet != before else { return }
        flushSave()
        perform { try library.moveSheet(project: projectId, sheet: sheet, folder: folder, before: before) }
        if sheet == sheetId { folderId = folder }
    }

    func trashSheet(_ id: String? = nil) {
        guard let projectId, let id = id ?? sheetId else { return }
        let title = folders.flatMap(\.sheets).first { $0.id == id }?.title ?? ""
        if id == sheetId { flushSave() }
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

    func restoreSheet(_ id: String) {
        guard let projectId else { return }
        perform { try library.restoreSheet(project: projectId, sheet: id) }
        showingTrash = false
        openSheet(id)
    }

    func restoreAll() {
        guard let projectId else { return }
        for s in trash { try? library.restoreSheet(project: projectId, sheet: s.id) }
        reloadOutline()
        showingTrash = false
    }

    func deleteForever(_ id: String) {
        guard let projectId, confirm(t(.trashDeleteForeverConfirm)) else { return }
        perform { try library.deleteSheetForever(project: projectId, sheet: id) }
    }

    func emptyTrash() {
        guard let projectId, confirm(t(.trashEmptyConfirm)) else { return }
        perform { try library.emptyTrash(project: projectId) }
    }

    func createFolder(_ name: String) {
        guard let projectId, !name.isEmpty else { return }
        perform { _ = try library.createFolder(project: projectId, name: name) }
    }

    func renameFolder(_ id: String, _ name: String) {
        guard let projectId, !name.isEmpty else { return }
        perform { try library.renameFolder(project: projectId, folder: id, name: name) }
    }

    func deleteFolder(_ id: String) {
        guard let projectId, let f = folders.first(where: { $0.id == id }) else { return }
        let ok = f.sheets.isEmpty ? confirm(t(.folderDeleteConfirmEmpty, ["name": f.name]))
                                  : confirm(t(.folderDeleteConfirm, ["name": f.name], count: f.sheets.count))
        guard ok else { return }
        if f.sheets.contains(where: { $0.id == sheetId }) { flushSave(); closeSheet() }
        perform { try library.deleteFolder(project: projectId, folder: id) }
        if folderId == id { folderId = folders.first?.id }
        showToast(Toast(message: t(.folderDeleted, ["name": f.name])) { [weak self] in
            self?.perform { try self?.library.restoreFolder(project: projectId, folder: id) }
        })
    }

    func createProject(title: String, language: ManuscriptLanguage, folders names: [String], goal: Goal?) {
        flushSave()
        do {
            let p = try library.createProject(title: title, language: language, folders: names.isEmpty ? [defaultFolderName(.folderDefaultSerial, language)] : names)
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

    func defaultFolderName(_ key: L10nKey, _ language: ManuscriptLanguage) -> String {
        L10n.string(key, locale: language == .ko ? .ko : .en)
    }

    func updateProject(_ patch: ProjectPatch) {
        guard let projectId else { return }
        perform { _ = try library.updateProject(id: projectId, patch: patch) }
        refreshProjects()
    }

    /// Soft delete (kept 30 days) with an undo that stays until dismissed.
    func deleteProject() {
        guard let p = project, confirm(t(.projectSettingsDeleteConfirm, ["name": p.title])) else { return }
        flushSave()
        perform { try library.deleteProject(id: p.id) }
        overlay = nil
        refreshProjects()
        if let next = projects.first { selectProject(next.id) } else { projectId = nil; outline = nil; closeSheet(); overlay = .newProject(firstRun: true) }
        showToast(Toast(message: t(.projectSettingsDeleted, ["name": p.title]), undo: { [weak self] in
            guard let self else { return }
            perform { try self.library.restoreProject(id: p.id) }
            refreshProjects()
            if overlay == .newProject(firstRun: true) { overlay = nil }
            selectProject(p.id)
        }, sticky: true))
    }

    func importWebBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = t(.importWebHint)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            let before = Set(projects.map(\.id))
            let r = try library.importWebBackup(json: json)
            refreshProjects()
            if let first = projects.first(where: { !before.contains($0.id) }) { selectProject(first.id) }
            if case .newProject = overlay { overlay = nil }
            showToast(Toast(message: t(.importWebDone, ["projects": r.projects, "sheets": r.sheets])))
        } catch {
            showToast(Toast(message: t(.importWebFailed, ["message": error.localizedDescription]), sticky: true))
        }
    }

    // MARK: Episodes

    func episodeLabel(_ e: EpisodeInfo) -> String {
        let status = t(statusKey(e.status))
        guard let n = e.number else { return status }
        return t(.episodeNumber, ["number": n]) + " · " + status
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
    func setEpisodeStatus(_ status: EpisodeStatus?) {
        guard let projectId, let sheet else { return }
        var info = sheet.episode ?? EpisodeInfo(status: .draft)
        if let status { info.status = status }
        perform { try library.setEpisode(project: projectId, sheet: sheet.id, info: status == nil ? nil : info) }
    }

    func renumberEpisodes() {
        guard let projectId, let folder else { return }
        do {
            let n = try library.renumberEpisodes(project: projectId, folder: folder.id)
            reloadOutline()
            showToast(Toast(message: t(.episodeRenumbered, ["count": n], count: n)))
        } catch { fail(error) }
    }

    // MARK: Backups

    /// Launch and idle: one automatic backup a day, copied off the main thread (API.md backup_now).
    func runAutoBackupIfDue() {
        guard !info.inMemory, !readOnly, !backingUp, library.backupDue() else { return }
        backingUp = true
        Task { @MainActor in
            defer { backingUp = false }
            do { _ = try await library.backupNow() } catch {
                showToast(Toast(message: t(.backupFailed, ["message": error.localizedDescription])))
            }
        }
    }

    var backingUp = false

    // MARK: View

    func toggleInspector() { inspectorOpen.toggle(); focusMode = false }
    func toggleFocus() { focusMode.toggle(); if focusMode { libraryOverlay = false } }
    func show(_ o: Overlay) {
        if case .palette = o, case .palette = overlay { overlay = nil; return }
        // Export and history read the stored text: save what's typed first.
        if o == .export || o == .history { flushSave() }
        overlay = o
    }

    /// History → "restore this version": a new block with the old text; the editor reloads it.
    func restoreVersion(_ hash: String) {
        guard let projectId, let sheetId else { return }
        flushSave()
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

    private func fail(_ error: Error) {
        showToast(Toast(message: (error as? LibraryError) == .readOnly ? t(.libraryReadOnly) : error.localizedDescription, sticky: true))
    }
}

/// The few bits the menu bar needs. Commands observe this (ObservableObject is what Commands reliably track).
@MainActor
final class MenuState: ObservableObject {
    @Published var locale: L10nLocale = .ko
    @Published var hasSheet = false
    @Published var hasProject = false
}
