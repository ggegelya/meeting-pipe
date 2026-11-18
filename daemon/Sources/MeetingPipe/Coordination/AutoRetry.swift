import Foundation

/// PIPE41: one bounded automatic re-run of a summarize job that failed for a reason whose remedy is "retry".
///
/// A recorded meeting ends up summarized. One 120 s Anthropic timeout on 20261022-103101 left it with no
/// summary for 22 days across 5 launches, because nothing re-runs a failed job and the owner's workflows are
/// all pinned to a backend with no fallback. This file is the policy; the hooks are one line each in
/// `SinkDispatcher` (decided at failure time, where the job is known), `Coordinator` (the two triggers) and
/// `MeetingLibraryService.retryMeeting(stem:trigger:)` (the re-run itself, so PIPE18's coalescing, the
/// transcript reuse and the moved-into-NDA publish guard all apply unchanged).

/// Whether a failure may be re-run once without the owner asking.
enum AutoRetryEligibility {

    /// All of: a full run (not a re-transcribe or a Library re-run), recorded `.auto` (a BYO meeting is never
    /// re-run, REC2's no-auto-egress posture and the reason `reconcileStrandedJobs` marks rather than
    /// re-enqueues), failed in the `.pipeline` stage, and the pipeline's own failure metadata says the remedy
    /// is `retry`. `.interrupted`, `.transcribe`, `.launch`, `.memory` and `.publish` are never eligible, and
    /// a failure with no metadata is not eligible, because "retry" is the pipeline's claim and without it
    /// there is nothing to act on.
    static func isEligible(
        kind: ProcessingJobKind,
        summaryMode: SummaryMode,
        stage: PipelineFailureSidecar.Stage,
        metadata: FailureMetadata?
    ) -> Bool {
        guard case .full = kind, summaryMode == .auto, stage == .pipeline else { return false }
        return metadata?.remedy == "retry"
    }
}

/// The per-stem record that makes the bound hold. It cannot live in `<stem>.error.json`: `retryMeeting` clears
/// that file before it runs and a failed re-run writes a fresh one, so "already auto-retried" would be lost
/// exactly when it matters. It lives in `~/Library/Application Support/MeetingPipe` instead, outside the
/// library folder, so it is not a sidecar any stem scan, stranded-job detector or sidecar inventory sees.
///
/// Two states: `pending` (a failure was marked eligible and its re-run has not started) and `spent` (the one
/// re-run has been started; never re-armed, whatever it does, and across relaunches). Main-thread only.
final class AutoRetryStore {

    enum State: String, Codable { case pending, spent }

    struct Entry: Codable, Equatable {
        var state: State
        /// The failure sidecar's `ts` this entry was marked for, so the pickup can tell the failure it was
        /// decided for from a later one.
        var failedAt: String
    }

    private let url: URL
    private(set) var entries: [String: Entry]

