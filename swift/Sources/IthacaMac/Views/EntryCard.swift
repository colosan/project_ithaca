// The story bible summary card (design/screens/story-bible/spec.md §3) and the inspector's bible sections (§4).
// One content view for the editor's popover and the inspector's inline card.
import IthacaDesign
import SwiftUI

/// Kind icon · name · status / summary / last seen + its lines / voice / forms of address / latest change / [open entry].
/// Fields that are empty are left out, line and all.
struct EntryCardContent: View {
    let entry: BibleEntry
    let last: Appearance?
    let model: AppModel
    var header = true
    var onOpen: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s100) {
            if header {
                HStack(alignment: .firstTextBaseline, spacing: T.Space.s100) {
                    Icon(entry.kind.icon, size: T.Size.iconSm, color: .inkSecondary)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - T.Space.s25 }
                    Text(entry.name).textStyle(.heading).lineLimit(2)
                    if let s = entry.status { Text(s).textStyle(.caption).foregroundStyle(Color.inkTertiary).lineLimit(1) }
                }
            }
            if let s = entry.summary {
                Text(s).textStyle(.body).foregroundStyle(Color.inkPrimary).fixedSize(horizontal: false, vertical: true)
            }
            if let last {
                VStack(alignment: .leading, spacing: T.Space.s50) {
                    Caption(model.t(.bibleCardLastSeen, ["episode": model.appearanceLabel(last)]))
                    ForEach(Array(last.lines.prefix(3).enumerated()), id: \.offset) { _, line in
                        Text(line).textStyle(.label).foregroundStyle(Color.inkSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            part(.bibleCardVoice, entry.section(.voice))
            part(.bibleCardAddress, entry.section(.address))
            part(.bibleCardChange, entry.latestChange)
            if let onOpen {
                HStack(spacing: T.Space.s100) {
                    KitButton(model.t(.bibleCardOpen), icon: .open, action: onOpen)
                    Text(verbatim: "↩").textStyle(.caption).foregroundStyle(Color.inkTertiary)
                }
                .padding(.top, T.Space.s50)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func part(_ title: L10nKey, _ text: String?) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: T.Space.s25) {
                Caption(model.t(title))
                Text(text).textStyle(.label).foregroundStyle(Color.inkPrimary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The popover's content: the card at a fixed width.
struct EntryCardPopover: View {
    let entry: BibleEntry
    let last: Appearance?
    let model: AppModel
    let onOpen: () -> Void

    var body: some View {
        EntryCardContent(entry: entry, last: last, model: model, onOpen: onOpen)
            .padding(T.Space.s200)
            .frame(width: T.Layout.Pane.inspectorDefault)
            .background(Color.surfaceRaised)
            .environment(\.locale, Locale(identifier: model.locale.rawValue))
    }
}

// MARK: Inspector (spec §4)

/// Reference tab, on top: "이 시트에 나온 항목" — each entry once, in the order it first appears. A row opens its card inline.
struct BibleMentionsSection: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: String?
    /// The expanded card's last appearance, looked up once when it opens (not on every redraw).
    @State private var last: Appearance?

    var body: some View {
        if !model.bible.isEmpty, model.sheetId != nil {
            let entries = model.mentionedEntries
            VStack(alignment: .leading, spacing: T.Space.s25) {
                Caption(model.t(.inspectorMentionsTitle)).padding(.bottom, T.Space.s25)
                if entries.isEmpty {
                    Text(model.t(.inspectorMentionsNone)).textStyle(.label).foregroundStyle(Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(entries) { e in
                    MentionRow(entry: e, open: expanded == e.sheet) {
                        expanded = expanded == e.sheet ? nil : e.sheet
                        last = expanded == nil ? nil : model.lastAppearance(of: e)
                    }
                    if expanded == e.sheet {
                        EntryCardContent(entry: e, last: last, model: model, header: false) { model.openSheet(e.sheet) }
                            .padding(T.Space.s150)
                            .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.surfaceCanvas))
                            .padding(.bottom, T.Space.s100)
                    }
                }
            }
            .padding(.bottom, T.Space.s150)
            .hairline(.bottom)
            .padding(.bottom, T.Space.s150)
        }
    }
}

private struct MentionRow: View {
    @Environment(AppModel.self) private var model
    let entry: BibleEntry
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: T.Space.s100) {
            Icon(entry.kind.icon, size: T.Size.iconSm, color: .inkSecondary)
            Text(entry.name).textStyle(.label, weight: T.Typography.heading.weight).lineLimit(1).layoutPriority(1)
            if let s = entry.summary { Text(s).textStyle(.caption).foregroundStyle(Color.inkTertiary).lineLimit(1) }
            Spacer(minLength: 0)
            Icon(open ? .expanded : .collapsed, size: T.Size.iconSm, color: .inkTertiary)
        }
        .padding(.horizontal, T.Space.s100)
        .frame(maxWidth: .infinity, minHeight: T.Size.controlSm, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(hover || open ? Color.surfaceSelected : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Info tab of an entry sheet: "나온 회차" — "238화 · 3번" rows; a row opens that sheet with the first mention selected.
struct EntryAppearancesSection: View {
    @Environment(AppModel.self) private var model
    let entry: BibleEntry
    @State private var rows: [Appearance] = []

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s25) {
            Caption(model.t(.infoAppearances)).padding(.bottom, T.Space.s25)
            if rows.isEmpty {
                Text(model.t(entry.matchable ? .infoAppearancesNone : .infoAppearancesNoMatch)).textStyle(.label).foregroundStyle(Color.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows.reversed()) { a in
                AppearanceRow(text: model.t(.infoAppearanceRow, ["episode": model.appearanceLabel(a), "count": a.count], count: a.count)) {
                    model.openAppearance(a)
                }
            }
        }
        .padding(.bottom, T.Space.s150)
        // Saved text is what the core reads: refresh when the bible does (after saves) or another entry opens.
        .task(id: "\(entry.sheet):\(model.bible.first { $0.sheet == entry.sheet }?.lastSeen?.sheet ?? "")") { rows = model.appearances(entry.sheet) }
    }
}

private struct AppearanceRow: View {
    let text: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Text(text)
            .textStyle(.label)
            .foregroundStyle(Color.inkPrimary)
            .lineLimit(1)
            .padding(.horizontal, T.Space.s100)
            .frame(maxWidth: .infinity, minHeight: T.Size.controlSm, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(hover ? Color.surfaceSelected : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}
