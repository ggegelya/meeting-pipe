import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligenceError: Error, LocalizedError {
    case unavailable(String)
    case emptyTranscript
    case parseFailed(String)
    /// PIPE6: the on-device model rejected the transcript's language/locale (the
    /// case that stranded `20260707-150057`). Deterministic: a same-backend retry
    /// fails again, so the Library offers a local re-summarize instead.
    case unsupportedLanguage(String)

    /// PIPE6: stable phrase embedded in the unsupported-language reason so the
    /// Library can recognize it from `<stem>.error.json` (which carries only a
    /// free-text reason) without a schema change. Producer and consumer share this
    /// constant so they cannot drift; see `Meeting.failureSuggestsLocalReSummarize`.
    static let unsupportedLanguageMarker = "unsupported language or locale"

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return "Apple Intelligence is not available: \(why)"
        case .emptyTranscript: return "Transcript is empty; nothing to summarize."
        case .parseFailed(let detail): return "Apple Intelligence returned an unparseable summary: \(detail)"
        case .unsupportedLanguage(let detail):
            return "Apple Intelligence: \(Self.unsupportedLanguageMarker) for this transcript. \(detail)"
        }
    }

    /// PIPE6: true for a deterministic failure that re-running on the SAME backend
    /// cannot fix, so the recovery is a different-backend re-summarize (local), not
    /// a plain retry.
    var isDeterministicBackendFailure: Bool {
        if case .unsupportedLanguage = self { return true }
        return false
    }

    /// Whether an arbitrary error from the Foundation Models framework is an
    /// unsupported-language/locale rejection. The framework does not vend a stable
    /// public case reachable from the macOS 14 build, so this matches on the
    /// message; pure and `internal` so it is unit-testable without the framework.
    static func isUnsupportedLanguageError(_ error: Error) -> Bool {
        let text = "\(error) \(error.localizedDescription)".lowercased()
        return text.contains("unsupported language") || text.contains("unsupported locale")
            || (text.contains("language") && text.contains("not supported"))
            || (text.contains("locale") && text.contains("not supported"))
    }
}

/// On-device summarization backend on the macOS 26 Foundation Models framework
/// (TECH-SUM1-APPLE). It produces a `MeetingSummary` byte-compatible with the
/// pipeline's schema (so publish + Library read it like any other backend), and
/// chunks long transcripts (the system model has a ~4K-token context) with the
/// same windowing as `pipeline/src/mp/chunking.py` via `TranscriptChunker`.
///
/// All Foundation Models usage is gated behind `#if canImport(FoundationModels)`
/// plus `@available(macOS 26.0, *)`, so the daemon still builds on its macOS 14
/// deployment floor. On older systems, builds without the framework, or when the
/// user has not enabled Apple Intelligence, `isAvailable` is false and
/// `summarizeFile` throws `.unavailable` (surfaced by the pipeline failure UI).
///
/// Scope note (TECH-SUM1-APPLE v1): the instruction prompt is Swift-resident and
/// optionally injects the workflow team context; it does not reuse the Python
/// `meeting_summary.md` master prompt. Output quality is validated by on-device
/// dogfood (the acceptance bars require a real Apple Intelligence run).
struct AppleIntelligenceSummarizer {
    /// Chars per map window. The system model's context is 4096 tokens TOTAL,
    /// and Cyrillic tokenizes at ~1.7 tokens/char (vs ~0.3 for English), so the
    /// old 3200-char window overflowed on Ukrainian. 1000 keeps a worst-case
    /// window under the limit with headroom for the instructions + schema
    /// directive; English under-utilizes the window, but correctness wins (LOCAL3).
    var maxWindowChars: Int = 1000
    var overlapChars: Int = 200
    /// Partials merged per reduce call, so the reduce input also stays under the
    /// 4096-token context. A flat reduce concatenated every partial into one call
    /// and overflowed on real meetings; partials are now merged in rounds of this
    /// size until one remains (LOCAL3).
    var reduceBatch: Int = 4

