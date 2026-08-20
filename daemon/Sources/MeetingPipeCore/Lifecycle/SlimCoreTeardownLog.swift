import Foundation

/// END9: the one line Teams writes when it tears a call down, parsed out of the same SlimCore log
/// family MIC8 already reads for mute.
///
/// Deliberately a thin type. Generation resolution, the byte-range tail and the UTC timestamp parse
/// all live in `SlimCoreMuteLog` and are reused verbatim rather than reimplemented, because every
/// one of them encodes a gotcha that cost the MIC8 spike real time: resolve by **family** and never
/// by mtime over the directory (the Electron shell log is always fresher than the media log that
/// carries the signal, and was 7th newest in its own directory when measured), carry a partial line
/// between ticks (SlimCore flushes mid-line routinely, and the live file's last line is usually
/// truncated), and treat the printed clock as UTC despite the local offset suffixed to it. Only the
/// line predicate differs, so only the line predicate is here.
public enum SlimCoreTeardownLog {

    /// The line form, verbatim as Teams writes it:
    /// `2026-08-20T09:57:40.907203+03:00 0x00000001fb809d80 <INFO> SlimCoreModule::WindowContentProtectionProvider: UnregisterCall 378`
    ///
    /// Anchored on the component-qualified name rather than a bare `UnregisterCall` token, for the
    /// reason `SlimCoreMuteLog.transitionMarker` is anchored on its whole message: Teams' shell log
    /// dumps a large ECS config blob whose feature-flag keys are matched by loose tokens, and a
    /// loose predicate turns those into phantom teardowns. A phantom teardown here is worse than a
    /// missed one, because it confirms an end that never happened, which is the bug being fixed.
    ///
    /// The neighbouring `SetWindowContentProtection` line is deliberately NOT parsed. It brackets
    /// the same DRM object on the *registration* side and fires at call start, so accepting it
    /// would read every call's beginning as its end.
    public static let teardownMarker = "SlimCoreModule::WindowContentProtectionProvider: UnregisterCall "

    /// The teardown instant, or nil for every line that is not one, which is nearly all of them.
    ///
    /// The call id after the marker is parsed only to reject a malformed line; it is not returned.
    /// Matching a provisional end to a specific id would need Teams' id to be knowable from our
    /// side, and it is not: the registration line is the only place it appears and we do not read
    /// it. Time proximity is the whole correlation, which is why the lookback exists.
    public static func parse(line: some StringProtocol) -> Date? {
        guard let marker = line.range(of: teardownMarker) else { return nil }
        let id = line[marker.upperBound...].prefix { !$0.isWhitespace }
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return SlimCoreMuteLog.parseTimestamp(line[line.startIndex..<marker.lowerBound])
    }

    /// The newest teardown in a chunk of appended bytes, plus whatever trailing partial line the
    /// next tick has to prepend.
    ///
    /// Newest rather than all of them: the oracle only ever asks "has a teardown happened since
    /// roughly now", so a tick that catches up on several calls at once needs only the last. The
    /// carry is not an optimization, it is correctness: without it a teardown flushed across two
    /// ticks is silently dropped and the recording is held to the cap for a call that really ended.
    public static func newestTeardown(
        inChunk chunk: Data, pending: Data
    ) -> (newest: Date?, carry: Data) {
        var buffer = pending
        buffer.append(chunk)
        guard let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) else {
            return (nil, buffer)
        }
        let complete = buffer[buffer.startIndex...lastNewline]
        let carry = Data(buffer[buffer.index(after: lastNewline)...])
        guard let text = String(data: Data(complete), encoding: .utf8) else { return (nil, carry) }

        var newest: Date?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let at = parse(line: line) else { continue }
            if newest == nil || at > newest! { newest = at }
        }
        return (newest, carry)
    }
}
