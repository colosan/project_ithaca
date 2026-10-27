// Story bible actions in the editor (design/screens/story-bible §1): the context menu's "Make Story Bible Entry ▸"
// (with a selection) and "Add Field ▸" (in an entry), and appending a field as one undo step.
import AppKit
import IthacaCore
import IthacaDesign

extension ManuscriptView.Coordinator {
    var selectedText: String {
        guard let tv = textView else { return "" }
        return (tv.string as NSString).substring(with: tv.selectedRange())
    }

    /// `## title` at the end of the sheet through the formatting path (one undo step, no typing conveniences),
    /// caret on the empty line under it.
    func appendSection(_ title: String) {
        guard let tv = editable, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let end = (tv.string as NSString).length
        let insert = StoryBible.sectionInsertion(after: tv.string, title: title)
        replace(tv, NSRange(location: end, length: 0), with: insert, select: NSRange(location: end + (insert as NSString).length, length: 0))
        DispatchQueue.main.async { [weak self] in self?.reveal(center: false) }
    }

    /// The open entry's missing suggested fields, then "Custom Name…". nil when the sheet isn't an entry.
    func addFieldMenu() -> NSMenu? {
        guard let tv = textView, tv.isEditable, let missing = StoryBible.missingSections(tv.string, language: model.language) else { return nil }
        let menu = NSMenu()
        for title in missing { menu.addItem(ActionMenuItem(title) { [weak self] in self?.appendSection(title) }) }
        if !missing.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ActionMenuItem(model.t(.entryAddFieldCustom)) { [weak self] in
            guard let self, let name = StoryBible.promptFieldName(model) else { return }
            appendSection(name)
        })
        return menu
    }

    /// The palette's "Add Field": the same menu at the caret.
    func showAddFieldMenu() {
        guard let tv = editable, let menu = addFieldMenu() else { return }
        var at = NSPoint(x: tv.textContainerInset.width, y: tv.textContainerInset.height)
        if let w = tv.window {
            let rect = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
            if rect != .zero { let r = tv.convert(w.convertFromScreen(rect), from: nil); at = NSPoint(x: r.minX, y: r.maxY + 4) }
        }
        menu.popUp(positioning: nil, at: at, in: tv)
    }

    /// Items for the top of the editor's context menu.
    func entryMenuItems() -> [NSMenuItem] {
        guard let tv = textView, tv.isEditable, !model.readOnly else { return [] }
        var items: [NSMenuItem] = []
        if !StoryBible.name(fromSelection: selectedText).isEmpty {
            let make = NSMenuItem(title: model.t(.entryFromSelection), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for kind in EntryKind.all {
                sub.addItem(ActionMenuItem(model.t(kind.label)) { [weak self] in self?.model.makeEntryFromSelection(kind) })
            }
            make.submenu = sub
            items.append(make)
            // "Note in Story Bible ▸ 서윤": the selection as a line of that entry's notes (v3 §1.4).
            let targets = model.noteTargets(for: selectedText)
            if !targets.isEmpty {
                let note = NSMenuItem(title: model.t(.entryNote), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let text = selectedText
                for e in targets {
                    sub.addItem(ActionMenuItem(e.name) { [weak self] in self?.model.noteInEntry(e, text, asChange: false) })
                }
                note.submenu = sub
                items.append(note)
            }
        }
        if let menu = addFieldMenu() {
            let add = NSMenuItem(title: model.t(.entryAddField), action: nil, keyEquivalent: "")
            add.submenu = menu
            items.append(add)
        }
        return items
    }
}
