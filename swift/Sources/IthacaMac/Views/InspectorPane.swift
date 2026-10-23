// Inspector: reference (another sheet beside the manuscript) · info · outline (app-shell spec).
import IthacaDesign
import SwiftUI

enum InspectorTab: String, CaseIterable { case reference, info, outline }

struct InspectorPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("ithaca.inspectorTab") private var tab: InspectorTab = .reference

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: T.Space.s100) {
                // Fills the bar in every language (short Korean labels left a small, off-centre control).
                FillSegmented(items: [(InspectorTab.reference, model.t(.inspectorReference)), (.info, model.t(.inspectorInfo)),
                                      (.outline, model.t(.inspectorOutline))], selection: $tab)
                    .frame(maxWidth: .infinity)
                IconButton(.close, label: model.t(.actionClose)) { model.inspectorOpen = false }
            }
            .padding(.leading, T.Space.s200)
            .padding(.trailing, T.Space.s150)
            .frame(maxWidth: .infinity, minHeight: T.Size.barTop)
            .hairline(.bottom)
            ScrollView {
                Group {
                    switch tab {
                    case .reference: ReferenceTab()
                    case .info: InfoTab()
                    case .outline: OutlineTab()
                    }
                }
                .padding(T.Space.s200)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.surfaceRaised)
    }
}

/// Any sheet of the project (lore by default) to read while writing. Remembers the pick.
private struct ReferenceTab: View {
    @Environment(AppModel.self) private var model
    @AppStorage("ithaca.reference") private var picked = ""
    @State private var text = ""

    var body: some View {
        let candidates = model.folders.flatMap { f in f.sheets.filter { $0.id != model.sheetId }.map { (f, $0) } }
        let fallback = candidates.first { $0.0.order == 1 }?.1.id ?? candidates.first?.1.id ?? ""
        let id = candidates.contains { $0.1.id == picked } ? picked : fallback
        if candidates.isEmpty {
            Caption(model.t(.referenceNone))
        } else {
            VStack(alignment: .leading, spacing: T.Space.s150) {
                Picker(model.t(.referenceTitle), selection: Binding(get: { id }, set: { picked = $0 })) {
                    ForEach(model.folders) { f in
                        Section(f.name) {
                            ForEach(f.sheets.filter { $0.id != model.sheetId }) { s in
                                Text(s.title.isEmpty ? model.t(.sheetUntitled) : s.title).tag(s.id)
                            }
                        }
                    }
                }
                .labelsHidden()
                VStack(alignment: .leading, spacing: T.Space.s50) {
                    ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        if let r = line.range(of: #"^#+\s"#, options: .regularExpression) {
                            (Text(line[r]).foregroundColor(.inkMarkup) + Text(line[r.upperBound...]))
                                .textStyle(.heading)
                                .padding(.top, T.Space.s100)
                        } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                            Spacer().frame(height: T.Space.s50)
                        } else {
                            Text(line).textStyle(.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .textSelection(.enabled)
            }
            .task(id: id) { load(id) }
        }
    }

    private func load(_ id: String) {
        guard let p = model.projectId, !id.isEmpty else { text = ""; return }
        text = (try? model.library.sheetText(project: p, sheet: id)) ?? ""
    }
}

/// The open sheet, or its folder's totals ("시트 / 폴더"). With no sheet open it shows the folder.
private struct InfoTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        let folderScope = model.inspectorScope == .folder || model.sheet == nil
        VStack(alignment: .leading, spacing: T.Space.s150) {
            if model.folder != nil && model.sheet != nil {
                FillSegmented(items: [(InspectorScope.sheet, model.t(.inspectorScopeSheet)), (.folder, model.t(.inspectorScopeFolder))],
                              selection: $m.inspectorScope)
                    .frame(maxWidth: .infinity)
            }
            if folderScope, let folder = model.folder {
                FolderInfoView(folder: folder)
            } else {
                SheetInfo()
            }
        }
    }
}

