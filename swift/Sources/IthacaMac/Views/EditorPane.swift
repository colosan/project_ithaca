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
            if model.readOnly {
                EditorBanner(icon: .lease, message: model.readOnlyMessage)
            }
            if !model.info.problems.isEmpty && !model.problemsDismissed {
                EditorBanner(icon: .warning, message: model.t(.libraryProblems, ["count": model.info.problems.count], count: model.info.problems.count)) {
                    model.problemsDismissed = true
                }
            }
            if model.projectId != nil && model.tocDamagedProject == model.projectId {
                TocDamagedBanner()
            }
            if model.sheet?.damaged == true {
                DamagedSheetBanner()
            }
            if model.sheetId != nil {
                ManuscriptView(model: model, sizeClass: sizeClass)
                    .opacity(model.editorLocked ? T.Opacity.readOnly : 1)
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
            if model.focusMode {
                Spacer(minLength: 0)
                KitButton(model.t(.focusExit), icon: .focus, variant: .ghost) { model.focusMode = false }
            } else {
                if !panes.list || panes.compact {
                    IconButton(.library, label: model.t(.libraryShow), active: model.libraryOverlay) { model.libraryOverlay.toggle() }
                }
                Spacer(minLength: 0)
                IconButton(.command, label: model.t(.paletteTitle)) { model.show(.palette(search: false)) }
                IconButton(.focus, label: model.t(.focusTitle)) { model.toggleFocus() }
                if model.sheetId != nil {
                    IconButton(.history, label: model.t(.historyTitle)) { model.show(.history) }
                    IconButton(.export, label: model.t(.exportTitle)) { model.show(.export) }
                }
                IconButton(.reference, label: model.t(.inspectorTitle), active: model.inspectorOpen) { model.toggleInspector() }
            }
        }
        .padding(.horizontal, T.Space.s150)
        .frame(minHeight: T.Size.barTop)
    }

    private var empty: some View {
        VStack(spacing: T.Space.s200) {
            Icon(.sheet, size: T.Size.iconLg, color: .inkTertiary)
            Text(model.t(.editorNoSheet)).foregroundStyle(Color.inkTertiary)
            if model.folder != nil && !model.showingTrash && !model.readOnly {
                KitButton(model.t(.sheetNew), icon: .add, variant: .primary) { model.newSheet() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A warning strip above the manuscript (read-only library, problems found on open). `dismiss` adds a close button.
struct EditorBanner: View {
    @Environment(AppModel.self) private var model
    let icon: IthacaIcon
    let message: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: T.Space.s150) {
            Icon(icon, size: T.Size.iconSm)
            Text(message).textStyle(.label).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) { Icon(.close, size: T.Size.iconSm) }
                    .buttonStyle(.plain)
                    .help(model.t(.actionClose))
            }
        }
        .foregroundStyle(Color.stateWarning)
        .padding(T.Space.s150)
        .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.accentSoft))
        .padding(.horizontal, T.Space.s200)
    }
}

/// A damaged sheet (part of its history unreadable): the last intact text, read-only, with a way back.
struct DamagedSheetBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s100) {
            HStack(alignment: .top, spacing: T.Space.s150) {
                Icon(.warning, size: T.Size.iconSm)
                Text(model.t(.sheetDamaged)).textStyle(.label).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.stateDanger)
            let noBackup = model.noBackupForSheet == model.sheetId
            if noBackup {
                Text(model.t(.sheetNoBackupHasIt)).textStyle(.caption).foregroundStyle(Color.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            // Wraps when the editor is narrow (three buttons side by side clip below ~700 pt).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: T.Space.s100) { buttons(noBackup); Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: T.Space.s100) { buttons(noBackup) }
            }
        }
        .padding(T.Space.s150)
        .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.accentSoft))
        .padding(.horizontal, T.Space.s200)
        .padding(.bottom, T.Space.s100)
    }

    @ViewBuilder private func buttons(_ noBackup: Bool) -> some View {
        if noBackup {
            KitButton(model.t(.sheetKeepLastGood), icon: .check, variant: .primary) { model.keepLastGoodText() }.disabled(model.readOnly)
            KitButton(model.t(.sheetRecoverFromBackup), icon: .restore) { model.recoverDamagedSheet() }.disabled(model.readOnly)
        } else {
            KitButton(model.t(.sheetRecoverFromBackup), icon: .restore, variant: .primary) { model.recoverDamagedSheet() }.disabled(model.readOnly)
        }
        KitButton(model.t(.saveCopyText), icon: .copy) { model.copyUnsavedText() }
    }
}

/// Damaged table of contents: changes to this project can't be saved; restoring a backup copy is the way out.
struct TocDamagedBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: T.Space.s150) {
            Icon(.warning, size: T.Size.iconSm)
            Text(model.t(.projectTocDamaged)).textStyle(.label).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            KitButton(model.t(.projectTocDamagedAction), icon: .backup) {
                AppEnvironment.defaults.set(SettingsSection.backup.rawValue, forKey: "ithaca.settingsTab")
                openSettingsWindow()
            }
            .fixedSize()
        }
        .foregroundStyle(Color.stateDanger)
        .padding(T.Space.s150)
        .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.accentSoft))
        .padding(.horizontal, T.Space.s200)
        .padding(.bottom, T.Space.s100)
    }
}

/// Both counts always (words for English manuscripts), goal bar when the project sets one, honest save state.
struct EditorFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let c = model.liveCounts
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
                if model.language == .ko {
                    Text(model.t(.countWithSpaces, ["count": c.chars])).help(model.t(.countWithSpacesHint))
                    Text(model.t(.countWithoutSpaces, ["count": c.charsNoSpace])).help(model.t(.countWithoutSpacesHint))
                } else {
                    Text(model.t(.countWords, ["count": c.words], count: c.words))
                    Text(model.t(.countWithSpaces, ["count": c.chars], count: c.chars)).help(model.t(.countWithSpacesHint))
                }
                if let goal {
                    Text(model.t(.goalProgress, ["goal": goal.count, "percent": percent])).foregroundStyle(Color.inkSecondary)
                        .help(goalBasisName(goal.basis))
                }
                saveStatus
            }
            .textStyle(.caption)
            .foregroundStyle(Color.inkTertiary)
            .padding(.horizontal, T.Space.s150)
            .frame(maxWidth: .infinity, minHeight: T.Size.controlMd)
        }
        .hairline(.top)
    }

    private func goalBasisName(_ b: GoalBasis) -> String {
        model.t(.projectSettingsGoal) + " · " + model.t(GoalField.key(b))
    }

    @ViewBuilder private var saveStatus: some View {
        switch model.saveStatus {
        case .saved:
            Label { Text(model.t(.syncSavedLocal)) } icon: { Icon(.synced, size: T.Size.iconSm) }.foregroundStyle(Color.stateSuccess)
        case .pending:
            Label { Text(model.t(.syncSaving)) } icon: { Icon(.synced, size: T.Size.iconSm) }
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
