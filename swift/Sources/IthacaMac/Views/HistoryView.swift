// History (design/screens/history): the sheet's records grouped into writing sessions under day headers, newest
// first. A session expands into its individual saves; any session or save can be restored (a new block).
import IthacaDesign
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Snapshots: open with the newest session expanded and its newest save picked.
    var expandNewest = false

    enum Filter: Hashable { case all, claude, device }

    /// A whole session (`point == nil`) or one save inside it.
    struct Selection: Hashable { var session: String; var point: String? }

    @State private var sessions: [HistorySession] = []
    @State private var report: IntegrityReport?
    @State private var filter = Filter.all
    @State private var selected: Selection?
    @State private var expanded: Set<String> = []
    @State private var before = ""
    @State private var after = ""
    @State private var restored = false

    private var blockCount: Int { sessions.reduce(0) { $0 + $1.entries.count } }
    /// The sheet's current version: restoring it would change nothing.
    private var headHash: String? { sessions.first?.entries.first?.hash }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: T.Space.s150) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.t(.historyTitle)).textStyle(.title)
                    // The count is this sheet's records; the hash check itself covers the whole project.
                    if let r = report {
                        HStack(spacing: T.Space.s50) {
                            Icon(r.ok ? .verified : .warning, size: T.Size.iconSm, color: r.ok ? .stateSuccess : .stateDanger)
                            Text(r.ok ? model.t(.historyIntegrity, ["count": blockCount], count: blockCount)
                                      : model.t(.historyIntegrityFailed, ["message": r.message ?? ""]))
                        }
                        .textStyle(.caption)
                        .foregroundStyle(r.ok ? Color.inkTertiary : .stateDanger)
                    }
                }
                Spacer()
                Picker("", selection: $filter) {
                    Text(model.t(.historyFilterAll)).tag(Filter.all)
                    // "By Claude" stays hidden until Claude can write (ADR-0007: nothing that can't do anything is shown).
                    Text(model.t(.historyFilterDevice)).tag(Filter.device)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                IconButton(.close, label: model.t(.actionClose)) { dismiss() }
            }
            .padding(.horizontal, T.Space.s300)
            .padding(.vertical, T.Space.s150)
            .hairline(.bottom)
            HStack(spacing: 0) {
                list.frame(width: T.Layout.Pane.sheetListDefault)
                    .background(Color.surfaceList)
                    .hairline(.trailing)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 1040, height: 640)
        .background(Color.surfaceCanvas)
        .task { reload() }
        .onChange(of: filter) { selected = visible.first.map { Selection(session: $0.id) }; loadDiff() }
        .onChange(of: selected) { restored = false; loadDiff() }
    }

    private var visible: [HistorySession] {
        switch filter {
        case .all: sessions
        case .claude: sessions.filter { $0.actor == .claude }
        case .device: sessions.filter { $0.device == AppEnvironment.deviceId || $0.device == AppEnvironment.deviceName }
        }
    }

    /// Sessions under their day (by the session's end), newest day first.
    private var days: [(day: Date, sessions: [HistorySession])] {
        let cal = Calendar.current
        var out: [(day: Date, sessions: [HistorySession])] = []
        for s in visible {
            let d = cal.startOfDay(for: s.end.date)
            if out.last?.day == d { out[out.count - 1].sessions.append(s) } else { out.append((d, [s])) }
        }
        return out
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if visible.isEmpty { Caption(model.t(.historyEmpty)).padding(T.Space.s300) }
                ForEach(days, id: \.day) { group in
                    Text(dayLabel(group.day))
                        .textStyle(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.inkTertiary)
                        .padding(.horizontal, T.Space.s200)
                        .padding(.top, T.Space.s200)
                        .padding(.bottom, T.Space.s50)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hairline(.bottom)
                    ForEach(group.sessions) { s in
                        sessionRow(s)
                        if expanded.contains(s.id) {
                            ForEach(s.entries) { e in pointRow(e, in: s) }
                        }
                    }
                }
            }
        }
    }

    private func sessionRow(_ s: HistorySession) -> some View {
        let on = selected == Selection(session: s.id)
        let many = s.entries.count > 1
        return HStack(alignment: .top, spacing: T.Space.s50) {
            // Disclosure only where there is something finer to see.
            Group {
                if many {
                    let open = expanded.contains(s.id)
                    Button { toggle(s.id) } label: {
                        Icon(open ? .expanded : .collapsed, size: T.Size.iconSm, color: .inkTertiary)
                            .frame(width: T.Size.iconSm, height: T.Size.iconSm)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.t(open ? .historyCollapse : .historyExpand))
                    .accessibilityLabel(model.t(open ? .historyCollapse : .historyExpand))
                } else {
                    Color.clear.frame(width: T.Size.iconSm, height: T.Size.iconSm)
                }
            }
            .padding(.top, T.Space.s25)
            VStack(alignment: .leading, spacing: T.Space.s25) {
                HStack(spacing: T.Space.s50) {
                    if s.actor == .claude { Icon(.claude, size: T.Size.iconSm, color: .accentPrimary) }
                    Text(range(s)).fontWeight(.semibold).monospacedDigit()
                    if s.kind == .lease || s.kind == .merge {
                        Text("·").foregroundStyle(Color.inkTertiary)
                        Text(kindLabel(s.kind)).foregroundStyle(Color.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    if s.kind == .edit || s.kind == .meta { counts(s.added, s.removed) }
                }
                .textStyle(.label)
                Caption(([s.actor == .claude ? model.t(.historyActorClaude) : model.t(.historyActorMe), deviceLabel(s.device)]
                         + (many ? [model.t(.historySaves, ["count": s.entries.count], count: s.entries.count)] : []))
                    .joined(separator: " · "))
            }
        }
        .padding(.leading, T.Space.s150)
        .padding(.trailing, T.Space.s200)
        .padding(.vertical, T.Space.s150)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Color.surfaceSelected : .clear)
        .hairline(.bottom)
        .contentShape(Rectangle())
        .onTapGesture { selected = Selection(session: s.id) }
    }

    private func pointRow(_ e: HistoryEntry, in s: HistorySession) -> some View {
        let on = selected == Selection(session: s.id, point: e.hash)
        return HStack(spacing: T.Space.s50) {
            Text(time(e.at)).monospacedDigit().foregroundStyle(Color.inkSecondary)
            if e.hash == headHash {
                Icon(.check, size: T.Size.iconSm, color: .inkTertiary)
            }
            Spacer(minLength: 0)
            counts(e.added, e.removed)
        }
        .textStyle(.caption)
        .padding(.leading, T.Space.s150 + T.Size.iconSm + T.Space.s50 + T.Space.s150)
        .padding(.trailing, T.Space.s200)
        .padding(.vertical, T.Space.s100)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Color.surfaceSelected : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = Selection(session: s.id, point: e.hash) }
    }

    private func counts(_ added: Int, _ removed: Int) -> some View {
        HStack(spacing: T.Space.s50) {
            Text("+\(added.formatted())").foregroundStyle(Color.stateSuccess)
            Text("−\(removed.formatted())").foregroundStyle(Color.stateDanger)
        }
        .monospacedDigit()
    }

    /// What the detail pane shows: the version it restores, and the text before it.
    private func target(_ sel: Selection) -> (session: HistorySession, hash: String, base: String?)? {
        guard let s = sessions.first(where: { $0.id == sel.session }) else { return nil }
        guard let p = sel.point else { return (s, s.entries[0].hash, s.base) }
        guard let i = s.entries.firstIndex(where: { $0.hash == p }) else { return nil }
        // Within a session each save builds on the next one; the oldest builds on `base`.
        return (s, p, i + 1 < s.entries.count ? s.entries[i + 1].hash : s.base)
    }

    @ViewBuilder private var detail: some View {
        if let sel = selected, let t = target(sel) {
            VStack(alignment: .leading, spacing: T.Space.s150) {
                Text(sel.point == nil ? model.t(.historyWholeSession, ["range": range(t.session)])
                                      : model.t(.historySavedAt, ["time": model.dateTime(t.session.entries.first { $0.hash == t.hash }?.at.date ?? Date())]))
                    .textStyle(.label)
                    .fontWeight(.semibold)
                if sel.point == nil, t.session.entries.count > 1 {
                    Caption(model.t(.historySessionHint))
                }
                if before == after {
                    Caption(model.t(.historyNoText))
                    Spacer()
                } else {
                    let diff = Self.diff(before, after)
                    HStack(alignment: .top, spacing: T.Space.s200) {
                        column(model.t(.historyBefore), diff.before, highlight: .surfaceSelected)
                        column(model.t(.historyAfter), diff.after, highlight: .accentSoft)
                    }
                }
                HStack(spacing: T.Space.s150) {
                    if restored {
                        Label { Text(model.t(.historyRestored)) } icon: { Icon(.check, size: T.Size.iconSm) }
                            .foregroundStyle(Color.stateSuccess)
                    } else {
                        Caption(model.t(.historyRestoreHint))
                    }
                    Spacer()
                    if before != after || t.hash != headHash {
                        KitButton(model.t(.historyRestore), icon: .restore, variant: .primary) {
                            model.restoreVersion(t.hash)
                            restored = true
                            reload(keepSelection: true)
                        }
                        .disabled(model.editorLocked || t.hash == headHash)
                    }
                }
                .textStyle(.label)
            }
            .padding(T.Space.s300)
        } else {
            Caption(model.t(.historyPick)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func column(_ title: String, _ lines: [(String, Bool)], highlight: Color) -> some View {
        VStack(alignment: .leading, spacing: T.Space.s100) {
            Caption(title)
            ScrollView {
                VStack(alignment: .leading, spacing: T.Space.s100) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        Text(l.0.isEmpty ? " " : l.0)
                            .textStyle(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, T.Space.s50)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: T.Radius.piece).fill(l.1 ? highlight : .clear))
                    }
                }
                .padding(T.Space.s150)
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: T.Radius.panel).strokeBorder(Color.lineSubtle))
        }
        .frame(maxWidth: .infinity)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
            if selected?.session == id { selected = Selection(session: id) }
        } else {
            expanded.insert(id)
        }
    }

    // MARK: Labels

    private func kindLabel(_ k: BlockKind) -> String {
        switch k {
        case .edit, .meta: model.t(.historyKindEdit)
        case .lease: model.t(.historyKindLease)
        case .merge: model.t(.historyKindMerge)
        }
    }

    private func deviceLabel(_ d: String) -> String {
        d == AppEnvironment.deviceId ? AppEnvironment.deviceName : d
    }

    private func formatted(_ d: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.locale = model.dateLocale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }

    /// Clock time only (the day is in the header): 24-hour for Korean, the locale's clock for English.
    private func time(_ at: Int64) -> String { formatted(at.date, model.locale == .ko ? "HHmm" : "jmm") }

    /// "14:10 – 15:05", or one time for a single save.
    private func range(_ s: HistorySession) -> String {
        let a = time(s.start), b = time(s.end)
        return a == b ? a : "\(a) – \(b)"
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return model.t(.historyToday) }
        if cal.isDateInYesterday(day) { return model.t(.historyYesterday) }
        let thisYear = cal.component(.year, from: day) == cal.component(.year, from: Date())
        return formatted(day, (thisYear ? "" : "y") + "MMMdEEE")
    }

    // MARK: Loading

    private func reload(keepSelection: Bool = false) {
        guard let p = model.projectId, let s = model.sheetId else { return }
        sessions = (try? model.library.historySessions(project: p, sheet: s)) ?? []
        report = try? model.library.verify(project: p)
        let still = selected.flatMap(target) != nil
        if !keepSelection || !still { selected = visible.first.map { Selection(session: $0.id) } }
        if expandNewest, !keepSelection, let first = visible.first, first.entries.count > 1 {
            expanded.insert(first.id)
            selected = Selection(session: first.id, point: first.entries[1].hash)
        }
        loadDiff()
    }

    private func loadDiff() {
        guard let p = model.projectId, let s = model.sheetId, let sel = selected, let t = target(sel) else { before = ""; after = ""; return }
        after = (try? model.library.textAt(project: p, sheet: s, hash: t.hash)) ?? ""
        before = t.base.map { (try? model.library.textAt(project: p, sheet: s, hash: $0)) ?? "" } ?? ""
    }

    /// Paragraph diff: lines only in `before` and lines only in `after` are highlighted; shared lines stay plain.
    static func diff(_ a: String, _ b: String) -> (before: [(String, Bool)], after: [(String, Bool)]) {
        let la = a.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let lb = b.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let d = lb.difference(from: la)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in d {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        return (la.enumerated().map { ($1, removed.contains($0)) }, lb.enumerated().map { ($1, inserted.contains($0)) })
    }
}
