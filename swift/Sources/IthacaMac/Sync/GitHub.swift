// A private GitHub repository as the shared file store of sync (ADR-0013). Only what sync needs:
// the repository, its branch head, the file listing, file contents, and one commit per batch of changes.
// REST for reads, GraphQL for batched blob reads and for commits (createCommitOnBranch: one call, atomic,
// refused when the branch moved — the caller lists again and retries).
import Foundation

struct GitHubRepo: Equatable, Sendable {
    var owner: String
    var name: String
    var full: String { "\(owner)/\(name)" }

    /// "owner/name", or a github.com URL (with or without .git).
    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "git@"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        for prefix in ["github.com/", "github.com:", "www.github.com/"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasSuffix(".git") { s.removeLast(4) }
        while s.hasSuffix("/") { s.removeLast() }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        let ok: (Substring) -> Bool = { p in !p.isEmpty && p.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } && p.allSatisfy(\.isASCII) }
        guard parts.count == 2, ok(parts[0]), ok(parts[1]) else { return nil }
        owner = String(parts[0]); name = String(parts[1])
    }
}

enum GitHubError: Error, Equatable {
    case badToken, notFound, notPrivate, noWrite, offline, rateLimited
    /// The branch moved since it was listed (another device committed): list again.
    case stale
    case other(String)
}

/// The token is a file only this user can read, beside the library folder (not in it: backups copy the library).
/// Not the keychain: the app is ad-hoc signed, so every update would ask for the keychain password again.
enum GitHubToken {
    /// `--selftest-sync`: the token comes from the environment and is never written.
    private static var injected: String? {
        guard AppEnvironment.isTestLibrary else { return nil }
        return ProcessInfo.processInfo.environment["ITHACA_SYNC_TEST_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var file: URL { AppEnvironment.libraryURL.deletingLastPathComponent().appendingPathComponent("github-token") }

    static func read() -> String? {
        if let injected { return injected }
        guard let d = try? Data(contentsOf: file) else { return nil }
        let t = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    @discardableResult static func write(_ token: String) -> Bool {
        if injected != nil { return true }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Created 0600 before the token goes in, then replaced atomically.
            let tmp = file.deletingLastPathComponent().appendingPathComponent(".github-token-\(getpid())")
            fm.createFile(atPath: tmp.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])
            let h = try FileHandle(forWritingTo: tmp)
            try h.write(contentsOf: Data(token.utf8))
            try h.close()
            if fm.fileExists(atPath: file.path(percentEncoded: false)) {
                _ = try fm.replaceItemAt(file, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: file)
            }
            return true
        } catch {
            return false
        }
    }

    static func delete() {
        if injected != nil { return }
        try? FileManager.default.removeItem(at: file)
    }
}

struct GitHubClient: Sendable {
    let repo: GitHubRepo
    let token: String
    var session: URLSession = .shared
    static let api = URL(string: "https://api.github.com")!

    struct RepoInfo: Sendable { var isPrivate: Bool; var canPush: Bool; var defaultBranch: String }
    /// One file of the listing: its path and its blob id.
    struct Entry: Sendable { var path: String; var sha: String }

    // MARK: Requests

    private func request(_ method: String, _ path: String, json: Any? = nil, etag: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: Self.api.absoluteString + path)!)
        r.httpMethod = method
        r.timeoutInterval = 60
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("Ithaca", forHTTPHeaderField: "User-Agent")
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let json {
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Conditional requests must reach GitHub: a 304 from it is free, a cached 200 from URLCache is stale.
        r.cachePolicy = .reloadIgnoringLocalCacheData
        return r
    }

