// New project (incl. first run) and project settings (design/screens/new-project, project-settings).
import IthacaDesign
import SwiftUI

struct NewProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let firstRun: Bool

    @State private var title = ""
    @State private var goal: Goal?
    @FocusState private var titleFocused: Bool

    /// Korean manuscripts only (ADR-0011); folders are the defaults, changed later in the sidebar.
    private let language = ManuscriptLanguage.ko

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s200) {
            if firstRun {
                VStack(alignment: .leading, spacing: T.Space.s50) {
                    Text(model.t(.welcomeTitle)).textStyle(.title)
                    Text(model.t(.welcomeSubtitle)).foregroundStyle(Color.inkSecondary)
                }
                // Coming from the web version or a folder of text files: bring it in as a new project.
                HStack(alignment: .center, spacing: T.Space.s150) {
                    VStack(alignment: .leading, spacing: T.Space.s25) {
                        Text(model.t(.welcomeImportWeb)).textStyle(.label)
                        Text(model.t(.importWebHint)).textStyle(.caption).foregroundStyle(Color.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: T.Space.s50) {
                        KitButton(model.t(.importWeb) + "…", icon: .restore) { model.importWebBackup() }
                        KitButton(model.t(.importTextFolder) + "…", icon: .folderOpen) { model.importTextFolder() }
                            .help(model.t(.importTextFolderHint))
                    }
                    .disabled(model.busy != nil)
                    .fixedSize()
                }
                .padding(T.Space.s150)
                .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: T.Radius.panel).strokeBorder(Color.lineSubtle))
                Text(model.t(.welcomeStartFresh)).textStyle(.label).padding(.top, T.Space.s50)
            } else {
                Text(model.t(.newProjectTitle)).textStyle(.title)
            }
            Form {
                TextField(model.t(.projectSettingsName), text: $title, prompt: Text(model.t(.newProjectTitlePlaceholder)))
                    .focused($titleFocused)
                GoalField(goal: $goal, language: language)
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                KitButton(model.t(firstRun ? .welcomeLater : .actionCancel), variant: .ghost) { dismiss() }.keyboardShortcut(.cancelAction)
                KitButton(model.t(.newProjectCreate), variant: .primary, action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textStyle(.label, weight: 400)
        .padding(T.Space.s300)
        .frame(width: T.Layout.Pane.dialogDefault)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.surfaceCanvas)
        .overlay { if let busy = model.busy { BusyHUD(message: busy) } }
        .onAppear { titleFocused = true }
    }

    private func create() {
        let folders = [L10nKey.folderDefaultSerial, .folderDefaultLore, .folderDefaultMaterial].map { model.defaultFolderName($0) }
        model.createProject(title: title, language: language, folders: folders, goal: goal)
    }
}

/// Sheet goal: one popup (none, or a basis) and the count beside it once a basis is chosen.
struct GoalField: View {
    static func key(_ b: GoalBasis) -> L10nKey {
        switch b {
        case .withSpaces: .goalBasisWithSpaces
        case .withoutSpaces: .goalBasisWithoutSpaces
        case .words: .goalBasisWords
        case .munpia: .goalBasisMunpia
        case .novelpia: .goalBasisNovelpia
        }
    }

    @Environment(AppModel.self) private var model
    @Binding var goal: Goal?
    let language: ManuscriptLanguage

    private var bases: [GoalBasis] {
        // Platform bases for Korean manuscripts (research P1); a saved one stays listed either way.
        GoalBasis.allCases.filter { language == .ko || $0 == goal?.basis || ($0 != .munpia && $0 != .novelpia) }
    }

    var body: some View {
        LabeledContent(model.t(.projectSettingsGoal)) {
            VStack(alignment: .leading, spacing: T.Space.s50) {
                HStack {
                    Picker("", selection: Binding(
                        get: { goal?.basis },
                        set: { b in
                            guard let b else { goal = nil; return }
                            goal = Goal(count: goal?.count ?? (b == .words ? 2000 : 5000), basis: b)
                        }
                    )) {
                        Text(model.t(.projectSettingsGoalNone)).tag(GoalBasis?.none)
                        Divider()
                        ForEach(bases, id: \.self) { b in Text(model.t(Self.key(b))).tag(GoalBasis?.some(b)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if let g = goal {
                        TextField("", value: Binding(get: { g.count }, set: { goal = Goal(count: max(0, $0), basis: g.basis) }), format: .number)
                            .labelsHidden()
                            .frame(width: 90)
                    }
                }
                Caption(model.t(.projectSettingsGoalHint))
            }
        }
    }
}

struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var goal: Goal?

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s200) {
            Text(model.t(.projectSettingsTitle)).textStyle(.title)
            Form {
                TextField(model.t(.projectSettingsName), text: $title)
                GoalField(goal: $goal, language: model.project?.language ?? .ko)
            }
            .formStyle(.columns)
            .disabled(model.readOnly)
            HStack {
                if !model.readOnly {
                    KitButton(model.t(.projectSettingsDelete), icon: .delete, variant: .danger) { model.deleteProject() }
                }
                Spacer()
                KitButton(model.t(.actionCancel), variant: .ghost) { dismiss() }.keyboardShortcut(.cancelAction)
                KitButton(model.t(.actionDone), variant: .primary, action: save).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || model.readOnly)
            }
        }
        .textStyle(.label, weight: 400)
        .padding(T.Space.s300)
        .frame(width: T.Layout.Pane.dialogDefault)
        // Hug the content: the sheet otherwise grew taller than the form and centred it under empty space.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.surfaceCanvas)
        .onAppear {
            guard let p = model.project else { return }
            title = p.title
            goal = p.goal
        }
    }

    private func save() {
        model.updateProject(ProjectPatch(title: title.trimmingCharacters(in: .whitespaces),
                                         goal: .some(goal.flatMap { $0.count > 0 ? $0 : nil })))
        model.reloadOutline()
        dismiss()
    }
}
