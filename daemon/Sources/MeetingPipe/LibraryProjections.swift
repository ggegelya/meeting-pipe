import Foundation

/// The Library's three cross-meeting projections, Facts, People and Meeting time, each as one
/// latest-wins pass plus the per-stem cache that pass reads through (PERF23).
///
/// Owned by `LibraryWindowModel` rather than by the views, because the Library's centre column is an
/// `if / else` on the rail scope: every rail switch destroys `PeopleView` and `StatsView` and their
/// `@State` with them. Meeting time's talk cache lived there and died on every switch, so each visit
/// re-parsed the library's transcripts (about 80 MB at the work library). The views still hold what
/// they render; this holds what is expensive to recompute and the pass that recomputes it.
///
/// Each `reload` hands the newest complete result to `apply` and never an older one, and a cancelled
/// or superseded pass still folds what it measured into the cache, so a revision burst during a cold
/// pass makes progress instead of restarting from nothing on every bump.
@MainActor
final class LibraryProjections {
    let facts: FactsProjection
    let people: PeopleProjection
    let stats: StatsProjection

    nonisolated init(
        facts: FactsProjection = FactsProjection(),
        people: PeopleProjection = PeopleProjection(),
        stats: StatsProjection = StatsProjection()
    ) {
        self.facts = facts
        self.people = people
        self.stats = stats
    }
}

// MARK: - Facts

/// The Facts aggregate's loader. Runs on every store revision whether or not Facts is on screen,
/// because the rail's overdue badge reads it (DV1 + AI7); the per-stem cache is what makes that cheap.
@MainActor
final class FactsProjection {
    typealias Loader = @Sendable (_ meetings: [Meeting], _ now: Date, _ cache: FactsLoader.Cache) async -> FactsLoader.Pass

    private let loader: Loader
    private let pass = ProjectionPass<FactsLoader.Pass>()
    private(set) var cache = FactsLoader.Cache()

    /// - Parameter loader: the disk read, injectable so a test can hold one pass while a newer one lands.
    nonisolated init(
        loader: @escaping Loader = { meetings, now, cache in
            FactsLoader.load(meetings: meetings, now: now, cache: cache)
        }
    ) {
        self.loader = loader
    }

    /// Load the facts off-main and hand the newest complete pass to `apply`. Grouping is left to the
    /// caller, at apply time, so the cluster assignment it uses is the one known when the pass lands.
    @discardableResult
    func reload(
        meetings: [Meeting],
        now: Date = Date(),
        apply: @escaping @MainActor (FactsLoader.Pass) -> Void
    ) -> Task<Void, Never> {
        let loader = self.loader
        let cache = self.cache
        let live = Set(meetings.map(\.stem))
        return pass.start(
            work: { await loader(meetings, now, cache) },
            keep: { [weak self] in self?.cache.merge($0.cache) },
            apply: { [weak self] result in
                guard result.complete else { return }
                self?.cache.prune(keeping: live)
                apply(result)
            }
        )
    }
}

// MARK: - People

/// People's per-meeting attendee read, keyed on the speaker overlay's and the summary's modification
/// dates. The roster file is small and re-read every pass.
@MainActor
final class PeopleProjection {
    typealias Loader = @Sendable (_ meetings: [Meeting], _ cache: PeopleLoader.Cache) async -> PeopleLoader.Pass
    typealias Deriver = @Sendable (
        _ roster: [RosterProfile.Person], _ meetings: [PeopleRail.MeetingFacts], _ commitments: [ActionCluster]
    ) -> [PeopleRail.Person]

    private let loader: Loader
    private let deriver: Deriver
    private let pass = ProjectionPass<PeopleLoader.Pass>()
    /// The derivation's own pass (PERF13): `PeopleRail.derive` used to run on main, 146 samples
    /// in the 2026-10-23 rail-switch trace.
    private let derivePass = ProjectionPass<[PeopleRail.Person]>()
    private(set) var cache = PeopleLoader.Cache()

    /// - Parameter deriver: the pure derivation, injectable so a test can see which thread runs it.
    nonisolated init(
        loader: @escaping Loader = { meetings, cache in PeopleLoader.load(meetings: meetings, cache: cache) },
        deriver: @escaping Deriver = { roster, meetings, commitments in
            PeopleRail.derive(roster: roster, meetings: meetings, commitments: commitments)
        }
    ) {
        self.loader = loader
        self.deriver = deriver
    }

    /// Run `PeopleRail.derive` off main and hand the newest result to `apply`. Two things start
    /// one: a disk pass landing, and the Facts commitments changing (the clustering result
    /// arriving, a resolve). Both go through the one pass, so whichever was asked for last wins
    /// even when an older derivation finishes after it.
    @discardableResult
    func derive(
        roster: [RosterProfile.Person],
        meetings: [PeopleRail.MeetingFacts],
        commitments: [ActionCluster],
        apply: @escaping @MainActor ([PeopleRail.Person]) -> Void
    ) -> Task<Void, Never> {
        let deriver = self.deriver
        return derivePass.start(work: { deriver(roster, meetings, commitments) }, apply: apply)
    }