private struct SheetInfo: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let sheet = model.sheet {
            let c = model.liveCounts
            let lang = model.language
            let rows: [(String, String)] = [
                (model.t(.infoWithSpaces), model.number(c.chars)),
                (model.t(.infoWithoutSpaces), model.number(c.charsNoSpace)),
                lang == .ko ? (model.t(.infoManuscriptPages), model.t(.infoPages, ["count": (c.chars + 199) / 200], count: (c.chars + 199) / 200))
                            : (model.t(.infoWords), model.number(c.words)),
                (model.t(.infoParagraphs), model.number(c.paragraphs)),
                (model.t(.infoReadingTime), model.t(.infoMinutes, ["count": TextMetrics.readingMinutes(c, lang)], count: TextMetrics.readingMinutes(c, lang))),
                (model.t(.infoCreated), model.dateTime(sheet.created.date)),
                (model.t(.infoModified), model.dateTime(sheet.modified.date)),
            ]
            VStack(alignment: .leading, spacing: 0) {
                Picker(model.t(.episodeStatus), selection: Binding(get: { sheet.episode?.status }, set: { model.setEpisodeStatus($0) })) {
                    Text(model.t(.episodeNone)).tag(EpisodeStatus?.none)
                    ForEach(EpisodeStatus.allCases, id: \.self) { s in Text(model.t(model.statusKey(s))).tag(EpisodeStatus?.some(s)) }
                }
                .disabled(model.readOnly)
                .padding(.bottom, T.Space.s150)
                if let e = sheet.episode, e.status == .scheduled {
                    DatePicker(model.t(.episodePublishAt), selection: Binding(
                        get: { (e.publishAt ?? .nowMillis).date },
                        set: { model.setPublishAt($0) }), displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .environment(\.locale, model.dateLocale)
                        .disabled(model.readOnly)
                        .padding(.bottom, T.Space.s150)
                }
                if sheet.episode?.excluded == true {
                    Caption(model.t(.episodeExcluded) + " — " + model.t(.episodeExcludedHint))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, T.Space.s150)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(alignment: .firstTextBaseline, spacing: T.Space.s150) {
                        Text(row.0).foregroundStyle(Color.inkSecondary).layoutPriority(1)
                        Spacer(minLength: 0)
                        Text(row.1).fontWeight(.semibold).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }
                    .textStyle(.body)
                    .padding(.vertical, T.Space.s100)
                    .hairline(.top, i == 0 ? .clear : .lineSubtle)
                }
                PlatformCounts(sheet: sheet.id, version: sheet.modified)
            }
        } else {
            Caption(model.t(.editorNoSheet))
        }
    }
}

/// Headings and paragraph first lines; clicking moves the caret there.
private struct OutlineTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let text = model.liveText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Caption(model.t(.outlineEmpty))
        } else {
            let items = Self.items(text)
            VStack(alignment: .leading, spacing: T.Space.s25) {
                ForEach(items, id: \.at) { item in
                    OutlineRow(item: item) { model.editor?.select(NSRange(location: item.at, length: 0), center: true) }
                }
            }
        }
    }

    struct Item { let at: Int; let line: String; let heading: Bool }

    static func items(_ text: String) -> [Item] {
        var at = 0
        var out: [Item] = []
        for line in text.components(separatedBy: "\n") {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let heading = TextMetrics.isHeading(Substring(line))
                out.append(Item(at: at, line: heading ? line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression) : line, heading: heading))
            }
            at += (line as NSString).length + 1
        }
        return out
    }
}

private struct OutlineRow: View {
    let item: OutlineTab.Item
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Text(item.line)
            .textStyle(item.heading ? .label : .caption, weight: item.heading ? T.Typography.heading.weight : nil)
            .foregroundStyle(item.heading ? Color.inkPrimary : .inkSecondary)
            .lineLimit(1)
            .padding(.vertical, T.Space.s50)
            .padding(.leading, item.heading ? T.Space.s100 : T.Space.s300)
            .padding(.trailing, T.Space.s100)
            .frame(maxWidth: .infinity, minHeight: T.Size.controlSm, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: T.Radius.control).fill(hover ? Color.surfaceSelected : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}

/// Munpia / Novelpia counts of what would be pasted (export_text with Markdown stripped), as last saved.
private struct PlatformCounts: View {
    @Environment(AppModel.self) private var model
    let sheet: String
    let version: Int64

