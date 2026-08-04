import Foundation

/// MIC8: Teams' SlimCore media-stack log read as a mute oracle. Pure parsing plus the generation resolver and the byte-range tail; `LogMuteAdapter` is the host that schedules it and feeds `MicGate`. Everything here is a function of its arguments (or of the directory it is handed), so the whole read path is testable against fixture lines and a temp directory, with no Teams and no meeting.
public enum SlimCoreMuteLog {

    /// One parsed transition line: when Teams recorded the toggle (UTC, see `parseTimestamp`) and the state it moved to.
    public struct Reading: Equatable {
        public let at: Date
        public let muted: Bool

        public init(at: Date, muted: Bool) {
            self.at = at
            self.muted = muted
        }
    }

    /// The one line form MIC8 measured, verbatim:
    /// `2026-08-03T07:30:24.277723+03:00 0x00000001f2439d80 <INFO> AirPodsService: Input mute event received: mute`
    ///
    /// `AirPodsService` is a misnomer: the component logs the client-side transmit
    /// gate on the built-in mic too (the spike checked the resolved input device on
    /// every day carrying mute lines). The two neighbouring forms (`SetMuteState ...
    /// cause_id`, `InputMuteStateChangeNotification`) are deliberately NOT parsed:
    /// this is the form the correlation measured (594 transitions over 9 generations,
    /// re-confirmed at 381 over 6 on 2026-08-04), the three do not fire 1:1, and a
    /// second accepted form would be an unmeasured oracle. If Microsoft renames this
    /// line the AX read carries it, which is the whole point of fusing rather than
    /// superseding.
    public static let transitionMarker = "AirPodsService: Input mute event received: "

    /// Parse one log line. Returns nil for every line that is not a mute transition,
    /// which is nearly all of them.
    ///
    /// Anchored on the whole message rather than a `mute` token on purpose: Teams'
    /// *shell* log dumps a ~100 KB ECS config blob every hour whose feature-flag keys
    /// include `hfpOsUnmuteFixEnabled`, and a loose token match reads those as hits
    /// (the defect that would have confirmed the spike's false close).
    public static func parse(line: String) -> Reading? {
        guard let marker = line.range(of: transitionMarker) else { return nil }
        let token = line[marker.upperBound...].prefix { !$0.isWhitespace }.lowercased()
        let muted: Bool
        switch token {
        case "mute": muted = true
        case "unmute": muted = false
        default: return nil
        }
        guard let at = parseTimestamp(line[line.startIndex..<marker.lowerBound]) else { return nil }
        return Reading(at: at, muted: muted)
    }