    @discardableResult
    func reload(
        meetings: [Meeting],
        apply: @escaping @MainActor (PeopleLoader.Pass) -> Void
    ) -> Task<Void, Never> {
        let loader = self.loader
        let cache = self.cache
        let live = Set(meetings.map(\.stem))
        return pass.start(
            work: { await loader(meetings, cache) },
            keep: { [weak self] in self?.cache.merge($0.cache) },
            apply: { [weak self] result in
                guard result.complete else { return }
                self?.cache.prune(keeping: live)
                apply(result)
            }
        )
    }

    /// Stop the pass in flight, keeping what it read. Called when the rail leaves People.
    func cancel() {
        pass.cancel()
        derivePass.cancel()
    }
}

/// The disk half of the People rail: one `PeopleRail.MeetingFacts` per library row.
enum PeopleLoader {
    /// Per stem, the names a meeting resolves to (summary attendees mapped through the overlay).
    /// Keyed on `[overlay mtime, summary mtime]`, so a rename's overlay write re-reads only its stem.
    typealias Cache = StemFileCache<[String]>

    struct Pass: Sendable {
        var facts: [PeopleRail.MeetingFacts] = []
        var roster: [RosterProfile.Person] = []
        var cache: Cache
        var complete = false
        /// Stems whose sidecars this pass read rather than took from the cache.
        var read: [String] = []
    }

    /// Blocking disk I/O over the whole library: call it off-main. Stops between meetings once its
    /// task is cancelled.
    static func load(
        meetings: [Meeting],
        cache: Cache = Cache(),
        roster: () -> [RosterProfile.Person] = { RosterProfile.people() }
    ) -> Pass {
        var pass = Pass(roster: roster(), cache: cache)
        pass.facts.reserveCapacity(meetings.count)
        for m in meetings {
            if Task.isCancelled { return pass }
            let summaryURL = m.recordingsDir.appendingPathComponent("\(m.stem).summary.json")
            // Stamped before the read, so a write landing mid-read leaves a stale key.
            let stamp = Cache.stamp([
                SpeakerLabelStore.path(stem: m.stem, in: m.recordingsDir),
                summaryURL,
            ])
            let people: [String]
            if let cached = pass.cache.value(for: m.stem, stamp: stamp) {
                people = cached
            } else {
                pass.read.append(m.stem)
                let overlay = SpeakerLabelStore.read(stem: m.stem, in: m.recordingsDir)
                let summary = m.hasSummaryJSON ? MeetingSummary.load(from: summaryURL) : nil
                people = PeopleRail.resolvedPeople(attendees: summary?.attendees ?? [], overlay: overlay)
                // A summary that is there and failed to decode is not cached: an iCloud placeholder
                // materializing changes no mtime, so the failure would be pinned.
                if !(m.hasSummaryJSON && summary == nil) {
                    pass.cache.set(people, for: m.stem, stamp: stamp)
                }
            }
            pass.facts.append(PeopleRail.MeetingFacts(
                stem: m.stem, title: m.displayTitle, date: m.startedAt, people: people
            ))
        }
        pass.cache.prune(keeping: Set(meetings.map(\.stem)))
        pass.complete = true
        return pass
    }
}

// MARK: - Meeting time

/// Meeting time's talk measurements: the expensive half of the view, one transcript parse per
/// meeting. A rail switch keeps the cache, a rename invalidates exactly that stem (its overlay is in
/// the fingerprint), and an owner-name change drops it.
@MainActor
final class StatsProjection {
    typealias Reader = @Sendable (Meeting, String) -> StatsLoader.Reading

    private let reader: Reader
    private let pass = ProjectionPass<StatsLoader.Pass>()
    private(set) var cache = StatsLoader.TalkCache()
    /// The latest pass's task, so the next one can wait for it to fold in what it read.
    private var latest: Task<Void, Never>?

    /// - Parameter reader: one meeting's transcript read, injectable for the tests.
    nonisolated init(
        reader: @escaping Reader = { meeting, owner in StatsLoader.read(meeting: meeting, ownerLabel: owner) }
    ) {
        self.reader = reader
    }

    @discardableResult
    func reload(
        meetings: [Meeting],
        ownerLabel: String,
        apply: @escaping @MainActor (StatsLoader.Pass) -> Void
    ) -> Task<Void, Never> {
        if cache.ownerLabel != ownerLabel {
            cache = StatsLoader.TalkCache(ownerLabel: ownerLabel)
        }
        let reader = self.reader
        let superseded = latest
        let live = Set(meetings.map(\.stem))
        let task = pass.start(
            work: { [weak self] in
                // The pass this one supersedes is cancelled and stops at its next meeting; wait
                // for its `keep` to fold in what it read, then start from that cache rather than
                // the one as it stood before it. Without this, every revision during the cold
                // 80 MB pass would start one pass behind. Only here: Facts and People read under
                // 1 MB, and their tests hold an older pass open while a newer one completes.
                await superseded?.value
                let cache = await self?.cache ?? StatsLoader.TalkCache(ownerLabel: ownerLabel)
                return StatsLoader.load(meetings: meetings, ownerLabel: ownerLabel, cache: cache, read: reader)
            },
            keep: { [weak self] in self?.cache.merge($0.cache) },
            apply: { [weak self] result in
                guard result.complete else { return }
                self?.cache.stems.prune(keeping: live)
                apply(result)
            }
        )
        latest = task
        return task
    }

    /// Stop the pass in flight, keeping what it measured. Called when the rail leaves Meeting time.
    func cancel() { pass.cancel() }
}
