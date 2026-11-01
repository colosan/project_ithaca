// Rewrite side by side (app-shell spec "다시 쓰기"): the original on the left, read only; the sheet itself on the right,
// emptied, to be written again. The original is the version the sheet had when the rewrite began — kept in the history
// like every version, so the rewrite stores only its hash (per Mac, in the defaults) and survives closing the sheet or the
// app. "Done" just closes the left side; "back to the original" saves the original text as a new version.
import Foundation

struct Rewrite: Equatable {
    let sheet: String
    /// The history block the rewrite started from.
    let base: String
    /// The original manuscript (without the author's note, which stays in its field on the right).
    let original: String
    /// Characters with spaces, the body as posted (the footer's count).
    let count: Int
}

extension AppModel {
    private static let rewriteKey = "ithaca.rewrite"

    /// Sheet id → hash of the version its rewrite started from.
    private var rewriteBases: [String: String] {
        get { defaults.dictionary(forKey: Self.rewriteKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.rewriteKey) }
    }

    private var openIsManuscript: Bool { sheet?.episode != nil && openEntry == nil }

    /// The manuscript of a stored text: without the note for a manuscript, all of it for a blank page.
    private func body(of text: String) -> String { openIsManuscript ? TextMetrics.noteParts(text).body : text }

    var canRewrite: Bool {
        sheetId != nil && !editorLocked && rewrite == nil && openEntry == nil
            && !body(of: liveText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The right side is still empty: "bring the original over" is offered.
    var rewriteBodyEmpty: Bool { body(of: liveText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// After a sheet opens: its rewrite, if one is going on.
    func refreshRewrite() {
        guard let projectId, let sheetId, let base = rewriteBases[sheetId] else { rewrite = nil; return }
        if rewrite?.sheet == sheetId && rewrite?.base == base { return }
        do {
            let original = body(of: try library.textAt(project: projectId, sheet: sheetId, hash: base))
            let count = library.countFor(text: library.platformBody(text: original), rule: .withSpaces)
            rewrite = Rewrite(sheet: sheetId, base: base, original: original, count: count)
        } catch {
            forgetRewrite(sheetId)
            showToast(Toast(message: t(.rewriteLost)))
        }
    }

    /// Toolbar · Sheet menu · list menu: the original goes to the left, the manuscript (its note kept) is emptied.
    func startRewrite() {
        guard canRewrite, let projectId, let sheetId else { return }
        guard ensureSaved() else { return }
        do {
            guard let base = try library.history(project: projectId, sheet: sheetId).first?.hash else { return }
            let fresh = openIsManuscript ? TextMetrics.joinNote(body: "", note: TextMetrics.noteParts(text).note, title: t(.noteTitle)) : ""
            replaceSummary(try library.saveSheet(project: projectId, sheet: sheetId, text: fresh))
            var bases = rewriteBases
            bases[sheetId] = base
            rewriteBases = bases
            openSheet(sheetId, at: NSRange(location: 0, length: 0))
        } catch { fail(error) }
    }

    /// "다 썼어요": the new text stays; the left side closes.
    func finishRewrite() {
        guard let sheetId, rewrite != nil else { return }
        flushSave()
        forgetRewrite(sheetId)
        showToast(Toast(message: t(.rewriteFinished)))
    }

    /// "원래 글로 되돌리기": the original back as a new version (what was written stays in the history), the note as it is now.
    func revertRewrite() {
        guard let r = rewrite, let projectId, let sheetId, !editorLocked else { return }
        guard ensureSaved() else { return }
        let restored = openIsManuscript ? TextMetrics.joinNote(body: r.original, note: TextMetrics.noteParts(text).note, title: t(.noteTitle)) : r.original
        do {
            replaceSummary(try library.saveSheet(project: projectId, sheet: sheetId, text: restored))
            forgetRewrite(sheetId)
            openSheet(sheetId)
            showToast(Toast(message: t(.rewriteReverted)))
        } catch { fail(error) }
    }

    /// "원래 글 가져오기": the original into the empty right side, to be changed as it goes (one undo step).
    func bringOriginal() {
        guard let r = rewrite, !editorLocked else { return }
        editor?.replaceBody(with: r.original)
    }

    private func forgetRewrite(_ sheet: String) {
        var bases = rewriteBases
        bases[sheet] = nil
        rewriteBases = bases
        if rewrite?.sheet == sheet { rewrite = nil }
    }
}
