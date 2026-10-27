// The story bible summary card (design/screens/story-bible/spec.md §3) and the inspector's bible sections (§4).
// One content view for the editor's popover and the inspector's inline card.
import IthacaDesign
import SwiftUI

/// Kind icon · name · status / summary / last seen + its lines / voice / forms of address / latest change / [open entry].
/// Fields that are empty are left out, line and all.
struct EntryCardContent: View {
    let entry: BibleEntry
    let last: Appearance?
    var first: Appearance? = nil
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
                    if let first, first.sheet != last.sheet {
                        Caption(model.t(.bibleCardFirstLast, ["first": model.appearanceLabel(first), "last": model.appearanceLabel(last)]))
                    } else {
                        Caption(model.t(.bibleCardLastSeen, ["episode": model.appearanceLabel(last)]))
                    }
                    ForEach(Array(last.lines.prefix(3).enumerated()), id: \.offset) { _, line in
                        Text(line).textStyle(.label).foregroundStyle(Color.inkSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            part(.bibleCardVoice, entry.section(.voice))
            part(.bibleCardAddress, entry.section(.address))
            // As of the open episode: revising 120 doesn't show what changes in 238.
            part(.bibleCardChange, entry.latestChange(through: model.currentEpisode))
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
    let seen: (first: Appearance?, last: Appearance?)
    let model: AppModel
    let onOpen: () -> Void

    var body: some View {
        EntryCardContent(entry: entry, last: seen.last, first: seen.first, model: model, onOpen: onOpen)
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
    /// The expanded card's first and last appearance, looked up once when it opens (not on every redraw).
    @State private var seen: (first: Appearance?, last: Appearance?) = (nil, nil)

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
                        seen = expanded == nil ? (nil, nil) : model.cardAppearances(of: e)
                    }
                    if expanded == e.sheet {
                        EntryCardContent(entry: e, last: seen.last, first: seen.first, model: model, header: false) { model.openSheet(e.sheet) }
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
    @State private var query = ""
    @State private var hits: [LineHit] = []

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s25) {
            Caption(model.t(.infoAppearances)).padding(.bottom, T.Space.s25)
            if !rows.isEmpty {
                // "서윤 … 눈": check an old description without searching every episode (v3 §1.5).
                TextField(model.t(.infoAppearanceSearch), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.bottom, T.Space.s50)
                    .task(id: query) {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        hits = model.searchAppearances(entry, query)
                    }
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if hits.isEmpty {
                        Text(model.t(.infoAppearanceSearchNone)).textStyle(.label).foregroundStyle(Color.inkTertiary)
                    }
                    ForEach(hits) { h in
                        LineHitRow(hit: h) { model.openSheet(h.sheet, at: h.range) }
                    }
                    Spacer().frame(height: T.Space.s100)
                }
            }
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

private struct LineHitRow: View {
    let hit: LineHit
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hit.label).textStyle(.caption).foregroundStyle(Color.inkTertiary)
            Text(hit.line).textStyle(.label).foregroundStyle(Color.inkPrimary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, T.Space.s100)
        .padding(.vertical, T.Space.s50)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(hover ? Color.surfaceSelected : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Reference tab, on top in an episode: the end of the one before (v3 §1.1) — where it broke off and who was there.
struct PreviousEpisodeSection: View {
    @Environment(AppModel.self) private var model
    @State private var prev: (sheet: SheetSummary, tail: String)?
    @State private var names: [BibleEntry] = []
    @State private var hover = false

    var body: some View {
        // A stack, not a Group: `.task` on an empty Group never runs, and the section is empty until it loads.
        VStack(alignment: .leading, spacing: 0) {
            if let prev {
                VStack(alignment: .leading, spacing: T.Space.s50) {
                    Caption(model.t(.referencePreviousEnd, ["episode": prev.sheet.episode?.number.map { model.t(.bibleEpisode, ["number": $0]) } ?? prev.sheet.title]))
                    if !names.isEmpty {
                        // Who was on stage: a wrapped line of names (no chips row that clips in a narrow inspector).
                        Text(names.map(\.name).joined(separator: " · ")).textStyle(.caption).foregroundStyle(Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(prev.tail).textStyle(.label).foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(T.Space.s100)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(hover ? Color.surfaceSelected : Color.surfaceCanvas))
                        .contentShape(Rectangle())
                        .onHover { hover = $0 }
                        .onTapGesture { openEnd(prev.sheet) }
                        .help(model.t(.referencePreviousOpen))
                        .accessibilityAddTraits(.isButton)
                }
                .padding(.bottom, T.Space.s150)
                .hairline(.bottom)
                .padding(.bottom, T.Space.s150)
            }
        }
        .task(id: model.sheetId) { load() }
    }

    private func load() {
        prev = model.previousEpisode()
        guard let prev, let p = model.projectId, !model.bible.isEmpty,
              let text = try? model.library.sheetText(project: p, sheet: prev.sheet.id) else { names = []; return }
        var seen = Set<String>()
        names = ((try? model.library.mentionsIn(project: p, text: text)) ?? []).compactMap { seen.insert($0.entry).inserted ? model.entry($0.entry) : nil }
    }

    private func openEnd(_ s: SheetSummary) {
        guard let p = model.projectId, let text = try? model.library.sheetText(project: p, sheet: s.id) else { return }
        model.openSheet(s.id, at: NSRange(location: (text as NSString).length, length: 0))
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
