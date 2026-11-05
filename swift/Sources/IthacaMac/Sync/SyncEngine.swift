// Keeps the library in step with a private GitHub repository (ADR-0013). The core plans and takes files in
// (core/API.md §Sync); this moves them. One run: list the branch, fetch what's missing here, send what's
// missing there, prune what was deleted for good, remember the listing as the next run's base.
// Runs when the branch moved (checked every 15 s while the app is active, 60 s otherwise — a 304 is free)
// or when something was saved here (a few seconds after the save).
import AppKit
import Foundation
import IthacaDesign

@MainActor
@Observable
final class SyncEngine {
    enum Phase: Equatable {
        case off, idle, running
        case receiving(done: Int, total: Int)
        case sending(done: Int, total: Int)
        case failed(GitHubError)
    }

    private(set) var repo: GitHubRepo?
    private(set) var phase: Phase = .off
    private(set) var lastSync: Int64?

    @ObservationIgnored private let library: SyncableLibrary
    @ObservationIgnored private let defaults: UserDefaults
    /// Applies what a run brought in to the open project and sheet.
    @ObservationIgnored var didIngest: (SyncIngestResult) -> Void = { _ in }
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var nudgeTask: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var lastRunStart: Int64 = 0
    /// The listing after the last run: what both sides had then.
    @ObservationIgnored private var lastListing: [String] = []

    private enum Key {
        static let repo = "ithaca.sync.github.repo"
        static let branch = "ithaca.sync.github.branch"
        static let base = "ithaca.sync.github.base"
        static let last = "ithaca.sync.github.last"
    }

    private var branch: String { defaults.string(forKey: Key.branch) ?? "main" }
    /// The commit whose files are the base of the next run (nil before the first).
    private var base: String? {
        get { defaults.string(forKey: Key.base) }
        set { defaults.set(newValue, forKey: Key.base) }
    }

    init(library: SyncableLibrary, defaults: UserDefaults) {
        self.library = library
        self.defaults = defaults
        repo = defaults.string(forKey: Key.repo).flatMap(GitHubRepo.init)
        lastSync = (defaults.object(forKey: Key.last) as? NSNumber)?.int64Value
        if repo != nil { phase = .idle }
    }

    var connected: Bool { repo != nil }
    var busy: Bool { switch phase { case .running, .receiving, .sending: true; default: false } }
    var failure: GitHubError? { if case .failed(let e) = phase { e } else { nil } }

    private func client() -> GitHubClient? {
        guard let repo else { return nil }
        if token == nil { token = GitHubToken.read() }
        return token.map { GitHubClient(repo: repo, token: $0) }
    }

    // MARK: Connecting

    /// Checks the repository with the token, keeps both, and runs the first sync. Returns the problem, if any.
    func connect(repo text: String, token: String) async -> GitHubError? {
        guard let repo = GitHubRepo(text) else { return .other("repo") }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = GitHubClient(repo: repo, token: token)
        do {
            let info = try await c.info()
            guard info.isPrivate else { return .notPrivate }
            guard info.canPush else { return .noWrite }
            guard GitHubToken.write(token) else { return .other("token file") }
            if self.repo != repo { base = nil }
            self.repo = repo
            self.token = token
            etag = nil
            defaults.set(repo.full, forKey: Key.repo)
            defaults.set(info.defaultBranch, forKey: Key.branch)
            phase = .idle
            start()
            await run()
            return failure
        } catch let e as GitHubError {
            return e
        } catch {
            return .other(error.localizedDescription)
        }
    }

    /// Snapshots: looks connected, never runs.
    func preview(_ repo: GitHubRepo, lastSync: Int64) {
        self.repo = repo
        self.lastSync = lastSync
        phase = .idle
    }

    func disconnect() {
        loop?.cancel(); loop = nil
        nudgeTask?.cancel()
        GitHubToken.delete()
        for k in [Key.repo, Key.branch, Key.base, Key.last] { defaults.removeObject(forKey: k) }
        repo = nil; token = nil; etag = nil; lastSync = nil; lastListing = []
        phase = .off
    }

    // MARK: Scheduling

