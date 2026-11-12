import Foundation

/// One parsed line from the JSONL event logs, flattened for read-only display in
/// the Diagnostics window (UX20). The attributes beyond `ts`/`category`/`action`
/// are pre-formatted into `detail` (the `mp logs` `k=v k=v` shape) so the model
/// stays a plain value type.
struct DiagnosticEvent: Identifiable, Equatable {
    let id: Int
    let timestamp: String
    let date: Date?
    let category: String
    let action: String
    let detail: String
}

/// The window's three filters, as one value a reload carries off main.
struct DiagnosticsQuery: Equatable {
    var since: Date?
    var category: String?
    var action: String?
}

/// What a load returns: the rows to show, and how many lines it read but could not parse
/// (PERF13). A torn line used to be dropped in silence, so a row lost to a concurrent write
/// was indistinguishable from an event that never fired.
struct DiagnosticsResult: Equatable {
    var events: [DiagnosticEvent] = []
    var skipped = 0
}

/// Read-only reader over `events.jsonl` + `pipeline_events.jsonl`, mirroring the
/// `mp logs` semantics (since / category / action filters) in-process so a
/// detection incident is triageable without dropping to a terminal. Reads across
/// PERF7's rotated generations via `Log.logGenerations`.
///
/// PERF13 made a load cost what it shows rather than what is on disk. Each family is capped
/// at four 5 MiB files (about 200k lines across both), and the old load read every generation,
/// parsed every line, formatted every line's detail and parsed its timestamp, and only then
/// filtered and capped, on main, on every filter change. Now: each family is walked newest
/// first and stops at the first line older than `since` (lines ascend within a file, and a
/// generation whose modification date is already older is never opened), a row is rejected on
/// its timestamp, category and action before anything else is built, a family stops once it
/// has `displayLimit` matches, and `detail` is formatted only for the rows actually returned.
enum DiagnosticsLog {
    static let sources = ["events.jsonl", "pipeline_events.jsonl"]

    /// The most rows a load returns, newest first. Each family stops reading once it holds
    /// this many matches, so the cap bounds the parse as well as the render (PERF13: it used
    /// to apply only after every generation had been read and parsed, on main).
    static let displayLimit = 2000

    /// The categories both emitters write (CONVENTIONS event-log schema), for the
    /// filter dropdown. "" is the implicit "all" option the view prepends.
    static let categories = [
        "automation", "axbus", "coordinator", "correction", "detector", "doctor",
        "halbus", "library", "lifecycle", "main", "micgate", "recorder", "signal",
        "transcription", "workflow", "pipeline", "publisher",
    ]

    typealias Reader = (URL) -> String?
    typealias Modified = (URL) -> Date?
    typealias Formatter = ([String: Any]) -> String

    static func load(
        logsDir: URL = Log.logsDir,
        since: Date?,
        category: String?,
        action: String?
    ) -> [DiagnosticEvent] {
        load(logsDir: logsDir, query: DiagnosticsQuery(since: since, category: category, action: action)).events
    }

