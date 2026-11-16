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
    /// One directory listing, plus why it failed when it did.
    ///
    /// END10 item 4: the `try?` this replaces collapsed a TCC refusal, a transient I/O error and a
    /// genuinely absent family into the same empty array, which is why 323 `log_mute_source_missing`
    /// rows between 2026-08-05 and 2026-08-21 say nothing at all about their own cause. The failure
    /// travels out to a host that owns an `EventLog` rather than being logged here, because this
    /// target's rule is that decisions are pure and the host does the reporting.
    public struct Listing {
        public let generations: [Generation]
        /// Nil when the directory listed. Otherwise "<domain> <code>: <description>".
        public let failure: String?

        public init(generations: [Generation], failure: String?) {
            self.generations = generations
            self.failure = failure
        }
    }

    /// The file-system calls the read path makes, as a seam (END16), so a test can count them.
    ///
    /// `stat` is the `stat(2)` syscall, not `FileManager.attributesOfItem` or `URLResourceValues`.
    /// `attributesOfItem` also reads every extended attribute (a 60 s idle `sample` on 2026-10-23 put
    /// 7,224 samples of this watcher in `getxattr` against Teams' Group Container), and an `NSURL`'s
    /// resource values are cached until a run loop turns, which a GCD worker never does, so a tail
    /// stat'ing one stored URL could read a frozen size forever.
    public struct FileSystem {
        public var names: (String) throws -> [String]
        public var stat: (String) -> (size: UInt64, modified: Date)?
        public var read: (String, UInt64) -> Data?

        public init(
            names: @escaping (String) throws -> [String],
            stat: @escaping (String) -> (size: UInt64, modified: Date)?,
            read: @escaping (String, UInt64) -> Data?
        ) {
            self.names = names
            self.stat = stat
            self.read = read
        }

        public static let real = FileSystem(
            names: { try FileManager.default.contentsOfDirectory(atPath: $0) },
            stat: { posixStat($0) },
            read: { path, offset in
                guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
                defer { try? handle.close() }
                guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
                return try? handle.readToEnd()
            }
        )
    }

    /// `parseName` is a seam for the counting test (END16): each name is parsed once per listing,
    /// not at every comparison the sort makes.
    public static func listing(
        in directory: URL,
        family: String,
        fileSystem: FileSystem = .real,
        parseName: (String) -> Date? = SlimCoreMuteLog.nameTimestamp
    ) -> Listing {
        let names: [String]
        do {
            names = try fileSystem.names(directory.path)
        } catch let error as NSError {
            return Listing(
                generations: [],
                failure: "\(error.domain) \(error.code): \(error.localizedDescription)"
            )
        }
        let keyed: [(generation: Generation, key: (Date, String))] = names.compactMap { name in
            guard name.hasPrefix(family), name.hasSuffix(".log") else { return nil }
            let url = directory.appendingPathComponent(name)
            let modified = fileSystem.stat(url.path)?.modified ?? .distantPast
            return (Generation(url: url, modified: modified), (parseName(name) ?? modified, name))
        }
        return Listing(generations: keyed.sorted { $0.key < $1.key }.map(\.generation), failure: nil)
    }

    public static func generations(in directory: URL, family: String) -> [Generation] {
        listing(in: directory, family: family).generations
    }

    /// END10 item 7: rank by the timestamp the generation's own name carries, falling back to mtime
    /// only when the name does not parse. The names encode creation order and never move; mtime is
    /// the field that does, so ranking by it lets a touched older file outrank the live generation.
    static func generationPrecedes(_ lhs: Generation, _ rhs: Generation) -> Bool {
        let left = (nameTimestamp(lhs.url.lastPathComponent) ?? lhs.modified, lhs.url.lastPathComponent)
        let right = (nameTimestamp(rhs.url.lastPathComponent) ?? rhs.modified, rhs.url.lastPathComponent)
        return left < right
    }

    /// `MSTeamsNM_SlimCore_2026-08-13_18-06-05.23.log` -> that instant. Only the ordering matters,
    /// so reading the wall-clock stamp in a fixed zone is enough; it is never compared to a real clock.
    public static func nameTimestamp(_ name: String) -> Date? {
        guard let match = name.range(
            of: "[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}",
            options: .regularExpression
        ) else { return nil }
        return nameFormatter.date(from: String(name[match]))
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// The newest generation of one family, or nil when the family is absent (Teams
    /// never ran on this Mac, or the log directory moved). Absent resolves to no
    /// reading at all, never to unmuted.
    public static func newest(in directory: URL, family: String) -> URL? {
        generations(in: directory, family: family).last?.url
    }

    // MARK: - Tail

    /// One tick's read: which generation we are on, how far into it we have read, and the bytes appended since last time.
    public struct Tail: Equatable, Sendable {
        public let url: URL?
        public let offset: UInt64
        public let chunk: Data
        /// True when this tick moved to a different generation than the caller was on
        /// (including the first resolution). Rotation is per Teams restart, so the
        /// adapter re-resolves rather than holding a file handle open.
        public let rotated: Bool
        /// mtime of the generation this tick resolved, for END10's freshness check: a generation
        /// last written before the recording started is evidence the log is not being written,
        /// which is a different thing from evidence that no call ended.
        public let modified: Date?
        /// Non-nil when the directory could not be listed at all (END10 item 4). Since END16 it can
        /// be set beside a non-nil `url`: a failed listing still reads the generation already being
        /// tailed, so a flap costs no bytes.
        public let resolveFailure: String?
        /// Size of the generation at this tick's stat, nil when nothing resolved (END16).
        public let fileSize: UInt64?

        public init(
            url: URL?, offset: UInt64, chunk: Data, rotated: Bool,
            modified: Date? = nil, resolveFailure: String? = nil, fileSize: UInt64? = nil
        ) {
            self.url = url
            self.offset = offset
            self.chunk = chunk
            self.rotated = rotated
            self.modified = modified
            self.resolveFailure = resolveFailure
            self.fileSize = fileSize
        }
    }

    /// Resolve the newest generation and read whatever was appended past `offset`.
    ///
    /// `skipHistory` is the caller's first resolution: we start at end-of-file so a
    /// meeting does not replay a week of past toggles. A rotation *after* that starts
    /// at 0, because a generation created mid-meeting is newer than the meeting.
    /// Blocking I/O, so `LogMuteAdapter` runs it off the main queue.
    ///
    /// END16: `relist: false` with a `current` is the cheap tick, one `stat` of the file being tailed
    /// and no directory listing; it falls back to a listing when that stat fails. A listing that
    /// fails while `current` is known still reads `current`, reporting the failure beside it, and a
    /// tick that resolves nothing reports `rotated: false`, so the caller keeps its position and
    /// its carried half line (F160: the old path dropped both and resumed at end of file).
    public static func tail(
        directory: URL, family: String, current: URL?, offset: UInt64, skipHistory: Bool,
        relist: Bool = true, fileSystem: FileSystem = .real
    ) -> Tail {
        if !relist, let current, let info = fileSystem.stat(current.path) {
            return read(current, size: info.size, modified: info.modified, from: offset,
                        rotated: false, skipHistory: skipHistory, fileSystem: fileSystem)
        }
        let listed = listing(in: directory, family: family, fileSystem: fileSystem)
        guard let generation = listed.generations.last else {
            if listed.failure != nil, let current, let info = fileSystem.stat(current.path) {
                return read(current, size: info.size, modified: info.modified, from: offset,
                            rotated: false, skipHistory: skipHistory, fileSystem: fileSystem,
                            resolveFailure: listed.failure)
            }
            return Tail(
                url: nil, offset: offset, chunk: Data(), rotated: false,
                modified: nil, resolveFailure: listed.failure
            )
        }
        let newest = generation.url
        guard let size = fileSystem.stat(newest.path)?.size else {
            // Listed but not stat-able: resolve nothing this tick rather than read it as empty,
            // which would reset the offset to 0 and re-read the whole file next time.
            return Tail(url: nil, offset: offset, chunk: Data(), rotated: false,
                        modified: nil, resolveFailure: "stat failed for the newest generation")
        }
        return read(newest, size: size, modified: generation.modified, from: offset,
                    rotated: newest != current, skipHistory: skipHistory, fileSystem: fileSystem)
    }

    private static func read(
        _ url: URL, size: UInt64, modified: Date, from offset: UInt64, rotated: Bool,
        skipHistory: Bool, fileSystem: FileSystem, resolveFailure: String? = nil
    ) -> Tail {
        var start = offset
        if rotated {
            start = skipHistory ? size : 0
        }
        // A file that shrank was truncated or replaced in place; re-read it whole
        // rather than seeking past its end.
        if size < start { start = 0 }
        guard size > start, let data = fileSystem.read(url.path, start), !data.isEmpty else {
            return Tail(url: url, offset: start, chunk: Data(), rotated: rotated, modified: modified,
                        resolveFailure: resolveFailure, fileSize: size)
        }
        return Tail(
            url: url, offset: start + UInt64(data.count), chunk: data,
            rotated: rotated, modified: modified, resolveFailure: resolveFailure, fileSize: size
        )
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()
}

/// `stat(2)` for size and mtime. File-level so the `FileSystem.stat` property cannot shadow it.
private func posixStat(_ path: String) -> (size: UInt64, modified: Date)? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    let seconds = TimeInterval(info.st_mtimespec.tv_sec)
        + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    return (UInt64(info.st_size), Date(timeIntervalSince1970: seconds))
}
