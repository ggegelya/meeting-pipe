import Foundation

/// One read of a user-data store, telling missing from broken (STOR9).
///
/// Every Swift store used to read a file it could not open or parse as empty, and its writers then
/// saved that empty state over the owner's data. The rule now, mirroring Python's
/// `storage.load_json_object` / `StoreUnreadable`: **missing is empty, unreadable is not.**
/// Display-only callers keep the empty value (`orEmpty`); only writers branch, through
/// `StoreGuard.valueForWrite`.
enum StoreLoad<T> {
    /// No file (ENOENT): the store is empty, and a writer may create it.
    case missing
    case loaded(T)
    /// The bytes are there and are not this store's shape (not JSON, a non-object top level, a TOML
    /// syntax error). A machine-written store quarantines it before its first write.
    case unparseable(Error)
    /// An I/O error other than not-found (EACCES, EDEADLK for an evicted file, ...). Retryable, so a
    /// writer refuses: moving a valid file it merely could not read right now would lose it.
    case unreadable(Error)

    /// Read `url` and decode it. `decode` throws for a wrong shape, which is `unparseable`.
    static func read(_ url: URL, decode: (Data) throws -> T) -> StoreLoad<T> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return LibraryRootState.posixCode(of: error) == ENOENT ? .missing : .unreadable(error)
        }
        do {
            return .loaded(try decode(data))
        } catch {
            return .unparseable(error)
        }
    }

    /// The value a display-only reader shows: empty for every case but `loaded`.
    func orEmpty(_ empty: T) -> T {
        if case .loaded(let value) = self { return value }
        return empty
    }
}

/// A wrong-shaped store (valid JSON whose top level is not the object the store writes).
struct StoreShapeError: LocalizedError {
    let why: String
    var errorDescription: String? { why }
}

/// A writer that refused because its store could not be read (STOR9 item 2).
struct StoreRefusal: LocalizedError, Equatable {
    let file: String
    let reason: String
    var errorDescription: String? { "Couldn't read \(file): \(reason); nothing was changed." }
}

/// The writer side of `StoreLoad`, and the one place a refusal or quarantine is recorded.
enum StoreGuard {

    /// Where a store lives, for the event (never the path itself, SEC38): `library` for the
    /// per-meeting sidecars in `raw/`, `config` for `~/.config/meeting-pipe`, `app_support` for
    /// `~/Library/Application Support/MeetingPipe`. Python's `path_kind` uses the same words.
    enum PathKind: String { case library, config, appSupport = "app_support" }

    /// The value a writer starts from. `missing` is `empty`; `unparseable` moves the file aside as
    /// `<name>.corrupt-<UTC yyyyMMdd-HHmmss>` first, then starts from `empty`; `unreadable` throws
    /// `StoreRefusal` and changes nothing.
    static func valueForWrite<T>(
        _ load: StoreLoad<T>, empty: T, url: URL, store: String, pathKind: PathKind
    ) throws -> T {
        switch load {
        case .loaded(let value):
            return value
        case .missing:
            return empty
        case .unreadable(let error):
            throw refuse(url: url, error: error, store: store, pathKind: pathKind)
        case .unparseable(let error):
            try quarantineForWrite(url: url, error: error, store: store, pathKind: pathKind)
            return empty
        }
    }

    /// A per-meeting overlay an operation will re-anchor (a re-transcribe): both broken kinds refuse,
    /// since quarantining would drop the owner's edits from the carry and leave them on the wrong
    /// lines. Missing is empty.
    static func valueForCarry<T>(_ load: StoreLoad<T>, empty: T, url: URL, store: String) throws -> T {
        switch load {
        case .loaded(let value): return value
        case .missing: return empty
        case .unreadable(let error): throw refuse(url: url, error: error, store: store, pathKind: .library)
        case .unparseable(let error):
            report(store: store, pathKind: .library, reason: "unparseable", outcome: "refused", error: error)
            throw StoreRefusal(file: url.lastPathComponent, reason: "it is not valid JSON")
        }
    }

