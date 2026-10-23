// New project (incl. first run) and project settings (design/screens/new-project, project-settings).
import IthacaDesign
import SwiftUI

struct NewProjectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let firstRun: Bool

    @State private var title = ""
    @State private var language: ManuscriptLanguage = .ko
    @State private var goalOn = false
    @State private var goalCount = 5000
    @State private var goalBasis = GoalBasis.withSpaces
    @State private var folders: [(on: Bool, name: String)] = []
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s200) {
            if firstRun {
                VStack(alignment: .leading, spacing: T.Space.s50) {
                    Text(model.t(.welcomeTitle)).textStyle(.display)
                    Text(model.t(.welcomeSubtitle)).textStyle(.body).foregroundStyle(Color.inkSecondary)
                }
                // Coming from the web version: bring its JSON backup in as new projects.
                HStack(alignment: .top, spacing: T.Space.s150) {
                    Icon(.backup, size: T.Size.iconMd, color: .accentPrimary)
                    VStack(alignment: .leading, spacing: T.Space.s50) {
                        Text(model.t(.welcomeImportWeb)).textStyle(.heading)
                        Text(model.t(.importWebHint)).textStyle(.caption).foregroundStyle(Color.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: T.Space.s100) {
                        KitButton(model.t(.importWeb) + "…", icon: .restore) { model.importWebBackup() }.disabled(model.busy != nil)
                        KitButton(model.t(.importTextFolder) + "…", icon: .folderOpen) { model.importTextFolder() }
                            .disabled(model.busy != nil)
                            .help(model.t(.importTextFolderHint))
                    }
                    .fixedSize()
                }
                .padding(T.Space.s200)
                .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: T.Radius.panel).strokeBorder(Color.lineSubtle))
                Text(model.t(.welcomeStartFresh)).textStyle(.heading).padding(.top, T.Space.s100)
            } else {
                Text(model.t(.newProjectTitle)).textStyle(.title)
            }
            Form {
                TextField(model.t(.projectSettingsName), text: $title, prompt: Text(model.t(.newProjectTitlePlaceholder)))
                    .focused($titleFocused)
                Picker(model.t(.projectSettingsLanguage), selection: $language) {
                    Text(model.t(.languageKo)).tag(ManuscriptLanguage.ko)
                    Text(model.t(.languageEn)).tag(ManuscriptLanguage.en)
                }
                .onChange(of: language) { _, l in resetFolders(l) }
                GoalField(on: $goalOn, count: $goalCount, basis: $goalBasis, language: language)
                LabeledContent(model.t(.newProjectFolders)) {
                    VStack(alignment: .leading, spacing: T.Space.s50) {
                        ForEach(folders.indices, id: \.self) { i in
                            HStack {
                                Toggle("", isOn: $folders[i].on).labelsHidden().toggleStyle(.checkbox)
                                TextField("", text: $folders[i].name).labelsHidden()
                            }
                        }
                        Caption(model.t(.newProjectFoldersHint)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                if !firstRun { KitButton(model.t(.actionCancel), variant: .ghost) { dismiss() }.keyboardShortcut(.cancelAction) }
                KitButton(model.t(.newProjectCreate), variant: .primary, action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || !folders.contains { $0.on && !$0.name.isEmpty })
            }
        }
        .textStyle(.body)
        .padding(T.Space.s300)
        .frame(width: T.Layout.Pane.dialogDefault)
        .background(firstRun ? Color.surfaceSidebar : .surfaceCanvas)
        .interactiveDismissDisabled(firstRun)
        .overlay { if let busy = model.busy { BusyHUD(message: busy) } }
        .onAppear {
            language = model.locale == .ko ? .ko : .en
            resetFolders(language)
            titleFocused = true
        }
    }

    private func resetFolders(_ l: ManuscriptLanguage) {
        folders = [L10nKey.folderDefaultSerial, .folderDefaultLore, .folderDefaultMaterial].map { (true, model.defaultFolderName($0, l)) }
    }

    private func create() {
        let names = folders.filter { $0.on }.map { $0.name.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.createProject(title: title, language: language, folders: names, goal: goalOn ? Goal(count: goalCount, basis: goalBasis) : nil)
    }
}

struct GoalField: View {
    @Environment(AppModel.self) private var model
    @Binding var on: Bool
    @Binding var count: Int
    @Binding var basis: GoalBasis
    let language: ManuscriptLanguage

    var body: some View {
        LabeledContent(model.t(.projectSettingsGoal)) {
            VStack(alignment: .leading, spacing: T.Space.s50) {
                HStack {
                    Toggle("", isOn: $on).labelsHidden().toggleStyle(.checkbox)
                    TextField("", value: $count, format: .number).labelsHidden().frame(width: 90).disabled(!on)
                    Picker("", selection: $basis) {
                        Text(model.t(.goalBasisWithSpaces)).tag(GoalBasis.withSpaces)
                        Text(model.t(.goalBasisWithoutSpaces)).tag(GoalBasis.withoutSpaces)
                        Text(model.t(.goalBasisWords)).tag(GoalBasis.words)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!on)
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
    @State private var language = ManuscriptLanguage.ko
    @State private var goalOn = false
    @State private var goalCount = 5000
    @State private var goalBasis = GoalBasis.withSpaces
    @State private var newFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: T.Space.s200) {
            Text(model.t(.projectSettingsTitle)).textStyle(.title)
            Form {
                TextField(model.t(.projectSettingsName), text: $title)
                Picker(model.t(.projectSettingsLanguage), selection: $language) {
                    Text(model.t(.languageKo)).tag(ManuscriptLanguage.ko)
                    Text(model.t(.languageEn)).tag(ManuscriptLanguage.en)
                }
                Caption(model.t(.projectSettingsLanguageHint))
                GoalField(on: $goalOn, count: $goalCount, basis: $goalBasis, language: language)
                LabeledContent(model.t(.projectSettingsFolders)) {
                    VStack(alignment: .leading, spacing: T.Space.s50) {
                        ForEach(model.folders) { f in FolderEditRow(folder: f) }
                        HStack {
                            TextField("", text: $newFolder, prompt: Text(model.t(.folderNamePlaceholder))).labelsHidden()
                                .onSubmit(addFolder)
                            KitButton(model.t(.folderNew), icon: .add, variant: .ghost, action: addFolder)
                                .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Caption(model.t(.projectSettingsFolderHint))
                    }
                }
            }
            .formStyle(.columns)
            HStack {
                KitButton(model.t(.projectSettingsDelete), icon: .delete, variant: .danger) { model.deleteProject() }
                Spacer()
                KitButton(model.t(.actionCancel), variant: .ghost) { dismiss() }.keyboardShortcut(.cancelAction)
                KitButton(model.t(.actionDone), variant: .primary, action: save).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textStyle(.body)
        .padding(T.Space.s300)
        .frame(width: T.Layout.Pane.dialogDefault)
        .background(Color.surfaceCanvas)
        .onAppear {
            guard let p = model.project else { return }
            title = p.title
            language = p.language
            goalOn = p.goal != nil
            goalCount = p.goal?.count ?? (p.language == .ko ? 5000 : 2000)
            goalBasis = p.goal?.basis ?? (p.language == .ko ? .withSpaces : .words)
        }
    }

    private func addFolder() {
        let n = newFolder.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        model.createFolder(n)
        newFolder = ""
    }

    private func save() {
        model.updateProject(ProjectPatch(title: title.trimmingCharacters(in: .whitespaces), language: language,
                                         goal: .some(goalOn && goalCount > 0 ? Goal(count: goalCount, basis: goalBasis) : nil)))
        model.reloadOutline()
        dismiss()
    }
}

private struct FolderEditRow: View {
    @Environment(AppModel.self) private var model
    let folder: FolderInfo
    @State private var name = ""

    var body: some View {
        HStack {
            TextField("", text: $name).labelsHidden()
                .onSubmit { model.renameFolder(folder.id, name.trimmingCharacters(in: .whitespaces)) }
            Caption(model.t(.sheetListCount, ["count": folder.sheets.count], count: folder.sheets.count))
            IconButton(.delete, label: model.t(.folderDelete)) { model.deleteFolder(folder.id) }
        }
        .onAppear { name = folder.name }
        .onDisappear { if name != folder.name, !name.isEmpty { model.renameFolder(folder.id, name) } }
    }
}