    /// The leading stamp of a SlimCore line, as a UTC `Date`.
    ///
    /// **SlimCore prints UTC and then suffixes the machine's local offset**, so
    /// `2026-08-03T07:30:24.277723+03:00` happened at 07:30:24 **UTC**, not at
    /// 04:30:24 UTC. Measured: the generation created at 20:32:53 local carries
    /// `17:32:53+03:00` on its first line. So we parse the naive clock reading and
    /// discard the offset. Getting this wrong is silently wrong by the local offset
    /// and correct-looking on a UTC machine, which is the worst kind of wrong;
    /// `mic8_log_correlation.py` does the same thing for the same reason.
    public static func parseTimestamp(_ text: some StringProtocol) -> Date? {
        let stamp = text.prefix { !$0.isWhitespace }
        guard let tIndex = stamp.firstIndex(of: "T") else { return nil }
        let datePart = stamp[stamp.startIndex..<tIndex]
        // The offset sign can only appear after the `T`, so cutting here cannot
        // trip over the date's own separators.
        let clockPart = stamp[stamp.index(after: tIndex)...]
            .prefix { $0 != "+" && $0 != "-" && $0 != "Z" && $0 != "z" }
        let date = datePart.split(separator: "-")
        let clock = clockPart.split(separator: ":")
        guard date.count == 3, clock.count == 3,
              let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
              let hour = Int(clock[0]), let minute = Int(clock[1]) else { return nil }
        let secondField = clock[2].split(separator: ".", maxSplits: 1)
        guard let second = Int(secondField[0]) else { return nil }
        var fraction: TimeInterval = 0
        if secondField.count == 2, let digits = Double(secondField[1]) {
            fraction = digits / pow(10.0, Double(secondField[1].count))
        }
        let components = DateComponents(
            calendar: utcCalendar, timeZone: utcCalendar.timeZone,
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        guard let whole = components.date else { return nil }
        return whole.addingTimeInterval(fraction)
    }

    // MARK: - Generation resolution

    /// One candidate log file: the URL plus the modification date the resolver ranks on.
    public struct Generation: Equatable {
        public let url: URL
        public let modified: Date

        public init(url: URL, modified: Date) {
            self.url = url
            self.modified = modified
        }
    }

    /// Every generation of one log **family** in `directory`, newest last.
    ///
    /// Filtering by family and never taking a flat newest-N over the directory is
    /// load-bearing, and is the defect that hid this signal for ten days. Teams'
    /// families rotate at wildly different rates: `MSTeams_*` (the Electron shell)
    /// and `TeamsSwitcher.log_*` roll every ~2 MB, hourly on a working day, while
    /// `MSTeamsNM_SlimCore_*` rolls only when Teams restarts, roughly weekly. The
    /// shell log therefore always looks fresher than the media log that carries the
    /// signal: measured 2026-08-04, the live SlimCore generation was 7th newest in
    /// its own directory.
    public static func generations(in directory: URL, family: String) -> [Generation] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let found: [Generation] = names.compactMap { name in
            guard name.hasPrefix(family), name.hasSuffix(".log") else { return nil }
            let url = directory.appendingPathComponent(name)
            let attrs = try? manager.attributesOfItem(atPath: url.path)
            let modified = attrs?[.modificationDate] as? Date
            return Generation(url: url, modified: modified ?? .distantPast)
        }
        return found.sorted { ($0.modified, $0.url.lastPathComponent) < ($1.modified, $1.url.lastPathComponent) }
    }

    /// The newest generation of one family, or nil when the family is absent (Teams
    /// never ran on this Mac, or the log directory moved). Absent resolves to no
    /// reading at all, never to unmuted.
    public static func newest(in directory: URL, family: String) -> URL? {
        generations(in: directory, family: family).last?.url
    }

    // MARK: - Tail

    /// One tick's read: which generation we are on, how far into it we have read, and the bytes appended since last time.
    public struct Tail: Equatable {
        public let url: URL?
        public let offset: UInt64
        public let chunk: Data
        /// True when this tick moved to a different generation than the caller was on
        /// (including the first resolution). Rotation is per Teams restart, so the
        /// adapter re-resolves rather than holding a file handle open.
        public let rotated: Bool

        public init(url: URL?, offset: UInt64, chunk: Data, rotated: Bool) {
            self.url = url
            self.offset = offset
            self.chunk = chunk
            self.rotated = rotated
        }
    }

    /// Resolve the newest generation and read whatever was appended past `offset`.
    ///
    /// `skipHistory` is the caller's first resolution: we start at end-of-file so a
    /// meeting does not replay a week of past toggles. A rotation *after* that starts
    /// at 0, because a generation created mid-meeting is newer than the meeting.
    /// Blocking I/O, so `LogMuteAdapter` runs it off the main queue.
    public static func tail(
        directory: URL, family: String, current: URL?, offset: UInt64, skipHistory: Bool
    ) -> Tail {
        guard let newest = newest(in: directory, family: family) else {
            return Tail(url: nil, offset: 0, chunk: Data(), rotated: current != nil)
        }
        let rotated = newest != current
        let size = fileSize(of: newest) ?? 0
        var start = offset
        if rotated {
            start = skipHistory ? size : 0
        }
        // A file that shrank was truncated or replaced in place; re-read it whole
        // rather than seeking past its end.
        if size < start { start = 0 }
        guard size > start, let handle = try? FileHandle(forReadingFrom: newest) else {
            return Tail(url: newest, offset: start, chunk: Data(), rotated: rotated)
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else {
            return Tail(url: newest, offset: start, chunk: Data(), rotated: rotated)
        }
        return Tail(url: newest, offset: start + UInt64(data.count), chunk: data, rotated: rotated)
    }

    private static func fileSize(of url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()
}
