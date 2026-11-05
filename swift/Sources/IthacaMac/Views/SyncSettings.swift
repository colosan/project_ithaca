// Settings → Sync (ADR-0013): a private GitHub repository and a token; then a status line and "sync now".
import AppKit
import IthacaDesign
import SwiftUI

struct SyncSettings: View {
    @Environment(AppModel.self) private var model
    @State private var repoText = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        Form {
            if let sync = model.sync {
                if sync.connected { connected(sync) } else { connect(sync) }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func connect(_ sync: SyncEngine) -> some View {
        Section {
            Text(model.t(.syncGithubIntro)).fixedSize(horizontal: false, vertical: true)
            TextField(model.t(.syncGithubRepo), text: $repoText, prompt: Text(model.t(.syncGithubRepoPlaceholder)))
            SecureField(model.t(.syncGithubToken), text: $token)
            VStack(alignment: .leading, spacing: T.Space.s100) {
                Caption(model.t(.syncGithubTokenHint)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: T.Space.s100) {
                    KitButton(model.t(.syncGithubMakeToken), icon: .externalLink) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    }
                    Spacer(minLength: 0)
                    if connecting { ProgressView().controlSize(.small) }
                    KitButton(model.t(connecting ? .syncGithubConnecting : .syncGithubConnect), variant: .primary) { go(sync) }
                        .disabled(connecting || repoText.isEmpty || token.isEmpty || model.readOnly)
                }
            }
            if let error { errorLine(error) }
        } header: {
            Text(model.t(.syncGithubTitle))
        } footer: {
            Caption(model.t(.syncGithubPlainNote)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func connected(_ sync: SyncEngine) -> some View {
        Section {
            LabeledContent {
                HStack(spacing: T.Space.s100) {
                    if sync.busy { ProgressView().controlSize(.small) }
                    KitButton(model.t(.syncNow), icon: .sync) { Task { await sync.run() } }.disabled(sync.busy)
                }
            } label: {
                VStack(alignment: .leading, spacing: T.Space.s25) {
                    Text(sync.repo?.full ?? "")
                    Caption(status(sync))
                }
            }
            if let e = sync.failure { errorLine(sync.message(e) { model.t($0, $1) }) }
            HStack {
                Spacer(minLength: 0)
                KitButton(model.t(.syncGithubDisconnect), variant: .ghost) {
                    if model.confirm(model.t(.syncGithubDisconnectConfirm)) { sync.disconnect(); repoText = ""; token = "" }
                }
            }
        } header: {
            Text(model.t(.syncGithubTitle))
        } footer: {
            Caption(model.t(.syncGithubPlainNote)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorLine(_ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Icon(.warning, size: T.Size.iconSm) }
            .foregroundStyle(Color.stateDanger)
    }

    private func status(_ sync: SyncEngine) -> String {
        switch sync.phase {
        case .running: model.t(.syncInProgress)
        case .receiving(let done, let total): model.t(.syncGithubReceiving, ["done": done, "total": total])
        case .sending(let done, let total): model.t(.syncGithubSending, ["done": done, "total": total])
        default: sync.lastSync.map(model.syncedAgo) ?? model.t(.syncGithubNever)
        }
    }

    private func go(_ sync: SyncEngine) {
        connecting = true
        error = nil
        Task {
            let e = await sync.connect(repo: repoText, token: token)
            connecting = false
            if let e { error = sync.message(e) { model.t($0, $1) } } else { token = "" }
        }
    }
}

extension AppModel {
    /// "방금 동기화" · "3분 전 동기화" …
    func syncedAgo(_ at: Int64) -> String {
        let minutes = max(0, Int((Int64.nowMillis - at) / 60_000))
        if minutes < 1 { return t(.syncJustNow) }
        if minutes < 60 { return t(.syncMinutesAgo, ["minutes": minutes]) }
        if minutes < 60 * 24 { return t(.syncHoursAgo, ["hours": minutes / 60]) }
        return t(.syncDaysAgo, ["count": minutes / (60 * 24)], count: minutes / (60 * 24))
    }
}