    /// A store loaded once at launch whose load failed (STOR9), before its next mutation: read the
    /// file again and continue from what that says. A file that reads now is adopted (the failure
    /// was retryable, and the in-memory list is the empty fallback, not the owner's data); an
    /// unparseable one is quarantined and the store starts from `empty`; one still unreadable is
    /// refused. Nil means refuse the mutation.
    static func recoverForWrite<T>(
        reread: StoreLoad<T>, empty: T, url: URL, store: String, pathKind: PathKind
    ) -> T? {
        do {
            return try valueForWrite(reread, empty: empty, url: url, store: store, pathKind: pathKind)
        } catch {
            // These stores' mutators return quietly, so the refusal is said here; a throwing
            // writer's caller says it instead, and one notice per refusal is enough.
            StoreNotice.post(error.localizedDescription)
            return nil
        }
    }

    /// Record and return the refusal for an unreadable store.
    static func refuse(url: URL, error: Error, store: String, pathKind: PathKind) -> StoreRefusal {
        let reason = String(cString: strerror(LibraryRootState.posixCode(of: error)))
        report(store: store, pathKind: pathKind, reason: errnoName(of: error), outcome: "refused", error: error)
        return StoreRefusal(file: url.lastPathComponent, reason: reason)
    }

    /// Move an unparseable store aside and tell the owner where it went. Throws (and changes
    /// nothing) when the move itself fails, since writing over it then would lose it.
    static func quarantineForWrite(url: URL, error: Error, store: String, pathKind: PathKind) throws {
        let dest: URL
        do {
            dest = try quarantine(url)
        } catch let moveError {
            throw refuse(url: url, error: moveError, store: store, pathKind: pathKind)
        }
        report(store: store, pathKind: pathKind, reason: "unparseable", outcome: "quarantined", error: error)
        StoreNotice.post(
            "\(url.lastPathComponent) could not be read, so it was moved to \(dest.lastPathComponent) beside it and a new one was started."
        )
    }

    /// `<name>.corrupt-<UTC yyyyMMdd-HHmmss>` beside `url`, with `-1`, `-2`, ... on a collision:
    /// Python's `storage.quarantine`, byte for byte in the name.
    static func quarantine(_ url: URL, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let fm = FileManager.default
        var dest = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)-\(n)")
            n += 1
        }
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    /// `store_unreadable` with Python's attributes (`store`, `path_kind`, `reason`, `outcome`), under
    /// `library` for the per-meeting sidecars and `coordinator` for the rest. `describe: false`: a
    /// file error's text names the path.
    static func report(store: String, pathKind: PathKind, reason: String, outcome: String, error: Error) {
        Log.failure(
            category: pathKind == .library ? "library" : "coordinator",
            action: "store_unreadable",
            error: error,
            attributes: ["store": store, "path_kind": pathKind.rawValue, "reason": reason, "outcome": outcome],
            describe: false
        )
    }

    /// Python's `reason` for an I/O failure: the errno's symbolic name (`EACCES`).
    static func errnoName(of error: Error) -> String {
        let code = LibraryRootState.posixCode(of: error)
        let names: [Int32: String] = [
            EPERM: "EPERM", ENOENT: "ENOENT", EIO: "EIO", EACCES: "EACCES", EDEADLK: "EDEADLK",
            ENOTDIR: "ENOTDIR", EISDIR: "EISDIR", ENOSPC: "ENOSPC", EROFS: "EROFS", EBUSY: "EBUSY",
        ]
        return names[code] ?? "errno\(code)"
    }
}

/// What a refusal or quarantine says to the owner (STOR9 item 3: "the surface that triggered it
/// says where the old file went"). The Coordinator points it at the notifier; a headless run only
/// logs. Also the landing point for `mp`'s own store notices, through `MP_NOTICE_FILE`.
enum StoreNotice {
    @MainActor private static var handler: ((String) -> Void)?

    @MainActor static func install(_ newHandler: ((String) -> Void)?) {
        handler = newHandler
    }

    /// Any thread. Logged at once; shown on main.
    static func post(_ message: String) {
        guard !message.isEmpty else { return }
        Log.writeLine("daemon", "store notice: \(message)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler?(message) }
        }
    }
}
