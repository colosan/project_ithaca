// `Ithaca --selftest-sync`: two libraries ("mac" and "phone") kept in step through a real private GitHub repository.
// Needs ITHACA_LIBRARY_PATH (the two libraries go in its a/ and b/), ITHACA_SYNC_TEST_REPO (owner/name, emptied
// first: use a repository for this only) and ITHACA_SYNC_TEST_TOKEN (never written anywhere).
import AppKit
import Foundation

@MainActor
enum SyncSelfTest {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard AppEnvironment.libraryOverride != nil, let repoText = env["ITHACA_SYNC_TEST_REPO"], let repo = GitHubRepo(repoText),
              let token = env["ITHACA_SYNC_TEST_TOKEN"], !token.isEmpty else {
            print("✗ needs ITHACA_LIBRARY_PATH, ITHACA_SYNC_TEST_REPO and ITHACA_SYNC_TEST_TOKEN"); exit(2)
        }
        Task { @MainActor in exit(await body(repo: repo, token: token) ? 0 : 1) }
        RunLoop.main.run()
    }

    private static func body(repo: GitHubRepo, token: String) async -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "  ✓ " : "  ✗ ") + what); if !ok { failures += 1 } }
        let root = AppEnvironment.libraryURL
        try? FileManager.default.removeItem(at: root)
        func open(_ name: String) -> (CoreLibrary, SyncEngine)? {
            let suite = "io.github.colosan.ithaca.test.sync.\(name)"
            UserDefaults().removePersistentDomain(forName: suite)
            guard let lib = try? CoreLibrary(path: root.appendingPathComponent(name).path(percentEncoded: false), deviceId: "selftest-\(name)"),
                  let defaults = UserDefaults(suiteName: suite) else { return nil }
            return (lib, SyncEngine(library: lib, defaults: defaults))
        }
        guard let (a, syncA) = open("a"), let (b, syncB) = open("b") else { print("✗ open"); return false }

        // An empty branch to start from (earlier runs' files go).
        let client = GitHubClient(repo: repo, token: token)
        do {
            if case .commit(let head, _) = try await client.head(try await client.info().defaultBranch) {
                let old = try await client.files(head).map(\.path).filter { $0.hasPrefix("projects/") }
                if !old.isEmpty {
                    _ = try await client.commit(try await client.info().defaultBranch, expected: head, add: [], delete: old, message: "selftest reset")
                }
                print("reset: removed \(old.count) files")
            }
        } catch { print("✗ reset: \(error)"); return false }

        func ok(_ s: SyncEngine, _ what: String) -> Bool {
            if let e = s.failure { print("    \(what): \(e)") }
            return s.failure == nil
        }

        // 1. Connect the mac: its project goes up.
        let p = try! a.createProject(title: "동기화 시험", language: .ko, folders: ["연재"])
        let folder = try! a.outline(project: p.id).folders[0].id
        let sheet = try! a.outline(project: p.id).folders[0].sheets[0].id
        try! a.saveSheet(project: p.id, sheet: sheet, text: "# 1화\n\n맥에서 쓴 첫 문장.")
        let e1 = await syncA.connect(repo: repo.full, token: token)
        check(e1 == nil && ok(syncA, "a"), "mac connects and sends (\(String(describing: e1)))")

        // 2. The phone connects: the project comes down.
        let e2 = await syncB.connect(repo: repo.full, token: token)
        check(e2 == nil && ok(syncB, "b"), "phone connects (\(String(describing: e2)))")
        check((try? b.sheetText(project: p.id, sheet: sheet)) == "# 1화\n\n맥에서 쓴 첫 문장.", "phone has the mac's sheet")

        // 3. An edit on the phone reaches the mac.
        try! b.saveSheet(project: p.id, sheet: sheet, text: "# 1화\n\n맥에서 쓴 첫 문장. 폰에서 이어 씀.")
        await syncB.run()
        var applied: SyncIngestResult?
        syncA.didIngest = { applied = $0 }
        await syncA.run()
        check(ok(syncA, "a") && (try? a.sheetText(project: p.id, sheet: sheet)) == "# 1화\n\n맥에서 쓴 첫 문장. 폰에서 이어 씀.", "mac gets the phone's edit")
        check(applied?.changed.contains { $0.project == p.id && $0.sheet == sheet } == true, "the change is reported for the open sheet")
        check((try? a.outline(project: p.id).folders[0].sheets.first { $0.id == sheet }?.branched) == false, "no fork")

        // 4. Both add a sheet apart: both keep both.
        let onA = try! a.createSheet(project: p.id, folder: folder, text: "# 맥에서 만든 시트").id
        let onB = try! b.createSheet(project: p.id, folder: folder, text: "# 폰에서 만든 시트").id
        await syncA.run(); await syncB.run(); await syncA.run()
        for (name, lib) in [("mac", a), ("phone", b)] {
            let ids = (try? lib.outline(project: p.id).folders[0].sheets.map(\.id)) ?? []
            check(ids.contains(onA) && ids.contains(onB), "\(name) has both new sheets (\(ids.count))")
        }
        check((try? a.outline(project: p.id)) == (try? b.outline(project: p.id)), "both outlines are the same")

        // 5. A sheet deleted for good on the mac goes everywhere.
        try! a.trashSheet(project: p.id, sheet: onA)
        try! a.deleteSheetForever(project: p.id, sheet: onA)
        await syncA.run(); await syncB.run()
        check((try? b.outline(project: p.id).folders[0].sheets.contains { $0.id == onA }) == false, "the deleted sheet is gone on the phone")
        if case .commit(let head, _) = try? await client.head(client.info().defaultBranch) {
            let paths = (try? await client.files(head).map(\.path)) ?? []
            check(!paths.contains { $0.contains(onA) }, "and from the repository")
            check(paths.filter { $0.hasPrefix("projects/") }.count == (await a.syncPlan(remote: [], base: []).upload.count), "repository = the mac's files")
        }

        // 6. Nothing to do: a run sends and receives nothing.
        await syncA.run()
        check(ok(syncA, "a") && syncA.phase == .idle, "idle after a run with nothing new")

        print(failures == 0 ? "✓ sync self-test passed" : "✗ sync self-test: \(failures) failed")
        return failures == 0
    }
}
