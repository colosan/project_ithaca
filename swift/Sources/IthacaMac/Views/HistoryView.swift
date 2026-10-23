// History (design/screens/history): every block of the sheet, newest first; paragraph diff; restore as a new block.
import IthacaDesign
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Filter: Hashable { case all, claude, device }

    @State private var entries: [HistoryEntry] = []
    @State private var report: IntegrityReport?
    @State private var filter = Filter.all
    @State private var selected: String?
    @State private var before = ""
    @State private var after = ""
    @State private var restored = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: T.Space.s150) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.t(.historyTitle)).textStyle(.title)
                    // The count is this sheet's records; the hash check itself covers the whole project.
                    if let r = report {
                        HStack(spacing: T.Space.s50) {
                            Icon(r.ok ? .verified : .warning, size: T.Size.iconSm, color: r.ok ? .stateSuccess : .stateDanger)
                            Text(r.ok ? model.t(.historyIntegrity, ["count": entries.count], count: entries.count)
                                      : model.t(.historyIntegrityFailed, ["message": r.message ?? ""]))
                        }
                        .textStyle(.caption)
                        .foregroundStyle(r.ok ? Color.inkTertiary : .stateDanger)
                    }
                }
                Spacer()
                Picker("", selection: $filter) {
                    Text(model.t(.historyFilterAll)).tag(Filter.all)
                    Text(model.t(.historyFilterClaude)).tag(Filter.claude)
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
        .onChange(of: filter) { selected = visible.first?.hash; loadDiff() }
        .onChange(of: selected) { restored = false; loadDiff() }
    }

    private var visible: [HistoryEntry] {
        switch filter {
        case .all: entries
        case .claude: entries.filter { $0.actor == .claude }
        case .device: entries.filter { $0.device == AppEnvironment.deviceId || $0.device == AppEnvironment.deviceName }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if visible.isEmpty { Caption(model.t(.historyEmpty)).padding(T.Space.s300) }
                ForEach(visible) { e in
                    let on = e.hash == selected
                    VStack(alignment: .leading, spacing: T.Space.s25) {
                        HStack(spacing: T.Space.s50) {
                            if e.actor == .claude { Icon(.claude, size: T.Size.iconSm, color: .accentPrimary) }
                            Text(e.actor == .claude ? model.t(.historyActorClaude) : model.t(.historyActorMe)).fontWeight(.semibold)
                            Text("·").foregroundStyle(Color.inkTertiary)
                            Text(kindLabel(e.kind)).foregroundStyle(Color.inkSecondary)
                            Spacer(minLength: 0)
                            if e.kind == .edit {
                                Text("+\(e.added)").foregroundStyle(Color.stateSuccess)
                                Text("−\(e.removed)").foregroundStyle(Color.stateDanger)
                            }
                        }
                        .textStyle(.label)
                        Caption("\(e.at.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: model.locale.rawValue)))) · \(deviceLabel(e.device))")
                    }
                    .padding(.horizontal, T.Space.s200)
                    .padding(.vertical, T.Space.s150)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(on ? Color.surfaceSelected : .clear)
                    .hairline(.bottom)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = e.hash }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let e = visible.first(where: { $0.hash == selected }) {
            VStack(alignment: .leading, spacing: T.Space.s150) {
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
                    if before != after || e.hash != entries.first?.hash {
                        KitButton(model.t(.historyRestore), icon: .restore, variant: .primary) {
                            model.restoreVersion(e.hash)
                            restored = true
                            reload(keepSelection: true)
                        }
                        .disabled(model.editorLocked || e.hash == entries.first?.hash)
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

    private func reload(keepSelection: Bool = false) {
        guard let p = model.projectId, let s = model.sheetId else { return }
        entries = (try? model.library.history(project: p, sheet: s)) ?? []
        report = try? model.library.verify(project: p)
        if !keepSelection || !entries.contains(where: { $0.hash == selected }) { selected = visible.first?.hash }
        loadDiff()
    }

    private func loadDiff() {
        guard let p = model.projectId, let s = model.sheetId, let h = selected, let i = entries.firstIndex(where: { $0.hash == h }) else { before = ""; after = ""; return }
        after = (try? model.library.textAt(project: p, sheet: s, hash: h)) ?? ""
        before = i + 1 < entries.count ? ((try? model.library.textAt(project: p, sheet: s, hash: entries[i + 1].hash)) ?? "") : ""
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
