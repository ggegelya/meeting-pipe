import Combine
import Foundation

/// One row in the Notion DB picker: 32-char DB id + human-readable title, sorted alphabetically.
struct NotionDatabaseEntry: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let title: String
}

/// Fetches and caches the user's Notion databases for the per-workflow DB picker (TECH-B8).
/// Cache at `~/Library/Caches/MeetingPipe/notion-databases.json`; never auto-expires (Notion DBs are stable and a stale list is less bad than a surprise API call on settings-tab open). Refresh is explicit.
/// Threading: `@MainActor`; the URLSession callback posts back to main before mutating published state.
@MainActor
final class NotionDatabaseList: ObservableObject {

    enum FetchState: Equatable {
        case idle
        case loading
        case loaded([NotionDatabaseEntry])
        case failed(String)
    }

    @Published private(set) var entries: [NotionDatabaseEntry] = []
    @Published private(set) var state: FetchState = .idle

    private let cacheURL: URL
    private let session: URLSession
    /// Resolves the global regulated-mode flag. Defaults to reading the config
    /// file at refresh time; tests inject a constant. (TECH-SEC4)
    private let isRegulated: () -> Bool

    init(
        cacheURL: URL = NotionDatabaseList.defaultCacheURL,
        session: URLSession = .shared,
        isRegulated: @escaping () -> Bool = { (try? Config.load())?.modes.regulatedMode ?? false }
    ) {
        self.cacheURL = cacheURL
        self.session = session
        self.isRegulated = isRegulated
        loadCache()
    }

    nonisolated static let defaultCacheURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MeetingPipe/notion-databases.json")
    }()

    /// Re-fetch from Notion using the token in the process environment. Preferences "Apply" keeps the env in sync with `secrets.env`, so no need to reach into SecretsStore.
    ///
    /// Gated on global regulated mode (TECH-SEC4): the daemon's own POST to
    /// api.notion.com is outside the pipeline's egress firewall, so under
    /// regulated mode we refuse the network call and fall back to the cached
    /// list / paste path. Every fetch attempt, allowed or blocked, emits an
    /// event-log line so daemon-originated egress is auditable. (NDA is a
    /// per-meeting/workflow flag, not a global daemon state; the DB picker is a
    /// global Preferences action, so the network gate keys off regulated mode.
    /// The editor disables this control for an NDA workflow at the call site.)
    func refresh() {
        if isRegulated() {
            Log.event(category: "daemon", action: "notion_fetch_blocked",
                      attributes: ["host": "api.notion.com", "reason": "regulated_mode"])
            state = .failed("Regulated mode is on: the database list is not fetched over the network. Pick from the cached list or paste a database id.")
            return
        }
        let token = ProcessInfo.processInfo.environment["NOTION_TOKEN"] ?? ""
        guard !token.isEmpty else {
            state = .failed("Set NOTION_TOKEN in Preferences -> Integrations first.")
            return
        }
        Log.event(category: "daemon", action: "notion_fetch_started",
                  attributes: ["host": "api.notion.com"])
        state = .loading
        Task {
            do {
                let fetched = try await Self.fetch(token: token, session: session)
                self.entries = fetched
                self.state = .loaded(fetched)
                self.persistCache(fetched)
                Log.event(category: "daemon", action: "notion_fetch_completed",
                          attributes: ["host": "api.notion.com", "count": fetched.count])
            } catch {
                self.state = .failed(error.localizedDescription)
                Log.event(category: "daemon", action: "notion_fetch_failed",
                          attributes: ["host": "api.notion.com", "error": error.localizedDescription])
            }
        }
    }

    /// True when no databases are loaded yet; picker falls back to a raw text field.
    var isEmpty: Bool { entries.isEmpty }

    // MARK: - Persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([NotionDatabaseEntry].self, from: data) else {
            return
        }
        entries = decoded
        if !decoded.isEmpty {
            state = .loaded(decoded)
        }
    }

    private func persistCache(_ list: [NotionDatabaseEntry]) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: - HTTP

    /// Fetch the DB list. Uses the same `/v1/search` filter as `mp doctor` so a successful fetch implies the token is valid.
    static func fetch(
        token: String,
        session: URLSession = .shared
    ) async throws -> [NotionDatabaseEntry] {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/search")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "filter": ["value": "database", "property": "object"],
            "page_size": 100,
        ])
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "NotionDatabaseList", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Notion API returned \(http.statusCode): \(body.prefix(200))"]
            )
        }
        return parse(jsonData: data)
    }

    /// Read-only reachability check for one database (UX22 onboarding "Verify
    /// connection"): a `GET /v1/databases/{id}`, the same probe `mp doctor`
    /// runs. Success means the token is valid AND the integration is connected
    /// to this database, so the publish target is ready. Throws a user-facing
    /// message otherwise (404 is the "not shared with the integration" case).
    /// No page is created; the daemon stays read-only, writes stay the
    /// pipeline's job. Returns the database's title for a confirming message.
    @discardableResult
    static func verifyDatabase(
        token: String,
        databaseId: String,
        session: URLSession = .shared
    ) async throws -> String {
        // Every daemon-originated Notion call emits an audit line, like `refresh()`.
        Log.event(category: "daemon", action: "notion_verify_started",
                  attributes: ["host": "api.notion.com"])
        func fail(_ code: Int, _ message: String) -> NSError {
            Log.event(category: "daemon", action: "notion_verify_failed",
                      attributes: ["host": "api.notion.com", "error": message])
            return NSError(domain: "NotionDatabaseList", code: code,
                           userInfo: [NSLocalizedDescriptionKey: message])
        }
        let id = databaseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://api.notion.com/v1/databases/\(id)") else {
            throw fail(-1, "Database id is not a valid value.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw fail(-1, "No HTTP response from Notion.")
        }
        switch http.statusCode {
        case 200:
            Log.event(category: "daemon", action: "notion_verify_completed",
                      attributes: ["host": "api.notion.com"])
            return databaseTitle(jsonData: data)
        case 404:
            throw fail(404, "Database not found, or the integration is not connected to it. In Notion, open the database, then the '…' menu -> Connections -> add your integration.")
        case 401, 403:
            throw fail(http.statusCode, "Notion rejected the token (HTTP \(http.statusCode)). Check the integration token.")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw fail(http.statusCode, "Notion returned HTTP \(http.statusCode): \(body.prefix(160))")
        }
    }

    /// The `title` plain-text of a `/v1/databases/{id}` response, or "(untitled)".
    /// Exposed for tests to lock the JSON shape.
    static func databaseTitle(jsonData: Data) -> String {
        guard let raw = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let parts = raw["title"] as? [[String: Any]] else {
            return "(untitled)"
        }
        let title = parts.compactMap { $0["plain_text"] as? String }.joined()
        return title.isEmpty ? "(untitled)" : title
    }

    /// Parse `(id, title)` pairs from a `/v1/search` response. Exposed for tests to lock in the JSON shape contract.
    static func parse(jsonData: Data) -> [NotionDatabaseEntry] {
        guard let raw = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let results = raw["results"] as? [[String: Any]] else {
            return []
        }
        var out: [NotionDatabaseEntry] = []
        for item in results {
            guard let id = item["id"] as? String, !id.isEmpty else { continue }
            // Notion title is an array of rich-text blocks: [{"plain_text": "..."}, ...].
            var title = ""
            if let parts = item["title"] as? [[String: Any]] {
                title = parts.compactMap { $0["plain_text"] as? String }.joined()
            }
            if title.isEmpty {
                title = "(untitled)"
            }
            out.append(NotionDatabaseEntry(id: id, title: title))
        }
        return out.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
