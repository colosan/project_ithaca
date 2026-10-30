// "What to make": the sheet list's ＋ popover and the empty folder's body (app-shell · story-bible §1).
// A manuscript sheet (episode with the author's note box) first, a blank page (no form), then the four story bible kinds with the fields
// their template brings, then the Notion import.
// Keyboard: ↑↓ choose · Return make · 1–6 make that row · Esc close. ⌘N stays the instant manuscript sheet.
import IthacaCore
import IthacaDesign
import SwiftUI

struct NewSheetPicker: View {
    @Environment(AppModel.self) private var model
    let folder: String
    /// Called after a choice (the popover closes).
    var done: () -> Void = {}
    /// The popover takes the keyboard; the empty folder's copy must not pull it from the editor.
    var autofocus = false
    @State private var index = 0
    @State private var hover: Int?
    @FocusState private var focused: Bool

    private enum Choice: Hashable { case blank, page, entry(EntryKind) }
    private var choices: [Choice] { [.blank, .page] + EntryKind.all.map(Choice.entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s50) {
            Text(model.t(.newSheetTitle)).textStyle(.heading)
                .padding(.horizontal, T.Space.s100)
                .padding(.bottom, T.Space.s50)
            row(0)
            row(1)
            Caption(model.t(.newSheetBible))
                .padding(.horizontal, T.Space.s100)
                .padding(.top, T.Space.s150)
            ForEach(2..<choices.count, id: \.self) { row($0) }
            Rectangle().fill(Color.lineSubtle).frame(height: T.Size.strokeHairline).padding(.vertical, T.Space.s100)
            HStack(spacing: T.Space.s100) {
                KitButton(model.t(.importBibleTitle) + "…", icon: .folderOpen, variant: .ghost) {
                    done()
                    model.importBible()
                }
                Spacer(minLength: 0)
            }
            Caption(model.t(.newSheetShortcut))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, T.Space.s100)
        }
        .padding(T.Space.s150)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { if autofocus { focused = true } }
        .onKeyPress(.downArrow) { index = min(choices.count - 1, index + 1); return .handled }
        .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
        .onKeyPress(.return) { make(choices[index]); return .handled }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), (1...choices.count).contains(n) else { return .ignored }
            make(choices[n - 1])
            return .handled
        }
    }

    private func row(_ i: Int) -> some View {
        let choice = choices[i]
        let on = hover.map { $0 == i } ?? (i == index && focused)
        return Button { make(choice) } label: {
            HStack(alignment: .top, spacing: T.Space.s150) {
                Icon(icon(choice), size: T.Size.iconMd, color: plain(choice) ? .inkSecondary : .accentPrimary)
                    .frame(width: T.Size.controlMd, height: T.Size.controlMd)
                    .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(plain(choice) ? Color.surfaceSelected : Color.accentSoft))
                VStack(alignment: .leading, spacing: T.Space.s25) {
                    Text(title(choice)).textStyle(.label).foregroundStyle(Color.inkPrimary)
                    Text(hint(choice)).textStyle(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1)
                    if case .entry(let k) = choice { fields(k) }
                }
                Spacer(minLength: 0)
                Text("\(i + 1)").textStyle(.caption).foregroundStyle(Color.inkTertiary).opacity(on ? 1 : 0)
            }
            .padding(T.Space.s100)
            .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(on ? Color.surfaceSelected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
        .accessibilityLabel(title(choice) + ", " + hint(choice))
    }

    /// The `## ` fields the template brings (without the summary and the notes every kind has): what makes it a form.
    private func fields(_ kind: EntryKind) -> some View {
        let titles = Self.templateFields(kind, model.language)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: T.Space.s50) {
                ForEach(titles, id: \.self) { t in
                    Text(t).textStyle(.caption).foregroundStyle(Color.inkSecondary).lineLimit(1).fixedSize()
                        .padding(.horizontal, T.Space.s50)
                        .background(Capsule().fill(Color.surfaceSelected))
                }
            }
            Text(titles.joined(separator: " · ")).textStyle(.caption).foregroundStyle(Color.inkTertiary).lineLimit(1)
        }
        .padding(.top, T.Space.s25)
    }

    nonisolated static func templateFields(_ kind: EntryKind, _ language: ManuscriptLanguage) -> [String] {
        var t = IthacaCore.parseEntry(text: IthacaCore.entryTemplate(kind: kind, name: "x", language: language.core))?.sections.map(\.title) ?? []
        if t.count > 1 { t.removeLast() }  // notes
        if t.count > 1 { t.removeFirst() }  // summary
        return t
    }

    private func plain(_ c: Choice) -> Bool { if case .entry = c { false } else { true } }

    private func make(_ c: Choice) {
        done()
        switch c {
        case .blank: model.newSheet(in: folder)
        case .page: model.newSheet(in: folder, .page)
        case .entry(let k): model.newEntry(k, in: folder)
        }
    }

    private func icon(_ c: Choice) -> IthacaIcon {
        switch c {
        case .blank: .edit
        case .page: .sheet
        case .entry(let k): k.icon
        }
    }

    private func title(_ c: Choice) -> String {
        switch c {
        case .blank: model.t(.newSheetBlank)
        case .page: model.t(.newSheetPage)
        case .entry(let k): model.t(k.label)
        }
    }

    private func hint(_ c: Choice) -> String {
        switch c {
        case .blank: model.nextEpisodeNumber(in: folder).map { model.t(.newSheetEpisodeHint, ["number": $0]) } ?? model.t(.newSheetBlankHint)
        case .page: model.t(.newSheetPageHint)
        case .entry(let k): model.t(k.hint)
        }
    }
}