    /// The store in Application Support, or `url` for a test.
    init(url: URL? = nil) {
        let resolved: URL
        if let url {
            resolved = url
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MeetingPipe", isDirectory: true)
            resolved = dir.appendingPathComponent("auto_retry.json")
        }
        self.url = resolved
        try? FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: resolved),
           let file = try? JSONDecoder().decode(File.self, from: data), file.schemaVersion == 1 {
            entries = file.entries
        } else {
            entries = [:]
            if FileManager.default.fileExists(atPath: resolved.path) {
                // Unreadable, not absent: keep it aside rather than let the next save overwrite the spent
                // entries that make the bound hold.
                Log.failure(category: "coordinator", action: "auto_retry_store_unreadable", reason: "unreadable, moved aside", attributes: [
                    "file": resolved.lastPathComponent,
                ])
                let aside = resolved.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: resolved, to: aside)
            }
        }
    }

    private struct File: Codable {
        var schemaVersion = 1
        var entries: [String: Entry]
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", entries }
    }

    /// Record a failure as waiting for its one re-run. False, and nothing written, when the stem already has
    /// an entry in either state: a `pending` one is the same failure, and a `spent` one is the bound, which
    /// is how a failure produced by the automatic re-run (through either of `retryMeeting`'s paths) is never
    /// itself marked.
    @discardableResult
    func markEligible(stem: String, failedAt: String) -> Bool {
        guard entries[stem] == nil else { return false }
        entries[stem] = Entry(state: .pending, failedAt: failedAt)
        save()
        return true
    }

    /// Pending stems, oldest failure first.
    func pending() -> [(stem: String, failedAt: String)] {
        entries.compactMap { $0.value.state == .pending ? (stem: $0.key, failedAt: $0.value.failedAt) : nil }
            .sorted { ($0.failedAt, $0.stem) < ($1.failedAt, $1.stem) }
    }

    func isPending(stem: String) -> Bool { entries[stem]?.state == .pending }

    /// True when the failure on disk (`failureTs`) is the one this stem's spent re-run was started for: on the
    /// summary path its error sidecar stays in place while the re-run is in flight, and a re-run that fails
    /// rewrites the sidecar with a new `ts`, so an equal `ts` means the re-run is still running or never started.
    func retryIsForFailure(stem: String, failureTs: String) -> Bool {
        guard let entry = entries[stem] else { return false }
        return entry.state == .spent && entry.failedAt == failureTs
    }

    /// Spend the stem's one re-run. Persisted before the caller starts anything, so a crash mid-run cannot
    /// buy a second attempt. False when there is nothing pending to spend.
    func claim(stem: String) -> Bool {
        guard var entry = entries[stem], entry.state == .pending else { return false }
        entry.state = .spent
        entries[stem] = entry
        save()
        return true
    }

    /// Forget a pending entry whose failure is gone (the owner retried it, or it succeeded). A `spent` entry is
    /// never dropped here: it is the bound.
    func dropPending(stem: String) {
        guard entries[stem]?.state == .pending else { return }
        entries.removeValue(forKey: stem)
        save()
    }

    /// Drop every entry whose meeting no longer has any file in the library, so a deleted meeting does not
    /// leave a record behind forever.
    func prune(keepingStems stems: Set<String>) {
        let gone = entries.keys.filter { !stems.contains($0) }
        guard !gone.isEmpty else { return }
        for stem in gone { entries.removeValue(forKey: stem) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(File(entries: entries)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The pickup: runs every pending re-run, once, through `retryMeeting`.
enum AutoRetryPass {

    /// Why a pending entry was dropped instead of run.
    enum Skip: String {
        case failureGone = "failure_gone"      // the owner retried it, deleted it, or it succeeded meanwhile
        case notPipelineStage = "stage_changed"
        case differentFailure = "failure_changed"
        case summaryExists = "summary_exists"
        case refused = "refused"               // retryMeeting declined (no audio, held back, meta unwritable)
    }

    /// For each pending stem, oldest first: re-validate that the failure it was decided for is still the one
    /// on disk (a `.pipeline` failure with the recorded `ts` and no summary), then spend the entry and call
    /// `retry`. Returns the stems whose re-run was started. Spent before `retry` runs, so the bound holds
    /// whatever the re-run does, including a crash.
    @discardableResult
    static func run(
        store: AutoRetryStore,
        readFailure: (String) -> PipelineFailureSidecar.Failure?,
        hasSummary: (String) -> Bool,
        retry: (String) -> Result<Void, Error>,
        onSkip: (String, Skip) -> Void = { _, _ in }
    ) -> [String] {
        var started: [String] = []
        for (stem, failedAt) in store.pending() {
            guard let failure = readFailure(stem) else {
                store.dropPending(stem: stem); onSkip(stem, .failureGone); continue
            }
            guard failure.stage == .pipeline else {
                store.dropPending(stem: stem); onSkip(stem, .notPipelineStage); continue
            }
            guard failure.ts == failedAt else {
                store.dropPending(stem: stem); onSkip(stem, .differentFailure); continue
            }
            guard !hasSummary(stem) else {
                store.dropPending(stem: stem); onSkip(stem, .summaryExists); continue
            }
            guard store.claim(stem: stem) else { continue }
            // A refused re-run is spent all the same (the bound is one attempt), but it is not "started": the
            // failure is still there, so the launch notice must still count it, and it is logged.
            if case .failure = retry(stem) { onSkip(stem, .refused); continue }
            started.append(stem)
        }
        return started
    }

    /// What the launch pass sees on disk, read off main by the caller (PERF24: `raw/` is about seven entries per
    /// meeting and may sync to iCloud). `names` is nil when the listing itself failed.
    struct LaunchSnapshot {
        var names: [String]?
        var failures: [(stem: String, ts: String)]
    }

    /// The launch pass as one unit: forget entries for meetings with no files left (never when the listing
    /// failed, which would read as every meeting gone and wipe the bound), run the pickup, then work out the
    /// stems for the once-per-launch notice. A failure is left out of the notice while its re-run is pending or
    /// in flight, however early in this launch the re-run started.
    static func launch(
        store: AutoRetryStore,
        snapshot: LaunchSnapshot,
        now: Date,
        readFailure: (String) -> PipelineFailureSidecar.Failure?,
        hasSummary: (String) -> Bool,
        retry: (String) -> Result<Void, Error>,
        onSkip: (String, Skip) -> Void = { _, _ in }
    ) -> (started: [String], unresolved: [String]) {
        if let names = snapshot.names {
            store.prune(keepingStems: Set(names.compactMap { name in
                name.firstIndex(of: ".").map { String(name[..<$0]) }
            }))
        }
        let started = run(store: store, readFailure: readFailure, hasSummary: hasSummary, retry: retry, onSkip: onSkip)
        let waiting = Set(store.pending().map(\.stem))
        let inFlight = Set(snapshot.failures.filter { store.retryIsForFailure(stem: $0.stem, failureTs: $0.ts) }.map(\.stem))
        let unresolved = UnresolvedFailureNotice.stems(
            failures: snapshot.failures, excluding: waiting.union(inFlight), now: now
        )
        return (started, unresolved)
    }
}

/// The launch-time notice for a failure nothing is going to re-run (PIPE41 item 4): one notification, naming
/// the count, once per launch. The status menu's failed row stays; it is only visible when the menu is opened.
enum UnresolvedFailureNotice {

    /// A failure younger than this is still the owner's to notice and retry.
    static let minAge: TimeInterval = 24 * 3600

    /// Stems whose failure is at least `minAge` old, oldest first, leaving out `excluding` (a pending re-run,
    /// or one the launch pass has just started: on the summary path its error sidecar still exists while the
    /// run is in flight, and a notice for a failure that is being retried would be wrong). A stem with no
    /// readable failure `ts` (an age-inferred stall) is left out, since it has no failure time to age.
    static func stems(
        failures: [(stem: String, ts: String)],
        excluding: Set<String>,
        now: Date
    ) -> [String] {
        let parse = ISO8601DateFormatter()
        parse.formatOptions = [.withInternetDateTime]
        return failures
            .filter { !excluding.contains($0.stem) }
            .compactMap { f -> (String, Date)? in
                guard let date = parse.date(from: f.ts), now.timeIntervalSince(date) >= minAge else { return nil }
                return (f.stem, date)
            }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map { $0.0 }
    }
}

/// When the launch pass runs. After `reconcileStrandedJobs` and a short wait, because a launch-at-login pass
/// can run before the network is up and one retry spent on a not-yet-connected Mac is a retry wasted. A
/// successful job landing first runs the pass sooner: whichever comes first (PIPE41 item 3).
enum AutoRetryTiming {
    static let launchDelay: TimeInterval = 90
}
