import Foundation

/// Window of a transcript produced by `TranscriptChunker`.
struct TranscriptWindow: Equatable {
    let index: Int
    let text: String
    let isFirst: Bool
    let isLast: Bool
}

/// Swift mirror of the pipeline's chunking primitive
/// (`pipeline/src/mp/chunking.py`, TECH-SUM1-PRIMITIVE). Kept deliberately
/// identical so the Apple Intelligence summarizer windows a long transcript the
/// same way the Python backends would; `TranscriptChunkerTests` pins the parity.
///
/// The decision to mirror in Swift rather than shell out to the Python primitive
/// is in TECH-SUM1-APPLE: the Apple path runs in-process on-device, so calling a
/// Python subprocess just to window a string would re-add the dependency the path
/// exists to avoid. The function is small and pinned by tests.
///
/// Coverage contract (same as Python): every word of the input appears in at
/// least one window. Windows end on whitespace (a word is never split at an end
/// boundary); consecutive windows overlap by `overlapChars`. Char counting is by
/// `Character`, which matches Python's code-point counting for ASCII / precomposed
/// text (the transcripts this serves).
enum TranscriptChunker {
    /// Prefix used when a carry summary is injected, identical to the Python
    /// primitive's `_CARRY_HEADER`.
    static let carryHeader = "Context from earlier in the meeting:"

    static func windows(
        _ transcript: String,
        maxChars: Int,
        overlapChars: Int = 200
    ) -> [TranscriptWindow] {
        precondition(maxChars > 0, "maxChars must be positive")
        let chars = Array(transcript)
        let n = chars.count
        if n == 0 { return [] }

        let overlap = max(0, min(overlapChars, maxChars - 1))

        var out: [TranscriptWindow] = []
        var start = 0
        var index = 0
        while start < n {
            var end = min(n, start + maxChars)
            if end < n, let snap = lastWhitespaceBreak(chars, end: end, start: start) {
                end = snap
            }
            let isLast = end >= n
            out.append(TranscriptWindow(
                index: index,
                text: String(chars[start..<end]),
                isFirst: index == 0,
                isLast: isLast
            ))
            if isLast { break }
            index += 1
            // Advance by the step, keeping the requested overlap. max() guards
            // the pathological case where end snapped back near start.
            start = max(start + 1, end - overlap)
        }
        return out
    }

    /// Compose the prompt for a window, prepending a carry summary when supplied.
    /// Mirrors `ChunkedWindow.prompt` on the Python side.
    static func prompt(for window: TranscriptWindow, carrySummary: String?) -> String {
        if let carry = carrySummary, !carry.isEmpty {
            return "\(carryHeader)\n\(carry)\n\n\(window.text)"
        }
        return window.text
    }

    private static func lastWhitespaceBreak(_ chars: [Character], end: Int, start: Int) -> Int? {
        var i = end - 1
        while i > start {
            if chars[i].isWhitespace { return i }
            i -= 1
        }
        return nil
    }
}
