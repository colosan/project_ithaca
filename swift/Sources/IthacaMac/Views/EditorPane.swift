// Editor pane: toolbar, the manuscript, counts footer (app-shell spec: editor toolbar, length display).
import IthacaDesign
import SwiftUI

struct EditorPane: View {
    @Environment(AppModel.self) private var model
    let sizeClass: T.Layout.SizeClass
    let panes: Panes

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            NoticeBar()
            if model.sheetId != nil {
                // Rewrite: the original on the left, the manuscript being written again on the right. The manuscript keeps
                // its place in the tree either way, so starting or ending a rewrite never reloads it.
                let rewrite = model.mini ? nil : model.rewrite
                if rewrite != nil { RewriteBar() }
                HStack(spacing: 0) {
                    if let rewrite {
                        OriginalPane(rewrite: rewrite, sizeClass: sizeClass)
                            .frame(minWidth: 0, maxWidth: .infinity)
                        Rectangle().fill(Color.lineSubtle).frame(width: T.Size.strokeHairline)
                    }
                    ManuscriptView(model: model, sizeClass: sizeClass)
                        .opacity(model.editorLocked ? T.Opacity.readOnly : 1)
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
                EditorFooter()
            } else {
                empty
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceCanvas)
    }

    private var toolbar: some View {
        HStack(spacing: T.Space.s50) {
            if model.mini {
                // A note: which sheet, and the way back. ⌘[ ⌘] still switch sheets.
                Text(model.sheet.map { $0.title.isEmpty ? model.t(.sheetUntitled) : $0.title } ?? "")
                    .textStyle(.label).foregroundStyle(Color.inkSecondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                KitButton(model.t(.miniExit), icon: .expand, variant: .ghost) { model.toggleMini() }
            } else if model.panesHidden {
                Spacer(minLength: 0)
                KitButton(model.t(.miniButton), icon: .mini, variant: .ghost) { model.toggleMini() }
                KitButton(model.t(model.focusMode ? .focusExit : .editorOnlyExit), icon: .focus, variant: .ghost) { model.showPanes() }
            } else {
                if !panes.list || panes.compact {
                    IconButton(.library, label: model.t(.libraryShow), active: model.libraryOverlay) { model.libraryOverlay.toggle() }
                }
                Spacer(minLength: 0)
                // The writing tools stay in sight; the rest, labelled, behind ⋯ (0.10.0: fewer marks above the text).
                IconButton(.focus, label: model.t(.focusTitle)) { model.toggleFocus() }
                if model.sheetId != nil {
                    if model.rewrite == nil {
                        IconButton(.rewrite, label: model.t(.rewriteStart)) { model.startRewrite() }
                            .disabled(!model.canRewrite)
                            .help(model.t(.rewriteStartHint))
                    }
                    IconButton(.history, label: model.t(.historyTitle)) { model.show(.history) }
                }
                IconButton(.reference, label: model.t(.inspectorTitle), active: model.inspectorOpen) { model.toggleInspector() }
                more
            }
        }
        .padding(.horizontal, T.Space.s150)
        // The note's bar sits under the traffic lights' row: leave them room on the left.
        .padding(.leading, model.mini ? 64 : 0)
        .frame(minHeight: T.Size.barTop)
    }

    private var more: some View {
        Menu {
            Button(model.t(.miniButton)) { model.toggleMini() }
            Button(model.t(.paletteTitle)) { model.show(.palette(search: false)) }
            if model.sheetId != nil {
                Divider()
                Button(model.t(.exportTitle) + "…") { model.show(.export) }
            }
        } label: {
            Icon(.more, size: T.Size.iconMd, color: .inkTertiary)
                .frame(width: T.Size.controlSm, height: T.Size.controlSm)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.t(.navMore))
        .accessibilityLabel(model.t(.navMore))
    }

    @ViewBuilder private var empty: some View {
        if model.projects.isEmpty { noProject } else { noSheet }
    }

    /// No project at all (first run after closing the welcome, or the last one deleted): the welcome's actions.
    private var noProject: some View {
        VStack(spacing: T.Space.s200) {
            Icon(.sheet, size: T.Size.iconLg, color: .inkTertiary)
            VStack(spacing: T.Space.s50) {
                Text(model.t(.editorNoProject)).textStyle(.heading)
                Text(model.t(.editorNoProjectHint)).textStyle(.body).foregroundStyle(Color.inkSecondary)
            }
            if !model.readOnly {
                KitButton(model.t(.libraryNewProject) + "…", icon: .add, variant: .primary) { model.show(.newProject(firstRun: false)) }
                HStack(spacing: T.Space.s100) {
                    KitButton(model.t(.importWeb) + "…", icon: .restore) { model.importWebBackup() }
                    KitButton(model.t(.importTextFolder) + "…", icon: .folderOpen) { model.importTextFolder() }
                        .help(model.t(.importTextFolderHint))
                }
                .disabled(model.busy != nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSheet: some View {
        VStack(spacing: T.Space.s200) {
            Icon(.sheet, size: T.Size.iconLg, color: .inkTertiary)
            Text(model.t(.editorNoSheet)).textStyle(.body).foregroundStyle(Color.inkTertiary)
            if model.folder != nil && !model.showingTrash && !model.readOnly {
                KitButton(model.t(.sheetNew), icon: .add, variant: .primary) { model.newSheet() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Everything wrong above the manuscript in one compact bar: the most important notice on one line (with its
/// main action), the rest behind "자세히" — damaged sheet › damaged table of contents › read-only library › problems on open.
struct NoticeBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("ithaca.noticeExpanded") private var expanded = false

    private enum Kind { case damagedSheet, tocDamaged, readOnly, problems }

    private var kinds: [Kind] {
        var k: [Kind] = []
        if model.sheet?.damaged == true { k.append(.damagedSheet) }
        if model.projectId != nil && model.tocDamagedProject == model.projectId { k.append(.tocDamaged) }
        if model.readOnly { k.append(.readOnly) }
        // Read-only because of these problems: the read-only notice already says so; the list sits under "자세히".
        if !model.info.problems.isEmpty && !model.problemsDismissed && model.readOnlyCause == nil { k.append(.problems) }
        return k
    }

    var body: some View {
        let kinds = kinds
        if let first = kinds.first {
            VStack(alignment: .leading, spacing: T.Space.s100) {
                HStack(spacing: T.Space.s100) {
                    Icon(icon(first), size: T.Size.iconSm)
                    // One line; "자세히" wraps it in full.
                    Text(message(first)).textStyle(.label).lineLimit(expanded ? nil : 1).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: expanded).help(message(first))
                    Spacer(minLength: T.Space.s50)
                    primaryAction(first)
                    // "자세히" only when there is more to show (other notices, the problem list, more actions, a long line).
                    if kinds.count > 1 || !model.info.problems.isEmpty || first == .damagedSheet || message(first).count > 60 {
                    Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                        HStack(spacing: T.Space.s25) {
                            Text(model.t(expanded ? .actionHideDetails : .actionDetails))
                            Icon(expanded ? .expanded : .collapsed, size: T.Size.iconSm)
                        }
                        .textStyle(.label)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    }
                    if first == .problems {
                        Button { model.problemsDismissed = true } label: { Icon(.close, size: T.Size.iconSm) }
                            .buttonStyle(.plain)
                            .help(model.t(.actionClose))
                    }
                }
                .foregroundStyle(tone(first))
                if expanded {
                    // Grows with its content, scrolls past ~180 pt so the manuscript stays in view.
                    if kinds.count + model.info.problems.count > 4 {
                        ScrollView { detailList(kinds) }.frame(height: 180)
                    } else {
                        detailList(kinds)
                    }
                }
            }
            .padding(.horizontal, T.Space.s150)
            .padding(.vertical, T.Space.s100)
            .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.accentSoft))
            .padding(.horizontal, T.Space.s200)
            .padding(.bottom, T.Space.s50)
        }
    }

    private func detailList(_ kinds: [Kind]) -> some View {
                        VStack(alignment: .leading, spacing: T.Space.s150) {
                            ForEach(Array(kinds.enumerated()), id: \.offset) { i, k in details(k, first: i == 0) }
                            if !model.info.problems.isEmpty {
                                VStack(alignment: .leading, spacing: T.Space.s50) {
                                    Caption(model.t(.libraryProblemsTitle))
                                    ForEach(Array(model.info.problems.enumerated()), id: \.offset) { _, p in
                                        Text("· " + model.problemText(p)).textStyle(.caption).foregroundStyle(Color.inkSecondary)
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                            .help(p)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func icon(_ k: Kind) -> IthacaIcon { k == .readOnly ? .lease : .warning }
    private func tone(_ k: Kind) -> Color { k == .damagedSheet || k == .tocDamaged ? .stateDanger : .stateWarning }

    private func message(_ k: Kind) -> String {
        switch k {
        case .damagedSheet: model.t(.sheetDamaged)
        case .tocDamaged: model.t(.projectTocDamaged)
        case .readOnly: model.readOnlyMessage
        case .problems: model.t(.libraryProblems, ["count": model.info.problems.count], count: model.info.problems.count)
        }
    }

    private var noBackup: Bool { model.noBackupForSheet == model.sheetId }

    @ViewBuilder private func primaryAction(_ k: Kind) -> some View {
        switch k {
        case .damagedSheet:
            if noBackup {
                KitButton(model.t(.sheetKeepLastGood), icon: .check, variant: .primary) { model.keepLastGoodText() }.disabled(model.readOnly).fixedSize()
            } else {
                KitButton(model.t(.sheetRecoverFromBackup), icon: .restore, variant: .primary) { model.recoverDamagedSheet() }.disabled(model.readOnly).fixedSize()
            }
        case .tocDamaged:
            KitButton(model.t(.projectTocDamagedAction), icon: .backup) { openBackupSettings() }.fixedSize()
        case .readOnly, .problems:
            EmptyView()
        }
    }

    /// The full sentence of each notice, wrapped, with the actions that didn't fit on the line.
    @ViewBuilder private func details(_ k: Kind, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: T.Space.s50) {
            if !first {  // the first one is already the (now wrapped) top line
                HStack(alignment: .top, spacing: T.Space.s100) {
                    Icon(icon(k), size: T.Size.iconSm)
                    Text(message(k)).textStyle(.label).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(tone(k))
            }
            switch k {
            case .damagedSheet:
                if noBackup {
                    Text(model.t(.sheetNoBackupHasIt)).textStyle(.caption).foregroundStyle(Color.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: T.Space.s100) {
                    if !first { primaryAction(k) }
                    if noBackup { KitButton(model.t(.sheetRecoverFromBackup), icon: .restore) { model.recoverDamagedSheet() }.disabled(model.readOnly).fixedSize() }
                    KitButton(model.t(.saveCopyText), icon: .copy) { model.copyUnsavedText() }.fixedSize()
                }
            case .tocDamaged:
                if !first { primaryAction(k) }
            case .readOnly, .problems:
                EmptyView()
            }
        }
    }

    private func openBackupSettings() {
        AppEnvironment.defaults.set(SettingsSection.backup.rawValue, forKey: "ithaca.settingsTab")
        openSettingsWindow()
    }
}

/// Both counts always (words for English manuscripts), goal bar when the project sets one, honest save state.
struct EditorFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The body as posted (PRODUCT "글자수 정의"); the whole manuscript is in the tooltip and the Info tab.
        let c = model.livePostedCounts
        let raw = model.liveCounts
        let goal = model.project?.goal
        let percent = goal.map { min(100, Int((Double(model.goalValue($0.basis)) / Double(max(1, $0.count)) * 100).rounded())) } ?? 0
        VStack(spacing: 0) {
            if goal != nil {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.lineSubtle)
                        Rectangle().fill(percent >= 100 ? Color.stateSuccess : .accentPrimary).frame(width: g.size.width * Double(percent) / 100)
                    }
                }
                .frame(height: T.Size.strokeFocus)
            }
            HStack(spacing: T.Space.s150) {
                // One count in sight (with spaces, as the serial sites count); the rest in the tooltip (0.10.0).
                let hint = [model.t(.countWithSpaces, ["count": c.chars]), model.t(.countWithoutSpaces, ["count": c.charsNoSpace]),
                            model.t(.countPostedHint, ["raw": raw.chars]),
                            goal.map { goalBasisName($0.basis) + " " + model.t(.goalProgress, ["goal": $0.count, "percent": percent]) }]
                    .compactMap { $0 }.joined(separator: "\n")
                Text(model.language == .ko ? model.t(.countCharsShort, ["count": c.chars], count: c.chars)
                                           : model.t(.countWords, ["count": c.words], count: c.words))
                    .help(hint)
                if goal != nil, !model.mini { Text(model.t(.goalPercent, ["percent": percent])).help(hint) }
                saveStatus
            }
            .textStyle(.caption)
            .foregroundStyle(Color.inkTertiary)
            .padding(.horizontal, T.Space.s150)
            .frame(maxWidth: .infinity, minHeight: T.Size.controlMd)
        }
        .hairline(.top)
    }

    private var savedHint: String {
        let backup = model.lastBackupAt.map { model.t(.backupLastAt, ["date": model.dateTime($0.date)]) } ?? model.t(.backupLastNone)
        return model.t(.syncSavedLocalHint) + "\n" + backup
    }

    private func goalBasisName(_ b: GoalBasis) -> String {
        model.t(.projectSettingsGoal) + " · " + model.t(GoalField.key(b))
    }

    /// Saved here, and GitHub sync is on (ADR-0013): a cloud, quiet unless sync is stuck.
    @ViewBuilder private func synced(_ sync: SyncEngine) -> some View {
        let backup = model.lastBackupAt.map { model.t(.backupLastAt, ["date": model.dateTime($0.date)]) } ?? model.t(.backupLastNone)
        if let e = sync.failure {
            let message = sync.message(e) { model.t($0, $1) }
            // Offline passes by itself: the mark only. Anything else needs the writer (token, repository): words too.
            HStack(spacing: T.Space.s50) {
                Icon(.syncOff, size: T.Size.iconSm, color: e == .offline ? .inkTertiary : .stateWarning)
                if e != .offline { Text(model.t(.syncGithubFailedShort)).foregroundStyle(Color.stateWarning) }
            }
            .help(message).accessibilityLabel(message)
        } else if sync.busy {
            Icon(.sync, size: T.Size.iconSm, color: .inkTertiary)
                .help(model.t(.syncInProgress)).accessibilityLabel(model.t(.syncInProgress))
        } else {
            let when = sync.lastSync.map(model.syncedAgo) ?? model.t(.syncGithubNever)
            Icon(.synced, size: T.Size.iconSm, color: .inkTertiary)
                .help(model.t(.syncGithubFooter) + " · " + when + "\n" + backup).accessibilityLabel(model.t(.syncGithubFooter))
        }
    }

    @ViewBuilder private var saveStatus: some View {
        if model.sheet?.damaged == true {
            // A damaged sheet shows its last intact text; nothing typed here is kept — never "saved".
            Label { Text(model.t(.syncDamaged)) } icon: { Icon(.warning, size: T.Size.iconSm) }
                .foregroundStyle(Color.stateDanger)
                .fontWeight(.semibold)
                .help(model.t(.sheetDamaged))
        } else if model.readOnly, model.saveStatus == .saved {
            Label { Text(model.t(.leaseReadOnly)) } icon: { Icon(.lease, size: T.Size.iconSm) }
                .foregroundStyle(Color.stateWarning)
                .help(model.readOnlyMessage)
        } else {
            status
        }
    }

    @ViewBuilder private var status: some View {
        switch model.saveStatus {
        case .saved:
            if let sync = model.sync, sync.connected {
                synced(sync)
            } else {
                // A local disk, not a cloud: nothing leaves this Mac. The tooltip says when the last backup was made.
                // Quiet when all is well: the mark alone, the words in its tooltip; trouble below speaks up.
                Icon(.savedLocal, size: T.Size.iconSm, color: .inkTertiary)
                    .help(model.t(.syncSavedLocal) + "\n" + savedHint).accessibilityLabel(model.t(.syncSavedLocal))
            }
        case .pending:
            Icon(.savedLocal, size: T.Size.iconSm, color: .inkTertiary).opacity(T.Opacity.disabled)
                .help(model.t(.syncSaving)).accessibilityLabel(model.t(.syncSaving))
        case .failed(let message):
            // Stays until a save succeeds; retries run on their own (AppModel.retryDelays), the button saves now.
            HStack(spacing: T.Space.s100) {
                Label { Text(model.t(.syncSaveFailedApp, ["message": message])) } icon: { Icon(.warning, size: T.Size.iconSm) }
                    .foregroundStyle(Color.stateDanger)
                    .fontWeight(.semibold)
                    .help(model.t(.saveAutoRetryHint))
                if !model.readOnly {
                    Button(model.t(.actionRetry)) { model.retrySave() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentPrimary)
                }
            }
        }
    }
}
