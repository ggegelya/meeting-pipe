import Foundation
import os

/// UX90: the one rule for "this meeting needs you because something failed", read by both the
/// Library (`buildMeeting`, `LibraryScope.needsYou`) and the status menu's failed row
/// (`unrecoveredFailureStems`). The menu used to skip every stem with a summary before it looked
/// at the error sidecar, so an all-sinks-failed publish (exit 3), a failed regenerate over an
/// existing summary and a partial publish all sat in the Library's Needs you rail while the
/// menu, the durable backup to a notification missed under Focus, said nothing.
extension MeetingStore {

    /// What the rule reads of a `<stem>.error.json`: its stage, whether it carries a structured
    /// failure, and when it was written.
    struct ErrorEvidence: Equatable, Sendable {
        var stage: PipelineFailureSidecar.Stage
        var structured: Bool
        var modified: Date
    }

    /// Whether a recorded failure is the meeting's current one. With no summary it always is.
    /// Beside a summary it is only when the failure is a publish failure (the summary is fine, the
    /// destination is not), or a structured failure newer than the summary (a failed regenerate).
    /// An older metadata-less sidecar beside a summary is the stale case: a legacy marker the
    /// summary superseded.
    static func errorIsCurrent(_ error: ErrorEvidence, summaryModified: Date?) -> Bool {
        guard let summaryModified else { return true }
        return error.stage == .publish || (error.structured && error.modified > summaryModified)
    }

    /// Whether a finished meeting's publish outcome wants the owner: nothing landed, only some
    /// sinks did, or the outcome was never recorded (PIPE34). A nil state is a local-only or
    /// never-published meeting, which nothing was meant to publish.
    static func publishNeedsAttention(_ state: String?) -> Bool {
        state == "none" || state == "partial" || state == PublishResult.unknownState
    }

    /// The content the menu's count reads, injected so `unrecoveredFailureStems` stays pure.
    /// Each is asked only for a stem that carries a summary and the matching file.
    struct FailureContentReaders: Sendable {
        /// The error sidecar's evidence, or nil when it does not decode.
        var errorEvidence: @Sendable (_ stem: String) -> ErrorEvidence?
        var summaryModified: @Sendable (_ stem: String) -> Date?
        /// `PublishResult.resolveState` over `publish.json` and `run.json`.
        var publishState: @Sendable (_ stem: String) -> String?

        /// The filename pass alone: a summary supersedes every error sidecar and no publish state
        /// is known. The launch auto-retry pass reads this way on purpose (its notice is "still
        /// has no summary", which a publish failure beside a summary is not).
        static let filenameOnly = FailureContentReaders(
            errorEvidence: { _ in nil }, summaryModified: { _ in nil }, publishState: { _ in nil }
        )
    }

    /// Readers over a directory, through `cache` so an unchanged file is decoded once.
    static func diskFailureReaders(in dir: URL, cache: FailureStateCache) -> FailureContentReaders {
        FailureContentReaders(
            errorEvidence: { stem in
                let url = PipelineFailureSidecar.url(forStem: stem, in: dir)
                return cache.value(for: url) { url, modified in
                    PipelineFailureSidecar.read(at: url).map {
                        .error(ErrorEvidence(stage: $0.stage, structured: $0.metadata != nil, modified: modified))
                    }
                }?.error
            },
            summaryModified: { stem in
                fileModified(dir.appendingPathComponent("\(stem).summary.json"))
            },
            publishState: { stem in
                let publish = dir.appendingPathComponent("\(stem).publish.json")
                if let state = cache.value(for: publish, decode: { _, _ in
                    PublishResult.load(stem: stem, in: dir).map { .publishState($0.state) }
                })?.publishState {
                    return state
                }
                let run = dir.appendingPathComponent("\(stem).run.json")
                return cache.value(for: run) { url, _ in
                    guard let data = try? Data(contentsOf: url),
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                    return .publishState(obj["publish_state"] as? String)
                }?.publishState
            }
        )
    }

    fileprivate static func fileModified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Decoded failure state per file, keyed by path and invalidated by mtime, so the menu's count
/// reads nothing twice for an unchanged library (UX90). A missing file costs one failed stat.
final class FailureStateCache: Sendable {
    static let shared = FailureStateCache()

    enum Value: Equatable, Sendable {
        case error(MeetingStore.ErrorEvidence)
        case publishState(String?)

        var error: MeetingStore.ErrorEvidence? {
            if case .error(let e) = self { return e }
            return nil
        }

        var publishState: String? {
            if case .publishState(let s) = self { return s }
            return nil
        }
    }

    private struct Entry: Sendable {
        var modified: Date
        var value: Value?
    }

    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])
    /// Decodes performed, for the test that pins "nothing read twice".
    private let decodes = OSAllocatedUnfairLock<Int>(initialState: 0)

    var decodeCount: Int { decodes.withLock { $0 } }

    /// The cached value for `url` while its mtime is unchanged, else `decode`'s. Nil when the file
    /// is absent or does not decode.
    func value(for url: URL, decode: (URL, Date) -> Value?) -> Value? {
        guard let modified = MeetingStore.fileModified(url) else {
            entries.withLock { _ = $0.removeValue(forKey: url.path) }
            return nil
        }
        if let hit = entries.withLock({ $0[url.path] }), hit.modified == modified { return hit.value }
        let value = decode(url, modified)
        decodes.withLock { $0 += 1 }
        entries.withLock { $0[url.path] = Entry(modified: modified, value: value) }
        return value
    }
}