    var body: some View {
        if model.language == .ko, let p = model.projectId,
           let text = try? model.library.exportText(project: p, sheets: [sheet], options: ExportOptions(blankLine: true, indent: false, stripMarkdown: true, includeTitle: false)) {
            let munpia = model.library.countFor(text: text, rule: .munpia)
            let pages = model.library.munpiaPages(text: text)
            let novelpia = model.library.countFor(text: text, rule: .novelpia)
            VStack(alignment: .leading, spacing: 0) {
                Caption(model.t(.infoPlatform)).padding(.top, T.Space.s200).padding(.bottom, T.Space.s50).help(model.t(.infoPlatformHint))
                row(model.t(.infoMunpia), model.t(.infoChars, ["count": munpia], count: munpia) + " · " + model.t(.infoMunpiaPages, ["count": pages], count: pages), first: true)
                row(model.t(.infoNovelpia), model.t(.infoChars, ["count": novelpia], count: novelpia), first: false)
            }
        }
    }

    private func row(_ k: String, _ v: String, first: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: T.Space.s150) {
            Text(k).foregroundStyle(Color.inkSecondary)
            Spacer(minLength: 0)
            Text(v).fontWeight(.semibold)
        }
        .textStyle(.body)
        .padding(.vertical, T.Space.s100)
        .hairline(.top, first ? .clear : .lineSubtle)
    }
}

/// FolderStats (core folder_stats): totals, episodes, platform counts, status breakdown, next release.
private struct FolderInfoView: View {
    @Environment(AppModel.self) private var model
    let folder: FolderInfo

    var body: some View {
        if let st = model.folderStats(folder) {
            let ko = model.language == .ko
            let next = model.nextRelease(folder)
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.name).textStyle(.heading).lineLimit(2).padding(.bottom, T.Space.s100)
                if st.sheets == 0 {
                    Caption(model.t(.folderStatsNone))
                } else {
                    InfoRow(model.t(.infoWithSpaces), model.number(st.counts.chars), first: true)
                    InfoRow(model.t(.infoWithoutSpaces), model.number(st.counts.charsNoSpace))
                    if !ko { InfoRow(model.t(.infoWords), model.number(st.counts.words)) }
                    InfoRow(model.t(.folderStatsSheets), model.t(.sheetListCount, ["count": st.sheets], count: st.sheets))
                    if st.episodes > 0 {
                        InfoRow(model.t(.folderStatsEpisodes), model.t(.folderStatsEpisodeCount, ["count": st.episodes], count: st.episodes))
                        InfoRow(model.t(.folderStatsAverage), ko ? model.t(.infoChars, ["count": st.averageChars], count: st.averageChars)
                                                                 : model.t(.countWords, ["count": st.episodes == 0 ? 0 : st.counts.words / st.episodes], count: st.counts.words / max(1, st.episodes)))
                        if ko {
                            Caption(model.t(.infoPlatform)).padding(.top, T.Space.s200).padding(.bottom, T.Space.s50).help(model.t(.infoPlatformHint))
                            InfoRow(model.t(.infoMunpia), model.t(.infoChars, ["count": st.munpia], count: st.munpia), first: true)
                            InfoRow(model.t(.infoNovelpia), model.t(.infoChars, ["count": st.novelpia], count: st.novelpia))
                        }
                        Caption(model.t(.folderStatsStatus)).padding(.top, T.Space.s200).padding(.bottom, T.Space.s50)
                        InfoRow(model.t(.folderStatsPublished), model.t(.folderStatsEpisodeCount, ["count": st.published], count: st.published), first: true)
                        InfoRow(model.t(.folderStatsScheduled), model.t(.folderStatsEpisodeCount, ["count": st.scheduled], count: st.scheduled))
                        InfoRow(model.t(.folderStatsDrafts), model.t(.folderStatsEpisodeCount, ["count": st.drafts], count: st.drafts)).help(model.t(.folderStatsDraftsHint))
                        if let next { InfoRow(model.t(.folderStatsNextRelease), model.releaseDate(next, time: true)) }
                    }
                    Caption(model.t(.folderStatsHint)).fixedSize(horizontal: false, vertical: true).padding(.top, T.Space.s200)
                }
            }
        } else {
            Caption(model.t(.folderStatsNone))
        }
    }
}

private struct InfoRow: View {
    let key: String, value: String, first: Bool
    init(_ key: String, _ value: String, first: Bool = false) { self.key = key; self.value = value; self.first = first }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: T.Space.s150) {
            Text(key).foregroundStyle(Color.inkSecondary).layoutPriority(1)
            Spacer(minLength: 0)
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
        .textStyle(.body)
        .padding(.vertical, T.Space.s100)
        .hairline(.top, first ? .clear : .lineSubtle)
    }
}
