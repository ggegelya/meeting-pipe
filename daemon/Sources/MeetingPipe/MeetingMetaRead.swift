import Foundation

/// One read of a meeting's `<stem>.meta.json`, in three outcomes (SEC25).
///
/// The sidecar is the only home of a meeting's per-workflow NDA posture, its pinned backend and the
/// record-time `regulated_mode`. Every Swift reader used to fold "exists but could not be read or
/// parsed" into "absent", and absent means the global config, so a sidecar iCloud had made
/// dataless (EDEADLK, seen 2026-10-16) sent an NDA meeting's tokens to the pipeline child and hid
/// its Local only badge. `absent` stays "no workflow"; `unreadable` fails closed wherever a privacy
/// decision reads it, which is what `mp.workflow.load_meta` does on the Python side.
enum MeetingMetaRead {
    enum FailureKind: String {
        /// The bytes could not be read (an I/O error with the file present).
        case io
        /// The bytes are not a JSON object.
        case parse
    }

    case absent
    case loaded([String: Any])
    /// `domain` and `code` are the read error's, for the event log; a parse failure carries the
    /// JSONSerialization error's, or `MeetingMetaRead` / 0 for JSON that is not an object.
    case unreadable(kind: FailureKind, domain: String, code: Int)

    static func url(stem: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(stem).meta.json")
    }

    static func load(stem: String, in dir: URL) -> MeetingMetaRead {
        load(at: url(stem: stem, in: dir))
    }

    static func load(at url: URL) -> MeetingMetaRead {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileReadNoSuchFile.rawValue {
                return .absent
            }
            if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) {
                return .absent
            }
            return .unreadable(kind: .io, domain: ns.domain, code: ns.code)
        }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unreadable(kind: .parse, domain: "MeetingMetaRead", code: 0)
            }
            return .loaded(obj)
        } catch {
            let ns = error as NSError
            return .unreadable(kind: .parse, domain: ns.domain, code: ns.code)
        }
    }

    /// The parsed sidecar, only for `loaded`.
    var dictionary: [String: Any]? {
        if case .loaded(let obj) = self { return obj }
        return nil
    }

    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }

    /// Whether this meeting is clamped on-device and local-only. Fail-closed: a sidecar that
    /// exists and cannot be read may be hiding `workflow_nda_mode`, and unknown is not permission.
    var isZeroEgress: Bool {
        switch self {
        case .absent:
            return false
        case .loaded(let obj):
            return (obj["workflow_nda_mode"] as? Bool ?? false) || (obj["regulated_mode"] as? Bool ?? false)
        case .unreadable:
            return true
        }
    }
}

/// What the stop path does when the stop-time `<stem>.meta.json` write fails (SEC25). The write is
/// atomic, so a failure leaves no file, which the pipeline reads as "no workflow".
enum MetaWriteFailure {
    /// The failure-sidecar reason for a held meeting. It opens with a prefix
    /// `FailurePresentation.isValidation` knows, so the Library row says this instead of the
    /// generic retry copy; no slash in it for the same reason.
    static let heldReason = "This meeting's workflow settings could not be saved, so it was not processed. Retry once the disk has space."

    /// True when the job must wait for a sidecar: the workflow makes a privacy promise (NDA) or
    /// pins an on-device backend. Any other workflow's sidecar carries routing (context, sinks)
    /// but no privacy promise, and holding every meeting on a transient write error costs more
    /// than it protects. Global regulated mode is not lost on a failed write: the pipeline and
    /// `cloudSecretPolicy` both read it live from `config.toml`.
    static func holdsJob(workflow: Workflow?) -> Bool {
        guard let workflow else { return false }
        if workflow.flags.ndaMode { return true }
        switch workflow.effectiveBackend {
        case .local, .appleIntelligence: return true
        default: return false
        }
    }
}
