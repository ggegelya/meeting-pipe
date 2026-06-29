#!/usr/bin/env swift
// Throwaway harness: summarize one transcript with the macOS 26 Apple Intelligence
// (Foundation Models) backend, headless, writing a MeetingSummary-shaped JSON.
//
// Mirrors daemon/Sources/MeetingPipe/Summarization/AppleIntelligenceSummarizer.swift
// (instructions + schema directive + chunked map/reduce) but is self-contained so
// it runs via `swift daemon/scripts/ai-summarize.swift` without the app target. Used
// by the engine comparison (docs/engine-comparison.md) to get a real Apple
// Intelligence column alongside the Python Anthropic + MLX backends.
//
// Usage: swift ai-summarize.swift <transcript.md> <out.json> [teamContext] [lang]
// Exit codes: 0 ok, 2 bad args, 3 Apple Intelligence unavailable, 4 generation error.
// Prints "LATENCY_SEC=<f> WINDOWS=<n>" to stderr.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

func die(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
if args.count < 3 { die("usage: ai-summarize.swift <transcript.md> <out.json> [teamContext] [lang]", 2) }
let transcriptPath = args[1]
let outPath = args[2]
let teamContext = args.count > 3 ? args[3] : ""
let summaryLanguage = args.count > 4 ? args[4] : "auto"

guard let transcript = try? String(contentsOf: URL(fileURLWithPath: transcriptPath), encoding: .utf8),
      !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    die("empty or unreadable transcript: \(transcriptPath)", 2)
}

// The system model's context is 4096 tokens TOTAL. Cyrillic tokenizes at ~1.3
// tokens/char (vs ~0.3 for English), so a 3200-char Ukrainian window overflows.
// Dense Ukrainian transcripts measured at ~1.7 to 1.9 tokens/char, so 1000 chars
// keeps a worst-case window under the limit with headroom for the instructions +
// schema directive. (English under-utilizes the window, but correctness wins.)
let maxWindowChars = 1000
let overlapChars = 200
// Partials per reduce call, so the reduce input also stays under 4096 tokens
// (the LOCAL3 bug: a flat reduce concatenates every partial into one call).
let reduceBatch = 4

func languageDirective(_ code: String) -> String {
    let c = code.trimmingCharacters(in: .whitespaces).lowercased()
    if c.isEmpty || c == "auto" || c.count != 2 {
        return "Write the summary in the SAME language as the transcript "
            + "(English transcript yields an English summary, Ukrainian yields Ukrainian)."
    }
    return "Write the summary in language `\(c)` (ISO 639-1) regardless of the transcript's "
        + "language; preserve proper nouns and code identifiers verbatim."
}

func instructions() -> String {
    var s = """
    You summarize meeting transcripts into a strict JSON object. Be concise and factual. \
    Do not invent action items: when no owner is named, set owner to null and confidence to "low". \
    Decisions contain only statements with explicit commitment language (will / agreed / decided / approved).
    """
    s += "\n\n" + languageDirective(summaryLanguage)
    let ctx = teamContext.trimmingCharacters(in: .whitespacesAndNewlines)
    if !ctx.isEmpty { s += "\n\nTeam context:\n" + ctx }
    return s
}

func reduceInstructions() -> String {
    "You merge several partial meeting summaries (each a JSON object) into a single final "
        + "summary JSON object. Deduplicate bullets, decisions, action items, questions, and "
        + "attendees. Keep the highest-confidence owner for each action.\n\n"
        + languageDirective(summaryLanguage)
}

let schemaDirective = """
The JSON object must have exactly these keys:
{"title": string, "summary": [string], "decisions": [string], "actions": [{"task": string, \
"owner": string|null, "due": string|null, "confidence": "low"|"medium"|"high"}], \
"questions": [string], "attendees": [string], "detected_language": string}
Output the JSON object and nothing else: no prose, no Markdown fences.
"""

// Word-boundary windows so a word is never split at an end boundary.
func windows(_ text: String, maxChars: Int, overlap: Int) -> [String] {
    let chars = Array(text)
    let n = chars.count
    if n <= maxChars { return [text] }
    var out: [String] = []
    var start = 0
    while start < n {
        var end = min(n, start + maxChars)
        if end < n {
            var i = end - 1
            while i > start && !chars[i].isWhitespace { i -= 1 }
            if i > start { end = i }
        }
        out.append(String(chars[start..<end]))
        if end >= n { break }
        start = max(start + 1, end - overlap)
    }
    return out
}

// Largest balanced top-level {...}, ignoring braces inside strings.
func largestJSONObject(in text: String) -> String? {
    let chars = Array(text)
    var best: (len: Int, lo: Int, hi: Int)?
    var depth = 0, start = -1
    var inStr = false, escape = false
    for (i, ch) in chars.enumerated() {
        if inStr {
            if escape { escape = false }
            else if ch == "\\" { escape = true }
            else if ch == "\"" { inStr = false }
            continue
        }
        if ch == "\"" { inStr = true; continue }
        if ch == "{" { if depth == 0 { start = i }; depth += 1; continue }
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

#if canImport(FoundationModels)
if #available(macOS 26.0, *) {
    switch SystemLanguageModel.default.availability {
    case .available: break
    case .unavailable(let reason): die("Apple Intelligence unavailable: \(reason)", 3)
    }

    func respond(_ body: String, instr: String, header: String) async throws -> String {
        let session = LanguageModelSession(instructions: instr)
        let prompt = header + "\n\n" + schemaDirective + "\n\n" + body
        let r = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
        return r.content
    }

    let sem = DispatchSemaphore(value: 0)
    var rc: Int32 = 0
    Task {
        let mapHeader = "Summarize this meeting transcript. Reply with ONLY the JSON object."
        let reduceHeader = "Merge these partial meeting summaries into one final summary. Reply with ONLY the JSON object."
        let wins = windows(transcript, maxChars: maxWindowChars, overlap: overlapChars)
        let t0 = Date()
        do {
            // Map: each window yields a partial summary JSON.
            var partials: [String] = []
            for w in wins {
                let c = try await respond(w, instr: instructions(), header: mapHeader)
                partials.append(largestJSONObject(in: c) ?? c)
            }
            // Reduce in rounds of `reduceBatch` so no single reduce call exceeds the
            // 4096-token context (prototypes the LOCAL3 hierarchical-reduce fix).
            while partials.count > 1 {
                var next: [String] = []
                var i = 0
                while i < partials.count {
                    let group = Array(partials[i..<min(i + reduceBatch, partials.count)])
                    if group.count == 1 {
                        next.append(group[0])
                    } else {
                        let combined = group.joined(separator: "\n\n---\n\n")
                        let c = try await respond(combined, instr: reduceInstructions(), header: reduceHeader)
                        next.append(largestJSONObject(in: c) ?? c)
                    }
                    i += reduceBatch
                }
                partials = next
            }
            let finalJSON = partials.first ?? "{}"
            let elapsed = Date().timeIntervalSince(t0)
            guard let data = finalJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                die("Apple Intelligence returned unparseable JSON: \(finalJSON.prefix(200))", 4)
            }
            let pretty = try JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
            try pretty.write(to: URL(fileURLWithPath: outPath))
            FileHandle.standardError.write(
                "LATENCY_SEC=\(elapsed) WINDOWS=\(wins.count)\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("generation error: \(error)\n".data(using: .utf8)!)
            rc = 4
        }
        sem.signal()
    }
    sem.wait()
    exit(rc)
} else {
    die("macOS 26 or later is required", 3)
}
#else
die("this swift was built without the Foundation Models framework", 3)
#endif
