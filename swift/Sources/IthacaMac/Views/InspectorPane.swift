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
        PreviousEpisodeSection()
        BibleMentionsSection()
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
    @State private var platform = ""

    var body: some View {
        if let sheet = model.sheet {
            // Posted counts first (what the platform will count), the manuscript as written as one secondary row.
            let c = model.livePostedCounts
            let raw = model.liveCounts
            let lang = model.language
            let details: [(String, String)] = [
                (model.t(.infoRawWithSpaces), model.number(raw.chars)),
                lang == .ko ? (model.t(.infoManuscriptPages), model.t(.infoPages, ["count": (c.chars + 199) / 200], count: (c.chars + 199) / 200))
                            : (model.t(.infoWords), model.number(c.words)),
                (model.t(.infoParagraphs), model.number(c.paragraphs)),
                (model.t(.infoReadingTime), model.t(.infoMinutes, ["count": TextMetrics.readingMinutes(c, lang)], count: TextMetrics.readingMinutes(c, lang))),
                (model.t(.infoCreated), model.dateTime(sheet.created.date)),
                (model.t(.infoModified), model.dateTime(sheet.modified.date)),
            ]
            VStack(alignment: .leading, spacing: 0) {
                if let entry = model.openEntry { EntryAppearancesSection(entry: entry) }
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
                if let e = sheet.episode, e.status == .scheduled || e.status == .published {
                    // A small free-text field; the last platform used is the default for the next episode.
                    LabeledContent(model.t(.episodePlatform)) {
                        TextField(model.t(.episodePlatformPlaceholder), text: $platform)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.setPlatform(platform) }
                            .disabled(model.readOnly)
                    }
                    .textStyle(.body)
                    .padding(.bottom, T.Space.s150)
                    .task(id: sheet.id + (e.platform ?? "")) { platform = e.platform ?? "" }
                    .onDisappear { if platform != (e.platform ?? "") { model.setPlatform(platform) } }
                }
                if sheet.episode?.excluded == true {
                    Caption(model.t(.episodeExcluded) + " — " + model.t(.episodeExcludedHint))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, T.Space.s150)
                }
                // The numbers a serial writer checks before posting, in one compact group near the top.
                VStack(alignment: .leading, spacing: 0) {
                    Caption(model.t(.infoPosted)).padding(.bottom, T.Space.s50).help(model.t(.infoPostedHint))
                    CompactRow(model.t(.infoWithSpaces), model.number(c.chars), first: true)
                    CompactRow(model.t(.infoWithoutSpaces), model.number(c.charsNoSpace))
                    PlatformCounts(sheet: sheet.id, version: sheet.modified)
                }
                .padding(T.Space.s150)
                .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.surfaceCanvas))
                .padding(.bottom, T.Space.s150)
                ForEach(Array(details.enumerated()), id: \.offset) { i, row in
                    CompactRow(row.0, row.1, first: i == 0)
                        .help(i == 0 ? model.t(.infoRawHint) : "")
                }
            }
        } else {
            Caption(model.t(.editorNoSheet))
        }
    }
}

/// One label · value line at caption/label size (the Info tab read as a heavy form at body size).
private struct CompactRow: View {
    let key: String, value: String, first: Bool
    init(_ key: String, _ value: String, first: Bool = false) { self.key = key; self.value = value; self.first = first }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: T.Space.s150) {
            Text(key).foregroundStyle(Color.inkSecondary).layoutPriority(1)
            Spacer(minLength: 0)
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
        .textStyle(.label)
        .padding(.vertical, T.Space.s50)
        .hairline(.top, first ? .clear : .lineSubtle)
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
            CompactRow(model.t(.infoMunpia), model.t(.infoChars, ["count": munpia], count: munpia) + " · " + model.t(.infoMunpiaPages, ["count": pages], count: pages))
                .help(model.t(.infoPlatformHint))
            CompactRow(model.t(.infoNovelpia), model.t(.infoChars, ["count": novelpia], count: novelpia))
                .help(model.t(.infoPlatformHint))
        }
    }
}

/// FolderStats (core folder_stats): totals, episodes, platform counts, status breakdown, next release.
private struct FolderInfoView: View {
    @Environment(AppModel.self) private var model
    let folder: FolderInfo

    var body: some View {
        if let st = model.folderStats(folder) {
            let ko = model.language == .ko
            // Lengths on the posted basis like the rows (the core's FolderStats totals count the text as written).
            let posted = folder.sheets.map { ($0, model.postedCounts(of: $0)) }
            let total = posted.reduce(into: Counts()) { $0.chars += $1.1.chars; $0.charsNoSpace += $1.1.charsNoSpace; $0.words += $1.1.words }
            let episodeChars = posted.filter { $0.0.episode?.excluded != true }.reduce(0) { $0 + $1.1.chars }
            let episodeWords = posted.filter { $0.0.episode?.excluded != true }.reduce(0) { $0 + $1.1.words }
            let average = st.episodes == 0 ? 0 : Int((Double(episodeChars) / Double(st.episodes)).rounded())
            let averageWords = st.episodes == 0 ? 0 : episodeWords / st.episodes
            let next = model.nextRelease(folder)
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.name).textStyle(.heading).lineLimit(2).padding(.bottom, T.Space.s100)
                if st.sheets == 0 {
                    Caption(model.t(.folderStatsNone))
                } else {
                    InfoRow(model.t(.infoWithSpaces), model.number(total.chars), first: true).help(model.t(.infoPostedHint))
                    InfoRow(model.t(.infoWithoutSpaces), model.number(total.charsNoSpace)).help(model.t(.infoPostedHint))
                    if !ko { InfoRow(model.t(.infoWords), model.number(total.words)) }
                    InfoRow(model.t(.folderStatsSheets), model.t(.sheetListCount, ["count": st.sheets], count: st.sheets))
                    if st.episodes > 0 {
                        InfoRow(model.t(.folderStatsEpisodes), model.t(.folderStatsEpisodeCount, ["count": st.episodes], count: st.episodes))
                        InfoRow(model.t(.folderStatsAverage), ko ? model.t(.infoChars, ["count": average], count: average)
                                                                 : model.t(.countWords, ["count": averageWords], count: averageWords))
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