    /// nil when Apple Intelligence can summarize right now; otherwise a
    /// human-readable reason. Safe to call on any macOS (false below 26).
    static var availabilityReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                return describe(reason)
            }
        } else {
            return "macOS 26 or later is required"
        }
        #else
        return "this build was compiled without the Foundation Models framework"
        #endif
    }

    static var isAvailable: Bool { availabilityReason == nil }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "this device is not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is not enabled in System Settings"
        case .modelNotReady: return "the system model is downloading or not ready yet"
        @unknown default: return "unavailable"
        }
    }
    #endif

    /// Read `<stem>.md`, summarize on-device, and write `<stem>.summary.json` plus
    /// `<stem>.summary.md` in the pipeline's schema. `outputSuffix` ("candidate")
    /// writes a preview sidecar without touching the live summary (TECH-A16).
    func summarizeFile(
        transcriptMD: URL,
        teamContext: String,
        summaryLanguage: String,
        outputSuffix: String = ""
    ) async throws {
        guard let raw = try? String(contentsOf: transcriptMD, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleIntelligenceError.emptyTranscript
        }
        let summary = try await summarize(
            transcript: raw, teamContext: teamContext, summaryLanguage: summaryLanguage
        )
        try Self.write(summary: summary, transcriptMD: transcriptMD, suffix: outputSuffix)
    }

    func summarize(transcript: String, teamContext: String, summaryLanguage: String) async throws -> MeetingSummary {
        guard Self.isAvailable else {
            throw AppleIntelligenceError.unavailable(Self.availabilityReason ?? "unavailable")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await generate(
                transcript: transcript, teamContext: teamContext, summaryLanguage: summaryLanguage
            )
        }
        #endif
        throw AppleIntelligenceError.unavailable("macOS 26 or later is required")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generate(transcript: String, teamContext: String, summaryLanguage: String) async throws -> MeetingSummary {
        let instructions = Self.instructions(teamContext: teamContext, summaryLanguage: summaryLanguage)
        let windows = TranscriptChunker.windows(transcript, maxChars: maxWindowChars, overlapChars: overlapChars)
        if windows.count <= 1 {
            return try await respondSummary(windows.first?.text ?? transcript, instructions: instructions)
        }
        // Chunked map then a hierarchical reduce: each window yields a partial
        // summary, then partials are merged in rounds of `reduceBatch` until one
        // remains, so no single reduce call concatenates every partial and blows
        // the ~4K-token context (LOCAL3).
        var partials: [MeetingSummary] = []
        for window in windows {
            partials.append(try await respondSummary(window.text, instructions: instructions))
        }
        let batch = max(2, reduceBatch)  // >= 2 so each round strictly shrinks the set
        while partials.count > 1 {
            var next: [MeetingSummary] = []
            for group in Self.batched(partials, size: batch) {
                if group.count == 1 {
                    next.append(group[0])
                    continue
                }
                let combined = group.map(Self.renderForReduce).joined(separator: "\n\n---\n\n")
                next.append(try await respondSummary(
                    combined,
                    instructions: Self.reduceInstructions(summaryLanguage: summaryLanguage),
                    isReduce: true
                ))
            }
            partials = next
        }
        guard let merged = partials.first else {
            throw AppleIntelligenceError.parseFailed("no partial summaries produced")
        }
        return merged
    }

    @available(macOS 26.0, *)
    private func respondSummary(_ body: String, instructions: String, isReduce: Bool = false) async throws -> MeetingSummary {
        let session = LanguageModelSession(instructions: instructions)
        let header = isReduce
            ? "Merge these partial meeting summaries into one final summary. Reply with ONLY the JSON object."
            : "Summarize this meeting transcript. Reply with ONLY the JSON object."
        let prompt = header + "\n\n" + Self.schemaDirective + "\n\n" + body
        let content: String
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
            content = response.content
        } catch {
            // PIPE6: surface an unsupported-language/locale rejection as a typed,
            // recognizable error so the Library offers a local re-summarize instead
            // of a doomed same-backend retry. Other errors propagate unchanged.
            if AppleIntelligenceError.isUnsupportedLanguageError(error) {
                throw AppleIntelligenceError.unsupportedLanguage(String("\(error)".prefix(200)))
            }
            throw error
        }
        guard let summary = Self.parse(content) else {
            throw AppleIntelligenceError.parseFailed(String(content.prefix(200)))
        }
        return summary
    }
    #endif

    // MARK: - Prompt + schema (Swift-resident)

    static func instructions(teamContext: String, summaryLanguage: String) -> String {
        var s = """
        You summarize meeting transcripts into a strict JSON object. Be concise and factual. \
        Summarize in your own words: never echo or transcribe raw dialogue, and never quote long \
        verbatim passages. Use at most 5 summary bullets, each a single short sentence. \
        Do not invent action items: when no owner is named, set owner to null and confidence to "low". \
        Decisions contain only statements with explicit commitment language (will / agreed / decided / approved).
        """
        s += "\n\n" + languageDirective(summaryLanguage)
        let ctx = teamContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            s += "\n\nTeam context:\n" + ctx
        }
        return s
    }

    static func reduceInstructions(summaryLanguage: String) -> String {
        "You merge several partial meeting summaries (each a JSON object) into a single final "
            + "summary JSON object. Deduplicate bullets, decisions, action items, questions, and "
            + "attendees. Keep the highest-confidence owner for each action. Keep at most 5 "
            + "summary bullets in the final object.\n\n"
            + languageDirective(summaryLanguage)
    }

    /// Forceful, field-by-field language directive (LOCAL7). The system model
    /// mislabelled and drifted Ukrainian in the engine comparison, so the target
    /// is restated as non-negotiable and applied to every string field rather
    /// than left as a one-line aside.
    static func languageDirective(_ code: String) -> String {
        let c = code.trimmingCharacters(in: .whitespaces).lowercased()
        if c.isEmpty || c == "auto" || c.count != 2 {
            return "Output language (non-negotiable): write EVERY string value, the title, "
                + "every summary bullet, decision, action task, and question, in the SAME "
                + "language as the transcript. A Ukrainian transcript yields a Ukrainian "
                + "summary; do not switch to English or Russian. An English transcript yields "
                + "an English summary. Keep proper nouns and code identifiers verbatim."
        }
        return "Output language (non-negotiable): write EVERY string value, the title, every "
            + "summary bullet, decision, action task, and question, in language `\(c)` "
            + "(ISO 639-1), regardless of the transcript's language. Do not switch to any "
            + "other language. Keep proper nouns and code identifiers verbatim."
    }

    static let schemaDirective = """
    The JSON object must have exactly these keys:
    {"title": string, "summary": [string], "decisions": [string], "actions": [{"task": string, \
    "owner": string|null, "due": string|null, "confidence": "low"|"medium"|"high"}], \
    "questions": [string], "attendees": [string], "detected_language": string}
    Output the JSON object and nothing else: no prose, no Markdown fences.
    """

    /// Partition `items` into consecutive groups of at most `size` for the
    /// hierarchical reduce (LOCAL3). `size <= 0` collapses to a single group.
    /// Pure, so the batching invariant is unit-tested without the on-device model.
    static func batched<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0 else { return items.isEmpty ? [] : [items] }
        var out: [[T]] = []
        var i = 0
        while i < items.count {
            out.append(Array(items[i..<min(i + size, items.count)]))
            i += size
        }
        return out
    }

    static func renderForReduce(_ s: MeetingSummary) -> String {
        let obj = s.jsonObject()
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return s.title
    }

    // MARK: - Parse + write

    /// Tolerant parse: try the whole reply as JSON, then fall back to the largest
    /// balanced object embedded in any surrounding prose.
    static func parse(_ text: String) -> MeetingSummary? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let s = try? JSONDecoder().decode(MeetingSummary.self, from: data),
           !(s.title.isEmpty && s.summary.isEmpty) {
            return s
        }
        if let extracted = largestJSONObject(in: text),
           let data = extracted.data(using: .utf8),
           let s = try? JSONDecoder().decode(MeetingSummary.self, from: data) {
            return s
        }
        return nil
    }

    /// Largest balanced top-level `{...}`, ignoring braces inside strings. Mirrors
    /// `json_extract.largest_balanced_json_object`; pinned by the CI3 golden fixture.
    static func largestJSONObject(in text: String) -> String? {
        let chars = Array(text)
        var best: (len: Int, lo: Int, hi: Int)?
        var depth = 0
        var start = -1
        var inStr = false
        var escape = false
        for (i, ch) in chars.enumerated() {
            if inStr {
                if escape { escape = false }
                else if ch == "\\" { escape = true }
                else if ch == "\"" { inStr = false }
                continue
            }
            if ch == "\"" { inStr = true; continue }
            if ch == "{" {
                if depth == 0 { start = i }
                depth += 1
                continue
            }
            if ch == "}" {
                if depth == 0 { continue }
                depth -= 1
                if depth == 0, start >= 0 {
                    let len = i - start + 1
                    if best == nil || len > best!.len { best = (len, start, i + 1) }
                    start = -1
                }
            }
        }
        guard let b = best else { return nil }
        return String(chars[b.lo..<b.hi])
    }

    static func write(summary: MeetingSummary, transcriptMD: URL, suffix: String = "") throws {
        let dir = transcriptMD.deletingLastPathComponent()
        let stem = transcriptMD.deletingPathExtension().lastPathComponent
        // `suffix` ("candidate") writes a preview sidecar (TECH-A16); empty for the live output.
        let infix = suffix.isEmpty ? "" : ".\(suffix)"
        let jsonURL = dir.appendingPathComponent("\(stem).summary\(infix).json")
        let mdURL = dir.appendingPathComponent("\(stem).summary\(infix).md")
        let data = try JSONSerialization.data(
            withJSONObject: summary.jsonObject(),
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        try data.write(to: jsonURL)
        if let md = renderMarkdown(summary).data(using: .utf8) {
            try md.write(to: mdURL)
        }
    }

    /// Human-readable rendering mirroring `markdown.render_summary_md`, using a
    /// plain hyphen for the due-date separator (the project bans em-dashes).
    /// Pinned by the CI3 golden fixture.
    static func renderMarkdown(_ s: MeetingSummary) -> String {
        var lines: [String] = ["# \(s.title)", ""]
        if !s.attendees.isEmpty {
            lines.append("**Attendees:** " + s.attendees.joined(separator: ", "))
            lines.append("")
        }
        lines.append("_Language: \(s.detectedLanguage ?? "en")_")
        lines.append("")
        lines.append("## Summary")
        for bullet in s.summary { lines.append("- \(bullet)") }
        lines.append("")
        if !s.decisions.isEmpty {
            lines.append("## Decisions")
            for (i, d) in s.decisions.enumerated() { lines.append("\(i + 1). \(d)") }
            lines.append("")
        }
        if !s.actions.isEmpty {
            lines.append("## Action Items")
            for a in s.actions {
                let owner = (a.owner?.isEmpty == false) ? a.owner! : "_unassigned_"
                let due = (a.due?.isEmpty == false) ? " - due \(a.due!)" : ""
                let box = a.resolved ? "[x]" : "[ ]"
                lines.append("- \(box) **\(owner)**: \(a.task)\(due)  _(confidence: \(a.confidence))_")
            }
            lines.append("")
        }
        if !s.questions.isEmpty {
            lines.append("## Open Questions")
            for q in s.questions { lines.append("- \(q)") }
            lines.append("")
        }
        // WF7: workflow-defined extra sections, mirroring markdown.render_summary_md.
        for sec in s.extraSections where !sec.content.isEmpty {
            lines.append("## \(sec.name)")
            for item in sec.content { lines.append("- \(item)") }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }
}