    func start() {
        guard repo != nil else { return }
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let pause: Double = NSApp?.isActive == true ? 15 : 60
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    /// Something was saved here: send it soon (coalesced while typing). At most one run per 30 s from saves:
    /// GitHub allows about 500 commits an hour, and a long writing session saves every few seconds.
    func nudge() {
        guard repo != nil else { return }
        nudgeTask?.cancel()
        let since = Double(Int64.nowMillis - lastRunStart) / 1000
        let delay = max(4, 30 - since)
        nudgeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    /// A cheap check: run only when the branch moved or this library has something the last listing hasn't.
    private func tick() async {
        guard let c = client(), !running else { return }
        if case .failed(.badToken) = phase { return }
        var moved = true
        if let etag, !lastListing.isEmpty, let h = try? await c.head(branch, etag: etag) { moved = h != .unchanged }
        if !moved {
            let p = await library.syncPlan(remote: lastListing, base: lastListing)
            if p.upload.isEmpty && p.deleteRemote.isEmpty { return }
            // Saves here are sent by `nudge`, at its pace.
            if Int64.nowMillis - lastRunStart < 30_000 { return }
        }
        await run()
    }

    // MARK: Running

    func run() async {
        guard let c = client() else {
            if repo != nil { phase = .failed(.badToken) }
            return
        }
        guard !running else { return }
        running = true
        lastRunStart = .nowMillis
        defer { running = false }
        phase = .running
        for _ in 0..<4 {
            do {
                try await once(c)
                lastSync = .nowMillis
                defaults.set(NSNumber(value: lastSync!), forKey: Key.last)
                phase = .idle
                return
            } catch GitHubError.stale {
                // Another device committed in between: list again.
                continue
            } catch let e as GitHubError {
                phase = .failed(e)
                return
            } catch {
                phase = .failed(.other((error as? LibraryError)?.detail ?? error.localizedDescription))
                return
            }
        }
        phase = .failed(.other("the branch kept moving"))
    }

    private func once(_ c: GitHubClient) async throws {
        var head: String
        switch try await c.head(branch) {
        case .commit(let sha, _): head = sha
        case .empty, .unchanged: head = try await c.initialize(branch)
        }
        let remote = try await c.files(head)
        let listing = remote.map(\.path)
        let baseListing: [String]
        if let base, base == head { baseListing = listing }
        else if let base { baseListing = ((try? await c.files(base)) ?? []).map(\.path) }
        else { baseListing = [] }
        var plan = await library.syncPlan(remote: listing, base: baseListing)

        if !plan.download.isEmpty {
            let sha = Dictionary(remote.map { ($0.path, $0.sha) }, uniquingKeysWith: { a, _ in a })
            let total = plan.download.count
            phase = .receiving(done: 0, total: total)
            let wanted = plan.download.compactMap { sha[$0] }
            let blobs = try await c.blobs(wanted) { [weak self] done in await MainActor.run { self?.phase = .receiving(done: done, total: total) } }
            let files = plan.download.compactMap { p in sha[p].flatMap { blobs[$0] }.map { (p, $0) } }
            let result = try await library.syncIngest(files)
            didIngest(result)
            // A merge written while taking the files in goes up too.
            plan = await library.syncPlan(remote: listing, base: baseListing)
        }

        let deletes = Set(plan.deleteRemote)
        if !plan.upload.isEmpty || !deletes.isEmpty {
            let total = plan.upload.count
            phase = .sending(done: 0, total: total)
            var done = 0
            var pendingDeletes = Array(deletes)
            // Batches small enough for one request; the deletions ride with the first.
            for batch in Self.batches(plan.upload) + (plan.upload.isEmpty ? [[]] : []) {
                let files = try await library.syncRead(batch)
                head = try await c.commit(branch, expected: head, add: files, delete: pendingDeletes,
                                          message: "\(AppEnvironment.deviceName) · 원고 조각 \(files.count)개" + (pendingDeletes.isEmpty ? "" : " · 지운 \(pendingDeletes.count)개"))
                pendingDeletes = []
                done += batch.count
                phase = .sending(done: done, total: total)
            }
        }
        base = head
        lastListing = Array(Set(listing).union(plan.upload).subtracting(deletes)).sorted()
        if case .commit(_, let tag) = try await c.head(branch) { etag = tag }
    }

    /// Up to 300 files per commit (block files are small: a few KB, a snapshot at most a sheet).
    private static func batches(_ paths: [String]) -> [[String]] {
        stride(from: 0, to: paths.count, by: 300).map { Array(paths[$0..<min($0 + 300, paths.count)]) }
    }

    // MARK: Words

    func message(_ e: GitHubError, _ t: (L10nKey, [String: Any]) -> String) -> String {
        switch e {
        case .badToken: t(.syncErrorBadToken, [:])
        case .notFound: t(.syncErrorNotFound, [:])
        case .notPrivate: t(.syncErrorPublic, [:])
        case .noWrite: t(.syncErrorNoWrite, [:])
        case .offline: t(.syncErrorOffline, [:])
        case .rateLimited: t(.syncErrorRateLimit, [:])
        case .stale: t(.syncErrorOther, ["message": "branch moved"])
        case .other("repo"): t(.syncErrorBadRepo, [:])
        case .other(let m): t(.syncErrorOther, ["message": m])
        }
    }
}