    /// The seams (`read`, `modified`, `formatDetail`) are there so a test can count which
    /// files were opened and how many details were built.
    static func load(
        logsDir: URL,
        query: DiagnosticsQuery,
        read: Reader = { try? String(contentsOf: $0, encoding: .utf8) },
        modified: Modified = { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate },
        formatDetail: Formatter = DiagnosticsLog.formatDetail
    ) -> DiagnosticsResult {
        let category = query.category.flatMap { $0.isEmpty ? nil : $0 }
        let action = query.action.flatMap { $0.isEmpty ? nil : $0 }
        var matches: [Match] = []
        var skipped = 0
        for name in sources {
            var found = 0
            // Newest first: `logGenerations` is oldest first, base last.
            family: for url in Log.logGenerations(logsDir.appendingPathComponent(name)).reversed() {
                // A file last written before `since` holds nothing newer, and every older
                // generation is older still.
                if let since = query.since, let m = modified(url), m < since { break family }
                guard let text = read(url) else { continue }
                for line in text.split(separator: "\n").reversed() {
                    guard let header = header(of: line) else {
                        if !line.allSatisfy(\.isWhitespace) { skipped += 1 }
                        continue
                    }
                    if let since = query.since {
                        guard let date = header.date else { continue }
                        // Lines ascend within a file, so the first one older than `since`
                        // ends this family.
                        if date < since { break family }
                    }
                    if let category, header.category != category { continue }
                    if let action, header.action != action { continue }
                    matches.append(header)
                    found += 1
                    if found >= displayLimit { break family }
                }
            }
        }
        // The two families interleave in time, so the final order is a sort over the bounded set.
        matches.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let shown = matches.prefix(displayLimit)
        let events = shown.enumerated().map { index, m in
            DiagnosticEvent(
                id: index, timestamp: m.timestamp, date: m.date,
                category: m.category, action: m.action, detail: formatDetail(m.object)
            )
        }
        return DiagnosticsResult(events: events, skipped: skipped)
    }

    /// A parsed line before its detail is built.
    private struct Match {
        let object: [String: Any]
        let timestamp: String
        let date: Date?
        let category: String
        let action: String
    }

    /// The structural keys of one line, or nil for a line that is not a JSON object (a torn
    /// row from a concurrent write, which the caller counts).
    private static func header<S: StringProtocol>(of line: S) -> Match? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return nil
        }
        let ts = obj["ts"] as? String ?? ""
        return Match(
            object: obj, timestamp: ts, date: isoDate(ts),
            category: obj["category"] as? String ?? "?",
            action: obj["action"] as? String ?? "?"
        )
    }

    /// One line as a fully built row, or nil when it does not parse.
    static func parseLine(_ line: String, id: Int) -> DiagnosticEvent? {
        guard let m = header(of: line) else { return nil }
        return DiagnosticEvent(
            id: id, timestamp: m.timestamp, date: m.date,
            category: m.category, action: m.action, detail: formatDetail(m.object)
        )
    }

    /// The `k=v k=v` tail, sorted, skipping the three structural keys. Mirrors
    /// `logs_cmd._format` on the Python side.
    static func formatDetail(_ obj: [String: Any]) -> String {
        let skip: Set<String> = ["ts", "category", "action"]
        return obj
            .filter { !skip.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(scalar($0.value))" }
            .joined(separator: " ")
    }

    private static func scalar(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case is NSNull: return "null"
        default:
            if let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.withoutEscapingSlashes]
            ), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "\(value)"
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func isoDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}

/// The Diagnostics window's loader (PERF13). A reload runs `DiagnosticsLog.load` off main and
/// lands on main only while it is still the newest one asked for, through the same latest-wins
/// pass the Library projections use, so a slow older reload can never overwrite a newer result.
/// Owned by the view as a `@StateObject`.
@MainActor
final class DiagnosticsModel: ObservableObject {
    typealias Loader = @Sendable (DiagnosticsQuery) async -> DiagnosticsResult

    @Published private(set) var result = DiagnosticsResult()
    /// True while a reload is in flight.
    @Published private(set) var isLoading = false
    /// False until the first reload lands, so the window shows a spinner, not "No events".
    @Published private(set) var hasLoaded = false

    private let loader: Loader
    private let pass = ProjectionPass<DiagnosticsResult>()

    nonisolated init(
        loader: @escaping Loader = { query in DiagnosticsLog.load(logsDir: Log.logsDir, query: query) }
    ) {
        self.loader = loader
    }

    @discardableResult
    func reload(_ query: DiagnosticsQuery) -> Task<Void, Never> {
        isLoading = true
        let loader = self.loader
        return pass.start(work: { await loader(query) }) { [weak self] result in
            guard let self else { return }
            self.result = result
            self.isLoading = false
            self.hasLoaded = true
        }
    }
}
