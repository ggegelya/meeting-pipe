import Foundation
import os
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
    /// PIPE36: one on-device call ran past `AppleIntelligenceSummarizer.callCeilingSeconds`.
    /// Not deterministic: a hang is a framework state, not a property of the transcript, so
    /// `isDeterministicBackendFailure` leaves it out and a plain retry stays the way back.
    case timedOut(seconds: Double)

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
        case .timedOut(let seconds):
            return "Apple Intelligence did not answer within \(Int(seconds)) seconds on one part of the transcript, so the summary was stopped. Retry when you are ready."
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
    /// PIPE36: the per-call ceiling `generate` applies; see the constant.
    var callCeilingSeconds: Double = AppleIntelligenceSummarizer.callCeilingSeconds

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
        outputSuffix: String = "",
        onCall: ((Int, Int) -> Void)? = nil
    ) async throws {
        guard let raw = try? String(contentsOf: transcriptMD, encoding: .utf8),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleIntelligenceError.emptyTranscript
        }
        let summary = try await summarize(
            transcript: raw, teamContext: teamContext, summaryLanguage: summaryLanguage, onCall: onCall
        )
        try Self.write(summary: summary, transcriptMD: transcriptMD, suffix: outputSuffix)
    }

    /// `onCall(done, planned)` beats once before every on-device call (PIPE36).
    func summarize(
        transcript: String, teamContext: String, summaryLanguage: String,
        onCall: ((Int, Int) -> Void)? = nil
    ) async throws -> MeetingSummary {
        guard Self.isAvailable else {
            throw AppleIntelligenceError.unavailable(Self.availabilityReason ?? "unavailable")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await generate(
                transcript: transcript, teamContext: teamContext, summaryLanguage: summaryLanguage,
                onCall: onCall
            )
        }
        #endif
        throw AppleIntelligenceError.unavailable("macOS 26 or later is required")
    }

    /// PIPE36: the ceiling on one on-device call, map or reduce. Measured on the owner's Mac
    /// (macOS 27.2) on 2026-11-12 with a synthetic 1,000-character English window and this
    /// file's schema directive: 7.2 s for the first call of a process, then 3.0 s three times.
    /// A reduce merges `reduceBatch` partials of about 600 characters each, so its input is a
    /// few map windows long, and Cyrillic tokenizes at about 1.7 tokens a character against
    /// about 0.3 for English (LOCAL3). 180 s is 25 times the slowest call measured, which
    /// leaves a slow reduce on a Ukrainian meeting well inside it. Every call is bounded by
    /// the model's 4,096-token context, so one past this is a framework hang, not a big window.
    static let callCeilingSeconds: Double = 180

    /// One on-device call: the window or merged partials, its instructions, and whether it is
    /// a reduce. The seam `mapReduce` drives, so its loop is tested without the model.
    typealias Respond = @Sendable (_ body: String, _ instructions: String, _ isReduce: Bool) async throws -> MeetingSummary

    /// How many calls `mapReduce` makes over `windows` map windows (PIPE36), so a progress
    /// beat can say "n of total". One per window, then one per reduce group of two or more,
    /// round after round until one partial remains. A single window is one call, no reduce.
    static func plannedCalls(windows: Int, reduceBatch: Int) -> Int {
        guard windows > 1 else { return 1 }
        let batch = max(2, reduceBatch)
        var calls = windows
        var remaining = windows
        while remaining > 1 {
            calls += remaining / batch + (remaining % batch >= 2 ? 1 : 0)
            remaining = (remaining + batch - 1) / batch
        }
        return calls
    }

    /// The map then hierarchical reduce (LOCAL3), with what PIPE36 put around every call: a
    /// cancellation check before it, so a Cancel lands before the next call rather than after
    /// the last of about 200 on a 3 h meeting; a beat before it (`onCall(done, planned)`), so
    /// a healthy summarize never trips the 30 s stall flag; and a ceiling on it. A call that
    /// fails or times out after the Task was cancelled reports the cancellation rather than
    /// the fault, because the owner's click is why it ended.
    ///
    /// Outside the `FoundationModels` gate on purpose: the CI runner has no such framework,
    /// and this loop is the part a test has to reach.
    static func mapReduce(
        windows: [String],
        instructions: String,
        reduceInstructions: String,
        reduceBatch: Int,
        callCeiling: Double,
        respond: @escaping Respond,
        onCall: ((Int, Int) -> Void)? = nil
    ) async throws -> MeetingSummary {
        let planned = plannedCalls(windows: windows.count, reduceBatch: reduceBatch)
        var done = 0
        func call(_ body: String, _ instructions: String, isReduce: Bool) async throws -> MeetingSummary {
            try Task.checkCancellation()
            onCall?(done, planned)
            do {
                let summary = try await withCallCeiling(seconds: callCeiling) {
                    try await respond(body, instructions, isReduce)
                }
                done += 1
                return summary
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
        if windows.count <= 1 {
            return try await call(windows.first ?? "", instructions, isReduce: false)
        }
        // Chunked map then a hierarchical reduce: each window yields a partial
        // summary, then partials are merged in rounds of `reduceBatch` until one
        // remains, so no single reduce call concatenates every partial and blows
        // the ~4K-token context (LOCAL3).
        var partials: [MeetingSummary] = []
        for window in windows {
            partials.append(try await call(window, instructions, isReduce: false))
        }
        let batch = max(2, reduceBatch)  // >= 2 so each round strictly shrinks the set
        while partials.count > 1 {
            var next: [MeetingSummary] = []
            for group in batched(partials, size: batch) {
                if group.count == 1 {
                    next.append(group[0])
                    continue
                }
                let combined = group.map(renderForReduce).joined(separator: "\n\n---\n\n")
                next.append(try await call(combined, reduceInstructions, isReduce: true))
            }
            partials = next
        }
        guard let merged = partials.first else {
            throw AppleIntelligenceError.parseFailed("no partial summaries produced")
        }
        return merged
    }

    /// Run one call under `seconds` (PIPE36). `runWithTimeout` is the right tool here, unlike
    /// for the blocking work CI8 is about: `LanguageModelSession.respond` suspends rather than
    /// holding a thread. A call past the ceiling is abandoned, not stopped (nothing can stop a
    /// wedged framework call), and its late answer is dropped.
    static func withCallCeiling<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = OSAllocatedUnfairLock<Result<T, Error>?>(initialState: nil)
        let finished = await runWithTimeout(seconds: seconds) {
            let result: Result<T, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            box.withLock { $0 = result }
        }
        guard finished, let result = box.withLock({ $0 }) else {
            throw AppleIntelligenceError.timedOut(seconds: seconds)
        }
        return try result.get()
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generate(
        transcript: String, teamContext: String, summaryLanguage: String,
        onCall: ((Int, Int) -> Void)?
    ) async throws -> MeetingSummary {
        let instructions = Self.instructions(teamContext: teamContext, summaryLanguage: summaryLanguage)
        let windows = TranscriptChunker.windows(transcript, maxChars: maxWindowChars, overlapChars: overlapChars)
        // A transcript that fits one window is summarized whole, as before.
        let texts = windows.count <= 1 ? [windows.first?.text ?? transcript] : windows.map(\.text)
        let summarizer = self
        return try await Self.mapReduce(
            windows: texts,
            instructions: instructions,
            reduceInstructions: Self.reduceInstructions(summaryLanguage: summaryLanguage),
            reduceBatch: reduceBatch,
            callCeiling: callCeilingSeconds,
            respond: { body, instructions, isReduce in
                try await summarizer.respondSummary(body, instructions: instructions, isReduce: isReduce)
            },
            onCall: onCall
        )
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
        if let md = renderMarkdown(summary, deeplinkStem: stem).data(using: .utf8) {
            try md.write(to: mdURL)
        }
    }

    /// FEAT10: the ` [12:34]` (or ` [12:34, 18:22]`) tail a cited point carries,
    /// mirroring `markdown.evidence_suffix`. Timestamps only, never the quote:
    /// the phrase is in-app hover detail, not note content.
    ///
    /// AUTO2: with a `deeplinkStem`, each timestamp becomes a
    /// `[12:34](meetingpipe://open?stem=…&t=…)` link back into the app. The link
    /// syntax eats the brackets rather than nesting inside them, because a
    /// leading `[[` is an Obsidian wikilink.
    static func evidenceSuffix(
        _ anchors: [MeetingSummary.Evidence], deeplinkStem: String? = nil
    ) -> String {
        guard !anchors.isEmpty else { return "" }
        guard let stem = deeplinkStem else {
            return " [" + anchors.map { TranscriptDisplay.timestamp($0.t) }.joined(separator: ", ") + "]"
        }
        return " " + anchors.map {
            "[\(TranscriptDisplay.timestamp($0.t))](\(deeplinkURL(stem: stem, seconds: $0.t)))"
        }.joined(separator: ", ")
    }

    /// AUTO2: `meetingpipe://open?stem=<stem>&t=<seconds>`, mirroring
    /// `markdown.deeplink_url`. The stem is percent-encoded down to the
    /// unreserved set (what Python's `quote(safe="")` leaves alone), because it
    /// also has to be safe inside a Markdown link target where a bare `)` would
    /// end the link early.
    static func deeplinkURL(stem: String, seconds: Double) -> String {
        let encoded = stem.addingPercentEncoding(withAllowedCharacters: Self.urlUnreserved) ?? stem
        return "\(AutomationCommand.scheme)://open?stem=\(encoded)&t=\(deeplinkSeconds(seconds))"
    }

    /// Millisecond precision with trailing zeros stripped, mirroring
    /// `markdown.deeplink_seconds`. The fraction is load-bearing:
    /// `TranscriptSegmentLookup` picks the last segment starting at or before
    /// `t`, so truncating an anchor snapped to a 754.32 s segment start would
    /// land the jump on the row before it.
    static func deeplinkSeconds(_ seconds: Double) -> String {
        var text = String(format: "%.3f", max(0, seconds))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }

    /// RFC 3986 unreserved characters, the exact set Python's
    /// `urllib.parse.quote` leaves unescaped with `safe=""`. Spelled out as
    /// ASCII literals on purpose: `CharacterSet.alphanumerics` is every Unicode
    /// letter, so a Cyrillic stem would survive here and be percent-encoded on
    /// the Python side, and `urlQueryAllowed` permits `&` and `=`, which would
    /// let a stem forge query parameters.
    private static let urlUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Human-readable rendering mirroring `markdown.render_summary_md`, using a
    /// plain hyphen for the due-date separator (the project bans em-dashes).
    /// Pinned by the CI3 golden fixture.
    ///
    /// This backend emits no evidence of its own (FEAT10 v1: absence over wrong
    /// anchors on the on-device path), but it is still the renderer every summary
    /// goes through on this side, so it has to render anchors written by any
    /// other backend.
    ///
    /// AUTO2: `deeplinkStem` links each rendered timestamp back into the app, the
    /// same way `render_summary_md`'s does. The file this writes is the stored
    /// `<stem>.summary.md`, which Python's writer also links, so the stem is
    /// passed rather than defaulted away.
    static func renderMarkdown(_ s: MeetingSummary, deeplinkStem: String? = nil) -> String {
        var lines: [String] = ["# \(s.title)", ""]
        if !s.attendees.isEmpty {
            lines.append("**Attendees:** " + s.attendees.joined(separator: ", "))
            lines.append("")
        }
        lines.append("_Language: \(s.detectedLanguage ?? "en")_")
        lines.append("")
        lines.append("## Summary")
        for (i, bullet) in s.summary.enumerated() {
            lines.append("- \(bullet)\(evidenceSuffix(s.evidence(section: "summary", at: i), deeplinkStem: deeplinkStem))")
        }
        lines.append("")
        if !s.decisions.isEmpty {
            lines.append("## Decisions")
            for (i, d) in s.decisions.enumerated() {
                lines.append("\(i + 1). \(d)\(evidenceSuffix(s.evidence(section: "decisions", at: i), deeplinkStem: deeplinkStem))")
            }
            lines.append("")
        }
        if !s.actions.isEmpty {
            lines.append("## Action Items")
            // AI10: mirror `markdown._action_runs` - a roll-up across meetings
            // (the weekly digest) tags each action with its source, and those
            // runs render under sub-headings. Nothing here tags anything, so
            // this side always takes the single untagged run.
            for run in MeetingSummary.actionRuns(s.actions) {
                if let group = run.group, !group.isEmpty {
                    lines.append("")
                    lines.append("### \(group)")
                }
                for a in run.actions {
                    let owner = (a.owner?.isEmpty == false) ? a.owner! : "_unassigned_"
                    let due = (a.due?.isEmpty == false) ? " - due \(a.due!)" : ""
                    let box = a.resolved ? "[x]" : "[ ]"
                    let cite = evidenceSuffix(a.evidence, deeplinkStem: deeplinkStem)
                    lines.append(
                        "- \(box) **\(owner)**: \(a.task)\(due)  _(confidence: \(a.confidence))_\(cite)"
                    )
                }
            }
            lines.append("")
        }
        if !s.questions.isEmpty {
            lines.append("## Open Questions")
            for (i, q) in s.questions.enumerated() {
                lines.append("- \(q)\(evidenceSuffix(s.evidence(section: "questions", at: i), deeplinkStem: deeplinkStem))")
            }
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
