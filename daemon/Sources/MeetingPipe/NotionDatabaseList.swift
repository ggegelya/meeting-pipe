import Combine
import Foundation

/// One row in the Notion DB picker: the 32-char DB id plus the human-
/// readable title the user assigned in Notion. Sorted alphabetically by
/// title so the picker reads like the user's database sidebar.
struct NotionDatabaseEntry: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let title: String
}

/// Fetches and caches the user's Notion databases for the per-workflow
/// DB picker (TECH-B8).
///
/// Cache lives at `~/Library/Caches/MeetingPipe/notion-databases.json`.
/// We never expire automatically — the cache stays good for as long as
/// the user's Notion DBs are stable. Refresh is explicit (a button next
/// to the picker) so the user is never surprised by a stale list and
/// never pays an API round-trip on a settings-tab open they didn't ask
/// for.
///
/// Threading: every published mutation runs on the main queue. The
/// underlying URLSession call lives on a background queue and posts
/// back via `DispatchQueue.main.async`.
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

    init(
        cacheURL: URL = NotionDatabaseList.defaultCacheURL,
        session: URLSession = .shared
    ) {
        self.cacheURL = cacheURL
        self.session = session
        loadCache()
    }

    nonisolated static let defaultCacheURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MeetingPipe/notion-databases.json")
    }()

    /// Re-fetch the DB list from Notion using the token currently in
    /// the process environment. The Preferences-tab "Apply" path keeps
    /// the env in sync with what's in `secrets.env`, so the daemon's
    /// process env is the right source — no need to reach back into
    /// SecretsStore here.
    func refresh() {
        let token = ProcessInfo.processInfo.environment["NOTION_TOKEN"] ?? ""
        guard !token.isEmpty else {
            state = .failed("Set NOTION_TOKEN in Preferences -> Integrations first.")
            return
        }
        state = .loading
        Task {
            do {
                let fetched = try await Self.fetch(token: token, session: session)
                self.entries = fetched
                self.state = .loaded(fetched)
                self.persistCache(fetched)
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Whether the picker should fall back to a raw text field. Empty
    /// cache + no in-flight load → no UI to render in the dropdown.
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

    /// Fetch the list. Uses the same `/v1/search` filter the pipeline's
    /// `mp doctor` uses to validate the token, so a successful daemon
    /// fetch reproduces the doctor's authentication contract.
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

    /// Pull `(id, title)` pairs out of Notion's `/v1/search` response.
    /// Exposed for tests so the JSON shape contract is locked in.
    static func parse(jsonData: Data) -> [NotionDatabaseEntry] {
        guard let raw = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let results = raw["results"] as? [[String: Any]] else {
            return []
        }
        var out: [NotionDatabaseEntry] = []
        for item in results {
            guard let id = item["id"] as? String, !id.isEmpty else { continue }
            // Title is an array of rich-text blocks: [{"plain_text": "..."}, ...].
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
