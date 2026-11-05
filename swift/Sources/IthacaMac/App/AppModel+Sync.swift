// What a sync run brought in, applied to what's on screen (ADR-0013).
import Foundation

extension AppModel {
    func applySync(_ r: SyncIngestResult) {
        guard r.added > 0 else { return }
        refreshProjects()
        guard let projectId, projects.contains(where: { $0.id == projectId }) else {
            // Nothing open (a new device's first sync), or the open project went away: open the first one.
            if let first = projects.first, ensureSaved() { selectProject(first.id) }
            return
        }
        guard r.changed.contains(where: { $0.project == projectId }) else { return }
        reloadOutline()
        guard let sheetId else {
            if let s = folder?.sheets.first?.id { openSheet(s) }
            return
        }
        guard sheet != nil else {
            // Trashed or deleted on the other device.
            if ensureSaved() { if let s = folder?.sheets.first?.id { openSheet(s) } }
            return
        }
        guard r.changed.contains(where: { $0.project == projectId && $0.sheet == sheetId }) else { return }
        // Typing here goes on: the next save writes over the winner and both stay in the history.
        guard !dirty, editor?.isComposing != true,
              let fresh = try? library.sheetText(project: projectId, sheet: sheetId).normalizedNewlines, fresh != text else { return }
        let caret = editor?.caretLocation
        openSheet(sheetId, at: caret.map { NSRange(location: min($0, (fresh as NSString).length), length: 0) })
        if sheet?.branched == true { showToast(Toast(message: t(.syncForked))) }
    }
}
