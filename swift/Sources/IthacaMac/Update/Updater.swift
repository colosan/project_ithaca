// Auto-update via Sparkle 2 + GitHub Releases (ADR-0008).
// Feed, public key and schedule live in swift/Apps/macOS/Info.plist; releases come from tools/mac/release.sh.
//
// Wiring (in the App):
//     @StateObject private var updater = UpdaterViewModel()
//     WindowGroup { … }.commands { UpdateCommands(updater: updater, locale: locale) }
//     Settings → About: Toggle(isOn: $updater.automaticallyChecksForUpdates) · updater.lastCheckText(locale:)
import Combine
import Foundation
import IthacaDesign
import Sparkle
import SwiftUI

/// Owns the one Sparkle updater for the app and mirrors its state for SwiftUI.
@MainActor
public final class UpdaterViewModel: ObservableObject {
    /// Sparkle refuses a check while one is already running.
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var lastUpdateCheckDate: Date?
    /// False when running outside a signed .app (e.g. `swift run`): there is no feed, so the menu item is disabled.
    public let isAvailable: Bool

    private let controller: SPUStandardUpdaterController
    private var bag = Set<AnyCancellable>()

    public init() {
        let info = Bundle.main.infoDictionary ?? [:]
        isAvailable = Bundle.main.bundleURL.pathExtension == "app"
            && info["SUFeedURL"] != nil && info["SUPublicEDKey"] != nil
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        guard isAvailable else { return }
        controller.startUpdater()
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &bag)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastUpdateCheckDate = $0 }
            .store(in: &bag)
    }

    /// Settings → About toggle. Persisted by Sparkle in UserDefaults (SUEnableAutomaticChecks).
    public var automaticallyChecksForUpdates: Bool {
        get { isAvailable && controller.updater.automaticallyChecksForUpdates }
        set {
            guard isAvailable else { return }
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// User-initiated check: Sparkle shows its own progress / "up to date" / update windows.
    public func checkForUpdates() {
        guard isAvailable else { return }
        controller.checkForUpdates(nil)
    }

    /// "Last checked …" / "Not checked yet" line for Settings → About (update.lastChecked / update.neverChecked).
    public func lastCheckText(locale: L10nLocale) -> String {
        guard let date = lastUpdateCheckDate else { return L10n.string(.updateNeverChecked, locale: locale) }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: locale.rawValue))
        return L10n.string(.updateLastChecked, locale: locale, ["date": date.formatted(style)])
    }
}

/// Adds "Check for Updates…" (update.checkMenu) right after "About Ithaca" in the app menu.
public struct UpdateCommands: Commands {
    @ObservedObject var updater: UpdaterViewModel
    let locale: L10nLocale

    public init(updater: UpdaterViewModel, locale: L10nLocale) {
        self.updater = updater
        self.locale = locale
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L10n.string(.updateCheckMenu, locale: locale)) { updater.checkForUpdates() }
                .disabled(!updater.isAvailable || !updater.canCheckForUpdates)
        }
    }
}
