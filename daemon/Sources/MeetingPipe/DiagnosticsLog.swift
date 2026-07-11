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

/// Read-only reader over `events.jsonl` + `pipeline_events.jsonl`, mirroring the
/// `mp logs` semantics (since / category / action filters) in-process so a
/// detection incident is triageable without dropping to a terminal. Reads across
/// PERF7's rotated generations via `Log.logGenerations`.
enum DiagnosticsLog {
    static let sources = ["events.jsonl", "pipeline_events.jsonl"]

    /// Cap the rendered set so a multi-megabyte log cannot stall the window; the
    /// filters narrow before this bites, and newest-first means the cap drops the
    /// oldest.
    static let displayLimit = 2000

    /// The categories both emitters write (CONVENTIONS event-log schema), for the
    /// filter dropdown. "" is the implicit "all" option the view prepends.
    static let categories = [
        "automation", "axbus", "coordinator", "correction", "detector", "doctor",
        "halbus", "library", "lifecycle", "main", "micgate", "recorder", "signal",
        "transcription", "workflow", "pipeline", "publisher",
    ]

    static func load(
        logsDir: URL = Log.logsDir,
        since: Date?,
        category: String?,
        action: String?
    ) -> [DiagnosticEvent] {
        var raw: [DiagnosticEvent] = []
        var idx = 0
        for name in sources {
            for url in Log.logGenerations(logsDir.appendingPathComponent(name)) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                text.enumerateLines { line, _ in
                    if let ev = parseLine(line, id: idx) {
                        raw.append(ev)
                        idx += 1
                    }
                }
            }
        }
        return filterAndSort(raw, since: since, category: category, action: action)
    }

    static func parseLine(_ line: String, id: Int) -> DiagnosticEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A truncated tail line during a concurrent write; skip, don't abort.
            return nil
        }
        let ts = obj["ts"] as? String ?? ""
        return DiagnosticEvent(
            id: id,
            timestamp: ts,
            date: isoDate(ts),
            category: obj["category"] as? String ?? "?",
            action: obj["action"] as? String ?? "?",
            detail: formatDetail(obj)
        )
    }

    static func filterAndSort(
        _ events: [DiagnosticEvent],
        since: Date?,
        category: String?,
        action: String?
    ) -> [DiagnosticEvent] {
        var out = events.filter { ev in
            if let category, !category.isEmpty, ev.category != category { return false }
            if let action, !action.isEmpty, ev.action != action { return false }
            if let since {
                guard let d = ev.date, d >= since else { return false }
            }
            return true
        }
        out.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if out.count > displayLimit { out = Array(out.prefix(displayLimit)) }
        return out
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
