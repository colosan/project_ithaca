// Settings window (design/screens/preferences): General · Editor · Backup · Claude · About.
// Sync and Shortcuts editing are hidden until they work; Claude is read-only (no write permission yet).
import AppKit
import IthacaCore
import IthacaDesign
import SwiftUI

enum SettingsSection: String { case general, editor, backup, claude, about }

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var updater: UpdaterViewModel
    @AppStorage("ithaca.settingsTab") private var tab = SettingsSection.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label { Text(model.t(.prefsGeneral)) } icon: { Image(lucide: .settings) } }.tag(SettingsSection.general)
            EditorSettings().tabItem { Label { Text(model.t(.prefsEditor)) } icon: { Image(lucide: .editorText) } }.tag(SettingsSection.editor)
            BackupSettings().tabItem { Label { Text(model.t(.prefsBackup)) } icon: { Image(lucide: .backup) } }.tag(SettingsSection.backup)
            ClaudeSettings().tabItem { Label { Text(model.t(.prefsClaude)) } icon: { Image(lucide: .claude) } }.tag(SettingsSection.claude)
            AboutSettings(updater: updater).tabItem { Label { Text(model.t(.prefsAbout)) } icon: { Image(lucide: .info) } }.tag(SettingsSection.about)
        }
        .frame(width: T.Layout.Pane.dialogDefault + T.Space.s800)
        .textStyle(.body)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        Form {
            // Language names in their own language (spec), switched instantly (ADR-0005).
            Picker(model.t(.prefsUiLanguage), selection: $m.localePref) {
                Text(model.t(.prefsLanguageSystem)).tag(LocalePref.system)
                Text(model.t(.uiLanguageKo)).tag(LocalePref.ko)
                Text(model.t(.uiLanguageEn)).tag(LocalePref.en)
            }
            Picker(model.t(.prefsTheme), selection: $m.theme) {
                Text(model.t(.themeSystem)).tag(ThemePref.system)
                Text(model.t(.themeLight)).tag(ThemePref.light)
                Text(model.t(.themeDark)).tag(ThemePref.dark)
            }
            .pickerStyle(.segmented)
            Toggle(model.t(.prefsConfirmDelete), isOn: $m.confirmDelete)
            LabeledContent(model.t(.prefsTrash)) { Text(model.t(.trashHint)).foregroundStyle(Color.inkSecondary) }
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        Form {
            Picker(model.t(.prefsEditorTextSize), selection: $m.textSize) {
                Text(model.t(.prefsEditorSmall)).tag(TextSize.small)
                Text(model.t(.prefsEditorNormal)).tag(TextSize.normal)
                Text(model.t(.prefsEditorLarge)).tag(TextSize.large)
            }
            .pickerStyle(.segmented)
            Picker(selection: $m.markup) {
                Text(model.t(.prefsEditorMarkupShow)).tag(MarkupMode.show)
                Text(model.t(.prefsEditorMarkupDim)).tag(MarkupMode.dim)
                Text(model.t(.prefsEditorMarkupHide)).tag(MarkupMode.hide)
            } label: { labeled(.prefsEditorMarkup, .prefsEditorMarkupHint) }
            .pickerStyle(.segmented)
            Picker(selection: $m.focusScope) {
                Text(model.t(.prefsEditorFocusSentence)).tag(FocusScope.sentence)
                Text(model.t(.prefsEditorFocusParagraph)).tag(FocusScope.paragraph)
            } label: { labeled(.prefsEditorFocusScope, .prefsEditorFocusScopeHint) }
            .pickerStyle(.segmented)
            Toggle(isOn: $m.typewriter) { labeled(.prefsEditorTypewriter, .prefsEditorTypewriterHint) }
            Toggle(isOn: Binding(get: { model.spellCheckActive }, set: { model.spellCheck = $0 })) {
                labeled(.prefsEditorSpell, .prefsEditorSpellAutoHint)
            }
        }
        .formStyle(.grouped)
    }

    private func labeled(_ title: L10nKey, _ hint: L10nKey) -> some View {
        VStack(alignment: .leading, spacing: T.Space.s25) {
            Text(model.t(title))
            Caption(model.t(hint))
        }
    }
}

private struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    @State private var list: [BackupInfo] = []
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent(model.t(.backupLibraryFolder)) {
                    VStack(alignment: .trailing, spacing: T.Space.s50) {
                        Text(model.info.inMemory ? model.t(.libraryInMemory) : AppEnvironment.libraryURL.path(percentEncoded: false))
                            .textStyle(.caption).foregroundStyle(Color.inkSecondary).textSelection(.enabled).multilineTextAlignment(.trailing)
                        KitButton(model.t(.backupReveal), icon: .folderOpen) {
                            NSWorkspace.shared.activateFileViewerSelecting([AppEnvironment.libraryURL])
                        }
                        .disabled(model.info.inMemory)
                    }
                }
            }
            if !model.info.problems.isEmpty {
                Section(model.t(.libraryProblemsTitle)) {
                    ForEach(Array(model.info.problems.enumerated()), id: \.offset) { _, p in
                        Label { Text(p).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: { Icon(.warning, size: T.Size.iconSm) }
                            .foregroundStyle(Color.stateWarning)
                    }
                }
            }
            Section {
                LabeledContent {
                    HStack {
                        if working { ProgressView().controlSize(.small) }
                        KitButton(model.t(.backupNow), icon: .backup, variant: .primary, action: backupNow).disabled(working || model.info.inMemory || model.readOnly)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: T.Space.s25) {
                        Text(model.t(.backupAuto))
                        Caption(model.t(.backupAutoDaily)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent(model.t(.backupLocation)) {
                    KitButton(model.t(.backupReveal), icon: .folderOpen) {
                        let dir = URL(fileURLWithPath: model.library.backupsDir(), isDirectory: true)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    .disabled(model.info.inMemory)
                }
            }
            Section(model.t(.backupRecent)) {
                if list.isEmpty { Caption(model.t(.backupNone)) }
                ForEach(list.prefix(12)) { b in
                    LabeledContent {
                        KitButton(model.t(.backupRestoreCopies), icon: .restore, variant: .ghost) { restore(b) }.disabled(model.readOnly || model.busy != nil)
                    } label: {
                        VStack(alignment: .leading, spacing: T.Space.s25) {
                            Text(b.at.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: model.locale.rawValue))))
                            Caption(kind(b.kind) + " · " + model.t(.backupMetaProjects, ["size": ByteCountFormatter.string(fromByteCount: Int64(b.bytes), countStyle: .file), "count": b.projects], count: b.projects))
                        }
                    }
                }
                Caption(model.t(.backupRestoreHint)).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent {
                    KitButton(model.t(.importWeb) + "…", icon: .restore) { model.importWebBackup() }.disabled(model.busy != nil)
                } label: {
                    VStack(alignment: .leading, spacing: T.Space.s25) {
                        Text(model.t(.importWeb))
                        Caption(model.t(.importWebHint)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let busy = model.busy {
                HStack(spacing: T.Space.s100) { ProgressView().controlSize(.small); Text(busy) }
            } else if let message { Text(message).foregroundStyle(Color.stateSuccess).fixedSize(horizontal: false, vertical: true) }
        }
        .formStyle(.grouped)
        .onAppear { list = model.library.backups() }
    }

    private func kind(_ k: BackupKind) -> String {
        switch k {
        case .auto: model.t(.backupKindAuto)
        case .manual: model.t(.backupKindManual)
        case .preMigration: model.t(.backupKindPreMigration)
        }
    }

    private func backupNow() {
        model.flushSave()
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                _ = try await model.library.backupManual()
                message = model.t(.backupDone)
            } catch { message = model.t(.backupFailed, ["message": error.localizedDescription]) }
            list = model.library.backups()
        }
    }

    /// Never overwrites: the backup's projects come back as new projects (PRODUCT.md).
    private func restore(_ b: BackupInfo) {
        message = nil
        model.restoreBackupAsCopies(b) { message = $0 }
    }
}

/// Claude (MCP), read only: the bundled ithaca-mcp shows Claude Desktop the checked projects.
/// Settings live in the library (setMcpSettings) so the separate ithaca-mcp process reads the same ones.
private struct ClaudeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var settings = McpSettings()
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { settings.enabled }, set: { settings.enabled = $0; save() })) {
                    VStack(alignment: .leading, spacing: T.Space.s25) {
                        Text(model.t(.mcpReadToggle))
                        Caption(model.t(.mcpReadOnlyHint)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(model.readOnly)
            }
            if settings.enabled {
                Section {
                    if model.projects.isEmpty { Caption(model.t(.mcpNoProjects)) }
                    ForEach(model.projects) { p in
                        Toggle(p.title, isOn: Binding(get: { settings.projects.contains(p.id) }, set: { on in
                            settings.projects.removeAll { $0 == p.id }
                            if on { settings.projects.append(p.id) }
                            save()
                        }))
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    Text(model.t(.mcpProjects))
                } footer: {
                    Caption(model.t(.mcpProjectsHint))
                }
                Section {
                    Text(Self.config)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        KitButton(copied ? model.t(.mcpCopied) : model.t(.mcpCopy), icon: copied ? .check : .copy) { copy() }
                        Spacer(minLength: 0)
                    }
                    Caption(model.t(.mcpPasteHint)).fixedSize(horizontal: false, vertical: true)
                    Caption(model.t(.mcpMoveHint)).fixedSize(horizontal: false, vertical: true)
                    if !FileManager.default.isExecutableFile(atPath: Self.serverPath) {
                        Label { Text(model.t(.mcpMissingBinary)).fixedSize(horizontal: false, vertical: true) } icon: { Icon(.warning, size: T.Size.iconSm) }
                            .textStyle(.caption)
                            .foregroundStyle(Color.stateWarning)
                    }
                } header: {
                    Text(model.t(.mcpConfigTitle))
                }
            }
            if let error { Text(error).foregroundStyle(Color.stateDanger).fixedSize(horizontal: false, vertical: true) }
        }
        .formStyle(.grouped)
        .onAppear { settings = model.library.mcpSettings() }
    }

    /// The running bundle's server, so the pasted config points at this copy of the app.
    static var serverPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ithaca-mcp").path }

    static var config: String {
        let root: [String: Any] = ["mcpServers": ["ithaca": ["command": serverPath]]]
        guard let d = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    private func copy() {
        // Plain text only (research §6-7).
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.config, forType: .string)
        copied = true
        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); copied = false }
    }

    private func save() {
        // Only live projects, in library order.
        let live = Set(model.projects.map(\.id))
        settings.projects = model.projects.map(\.id).filter { settings.projects.contains($0) && live.contains($0) }
        do { settings = try model.library.setMcpSettings(settings); error = nil } catch {
            self.error = error.localizedDescription
            settings = model.library.mcpSettings()
        }
    }
}

private struct AboutSettings: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent(model.t(.appName)) {
                    Text(model.t(.aboutVersion, ["version": AppEnvironment.version, "channel": "pre-alpha", "build": AppEnvironment.build]))
                }
                LabeledContent(model.t(.aboutCore)) { Text("\(model.info.coreVersion) · format \(model.info.format)") }
            }
            if updater.isAvailable {
                Section {
                    Toggle(model.t(.updateAutoCheck), isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: { updater.automaticallyChecksForUpdates = $0 }))
                    LabeledContent(updater.lastCheckText(locale: model.locale)) {
                        KitButton(model.t(.aboutCheckUpdate), icon: .sync) { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                    }
                }
            }
            Section {
                LabeledContent(model.t(.aboutLicense)) { Text("MIT OR Apache-2.0") }
                LabeledContent(model.t(.aboutSource)) { Link("github.com/colosan/project_ithaca", destination: URL(string: "https://github.com/colosan/project_ithaca")!) }
                Text(model.t(.aboutLocalFirst)).textStyle(.caption).foregroundStyle(Color.inkSecondary)
            }
        }
        .formStyle(.grouped)
    }
}