    private func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: r) } catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
                throw GitHubError.offline
            default: throw GitHubError.other(e.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw GitHubError.other("no HTTP response") }
        switch http.statusCode {
        case 200..<300, 304, 409: return (data, http)
        case 401: throw GitHubError.badToken
        case 403, 429:
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || http.statusCode == 429 || Self.message(data).localizedCaseInsensitiveContains("rate limit") {
                throw GitHubError.rateLimited
            }
            throw GitHubError.noWrite
        case 404: throw GitHubError.notFound
        default: throw GitHubError.other("HTTP \(http.statusCode) \(Self.message(data))")
        }
    }

    private static func message(_ data: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? ""
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubError.other("unexpected reply") }
        return o
    }

    private var base: String { "/repos/\(repo.owner)/\(repo.name)" }

    // MARK: Repository

    func info() async throws -> RepoInfo {
        let (data, _) = try await send(request("GET", base))
        let o = try object(data)
        let perms = o["permissions"] as? [String: Any]
        return RepoInfo(isPrivate: o["private"] as? Bool ?? false, canPush: perms?["push"] as? Bool ?? true,
                        defaultBranch: o["default_branch"] as? String ?? "main")
    }

    enum Head: Sendable, Equatable {
        case commit(String, etag: String?)
        case unchanged
        case empty
    }

    /// The branch's head commit. With the last ETag, `.unchanged` when it hasn't moved (a 304 costs no rate limit).
    func head(_ branch: String, etag: String? = nil) async throws -> Head {
        do {
            let (data, http) = try await send(request("GET", "\(base)/git/ref/heads/\(branch)", etag: etag))
            if http.statusCode == 304 { return .unchanged }
            if http.statusCode == 409 { return .empty }
            let sha = (try object(data)["object"] as? [String: Any])?["sha"] as? String
            guard let sha else { throw GitHubError.other("no head") }
            return .commit(sha, etag: http.value(forHTTPHeaderField: "ETag"))
        } catch GitHubError.notFound {
            // A repository without commits has no branch yet.
            return .empty
        }
    }

    /// A first commit, so the branch exists (createCommitOnBranch needs one).
    func initialize(_ branch: String) async throws -> String {
        let readme = "# Ithaca\n\nIthaca 원고 동기화 저장소예요. 앱이 관리하니 직접 고치지 마세요.\n"
        let body: [String: Any] = ["message": "Ithaca 동기화 시작", "content": Data(readme.utf8).base64EncodedString(), "branch": branch]
        let (data, http) = try await send(request("PUT", "\(base)/contents/README.md", json: body))
        if http.statusCode == 409 { throw GitHubError.stale }
        guard let sha = (try object(data)["commit"] as? [String: Any])?["sha"] as? String else { throw GitHubError.other("no commit") }
        return sha
    }

    /// Every file of a commit. A listing too big for one reply is walked folder by folder.
    func files(_ commit: String) async throws -> [Entry] {
        try await list(commit, prefix: "")
    }

    private func list(_ tree: String, prefix: String) async throws -> [Entry] {
        let (data, _) = try await send(request("GET", "\(base)/git/trees/\(tree)?recursive=1"))
        let o = try object(data)
        let items = o["tree"] as? [[String: Any]] ?? []
        if o["truncated"] as? Bool != true {
            return items.compactMap { i in
                guard i["type"] as? String == "blob", let p = i["path"] as? String, let s = i["sha"] as? String else { return nil }
                return Entry(path: prefix + p, sha: s)
            }
        }
        let (flat, _) = try await send(request("GET", "\(base)/git/trees/\(tree)"))
        var out: [Entry] = []
        for i in try object(flat)["tree"] as? [[String: Any]] ?? [] {
            guard let p = i["path"] as? String, let s = i["sha"] as? String else { continue }
            if i["type"] as? String == "tree" { out += try await list(s, prefix: prefix + p + "/") }
            else if i["type"] as? String == "blob" { out.append(Entry(path: prefix + p, sha: s)) }
        }
        return out
    }

    // MARK: Contents

    /// Blob contents by id, 100 per GraphQL call.
    func blobs(_ shas: [String], progress: @Sendable (Int) async -> Void = { _ in }) async throws -> [String: Data] {
        var out: [String: Data] = [:]
        var done = 0
        for chunk in stride(from: 0, to: shas.count, by: 100).map({ Array(shas[$0..<min($0 + 100, shas.count)]) }) {
            let fields = chunk.enumerated().map { i, sha in "b\(i): object(oid: \"\(sha)\") { ... on Blob { text isTruncated isBinary } }" }
            let query = "query { repository(owner: \"\(repo.owner)\", name: \"\(repo.name)\") { \(fields.joined(separator: " ")) } }"
            let o = try await graphQL(query, variables: [:])
            let r = (o["repository"] as? [String: Any]) ?? [:]
            for (i, sha) in chunk.enumerated() {
                if let b = r["b\(i)"] as? [String: Any], let text = b["text"] as? String, b["isTruncated"] as? Bool != true, b["isBinary"] as? Bool != true {
                    out[sha] = Data(text.utf8)
                } else {
                    out[sha] = try await blob(sha)
                }
            }
            done += chunk.count
            await progress(done)
        }
        return out
    }

    private func blob(_ sha: String) async throws -> Data {
        let (data, _) = try await send(request("GET", "\(base)/git/blobs/\(sha)"))
        let o = try object(data)
        guard let c = o["content"] as? String, let d = Data(base64Encoded: c, options: .ignoreUnknownCharacters) else { throw GitHubError.other("blob \(sha)") }
        return d
    }

    /// One commit with these files added and those deleted, on top of `expected`. Returns the new head.
    func commit(_ branch: String, expected: String, add: [(String, Data)], delete: [String], message: String) async throws -> String {
        let input: [String: Any] = [
            "branch": ["repositoryNameWithOwner": repo.full, "branchName": branch],
            "message": ["headline": message],
            "expectedHeadOid": expected,
            "fileChanges": ["additions": add.map { ["path": $0.0, "contents": $0.1.base64EncodedString()] },
                            "deletions": delete.map { ["path": $0] }],
        ]
        let q = "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }"
        let o = try await graphQL(q, variables: ["input": input])
        guard let oid = ((o["createCommitOnBranch"] as? [String: Any])?["commit"] as? [String: Any])?["oid"] as? String else {
            throw GitHubError.other("no commit")
        }
        return oid
    }

    private func graphQL(_ query: String, variables: [String: Any]) async throws -> [String: Any] {
        let (data, _) = try await send(request("POST", "/graphql", json: ["query": query, "variables": variables]))
        let o = try object(data)
        if let errors = o["errors"] as? [[String: Any]], !errors.isEmpty {
            let text = errors.map { ($0["type"] as? String ?? "") + " " + ($0["message"] as? String ?? "") }.joined(separator: "; ")
            if text.localizedCaseInsensitiveContains("expected") || text.contains("STALE_DATA") { throw GitHubError.stale }
            if text.contains("RATE_LIMITED") { throw GitHubError.rateLimited }
            if text.contains("FORBIDDEN") || text.localizedCaseInsensitiveContains("not accessible") { throw GitHubError.noWrite }
            if text.contains("NOT_FOUND") { throw GitHubError.notFound }
            throw GitHubError.other(text)
        }
        return o["data"] as? [String: Any] ?? [:]
    }
}
