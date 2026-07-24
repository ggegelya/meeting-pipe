import Foundation

/// DV3: the People projection's pure half. Given the enrolled roster and one
/// facts record per meeting, it answers "which meetings is this person in, and
/// which open actions do they own".
///
/// The identity spine is the roster (`~/.config/meeting-pipe/roster.json`), not
/// the transcript: a raw diarization label is not a person (see `MeetingCast`),
/// and only an enrolled voice carries a stable name across meetings. So the rail
/// has one row per enrolled person and nothing else; a summary owner the roster
/// never met (`THEM-A`, `speaker_0`, a bare `3`) stays out rather than inventing
/// an identity that cannot be renamed or merged.
///
/// Membership is by resolved display name, because that is the only link the
/// sidecars carry between a roster entry and a meeting. Two sources count, and
/// both are needed because each alone under-reports: the summary's `attendees`
/// (resolved through the speaker-label overlay, so an in-app naming counts even
/// when the summary predates it) and ownership of one of the meeting's actions
/// (the pipeline names owners the diarizer never labelled).
///
/// Derived over files, not a database of record (ADR 0003). Nothing here reads
/// a transcript: the whole library's `<stem>.json` is ~80 MB, its
/// `<stem>.summary.json` under 1 MB, and the summary already carries the
/// speaker set the transcript produced.
///
/// **The actions are AI7's commitments, handed in already grouped.** This rail
/// does not aggregate open actions itself: it filters the very `[ActionCluster]`
/// the Facts projection is showing (`LibraryRootView` owns the one load). DV3 and
/// AI7 shipped in parallel and briefly disagreed about what an open action is, so
/// a standup promise restated five times was one row in Facts and five under its
/// owner here, and resolving it in Facts left this rail stale until the next
/// reload. Sharing the grouped objects is what makes the two rails agree by
/// construction rather than by two implementations staying in step.
enum PeopleRail {

    // MARK: - Inputs

    /// One meeting reduced to what the rail needs. Built by the view off the
    /// sidecars; kept separate from `Meeting` so `derive` is pure and testable
    /// without a library on disk. Carries no actions: those arrive pre-grouped as
    /// `[ActionCluster]`, and a meeting's ownership is read off their instances.
    struct MeetingFacts: Equatable {
        let stem: String
        let title: String
        let date: Date
        /// Display names this meeting resolves to (summary attendees mapped
        /// through the overlay, plus names the overlay itself introduced).
        let people: [String]
    }

    // MARK: - Outputs

    struct Person: Identifiable, Equatable {
        let name: String
        let sampleCount: Int
        /// Every meeting they appear in, newest first.
        let meetings: [MeetingRef]
        /// The open commitments they own, in the Facts order (soonest due first,
        /// undated last). One entry per commitment, not per restatement.
        let actions: [ActionCluster]

        /// The most recent meeting they appear in. Nil for someone enrolled but
        /// not yet matched anywhere.
        var lastSeen: Date? { meetings.first?.date }

        var id: String { name }
    }

    struct MeetingRef: Identifiable, Equatable {
        let stem: String
        let title: String
        let date: Date
        var id: String { stem }
    }

    // MARK: - Name identity

    /// Case- and whitespace-insensitive identity for a display name. Owners and
    /// attendees are free-text fields the summarizer wrote, so "heorhii " and
    /// "Heorhii" are the same person; anything looser (first-token matching,
    /// substrings) would fold two different Ivans into one row, which is exactly
    /// the wrong-name failure the roster's two-gate match rule exists to avoid.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Derivation

    /// One row per enrolled person, in roster order (case-insensitive by name, so
    /// the rail and Preferences ▸ Pipeline ▸ People read the same).
    ///
    /// `commitments` is the Facts projection's grouped open actions (AI7). A
    /// person owns a commitment when they own **any** of its restatements: a
    /// series that named the owner in some occurrences and left the rest
    /// unattributed is still one promise they made, and taking the whole cluster
    /// is what keeps this rail's "restated N×" identical to Facts'. Passing none
    /// (the pre-AI7 shape, and what the view shows before the first load lands)
    /// simply gives every row an empty action list.
    static func derive(
        roster: [RosterProfile.Person],
        meetings: [MeetingFacts],
        commitments: [ActionCluster] = []
    ) -> [Person] {
        guard !roster.isEmpty else { return [] }
        let ordered = meetings.sorted { $0.date > $1.date }
        return roster.map { entry in
            let key = normalized(entry.name)
            // Order is inherited from Facts (soonest due first, undated last), so
            // the two rails cannot sort one person's commitments differently.
            let owned = commitments.filter { cluster in
                cluster.instances.contains { normalized($0.owner ?? "") == key }
            }
            // Only the restatements they are actually named on make a meeting
            // theirs. Widening this to every instance of an owned cluster would
            // put them in a meeting the sidecars never place them in.
            let ownedStems = Set(
                owned.flatMap(\.instances)
                    .filter { normalized($0.owner ?? "") == key }
                    .map(\.stem)
            )
            var refs: [MeetingRef] = []
            for m in ordered {
                let attended = m.people.contains { normalized($0) == key }
                // Owning an action counts as being in the meeting: the summarizer
                // names owners the diarizer never labelled, so attendance alone
                // would hide meetings whose actions the rail is already showing.
                if attended || ownedStems.contains(m.stem) {
                    refs.append(MeetingRef(stem: m.stem, title: m.title, date: m.date))
                }
            }
            return Person(
                name: entry.name, sampleCount: entry.sampleCount,
                meetings: refs, actions: owned
            )
        }
    }

    /// The display names a meeting resolves to: its summary attendees mapped
    /// through the overlay's cluster-name table, plus the names the overlay
    /// itself introduced. Both halves matter: a summary written before an in-app
    /// naming still lists the raw `THEM-A`, and a summary regenerated after one
    /// lists the name while the overlay still keys on the raw label.
    ///
    /// Nothing is filtered out. `speaker_unknown` and `THEM-A` are not roster
    /// names, so they simply match nobody.
    static func resolvedPeople(
        attendees: [String],
        overlay: SpeakerLabelStore.Overlay
    ) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        func add(_ raw: String) {
            let name = overlay.labels[raw] ?? raw
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(normalized(trimmed)).inserted else { return }
            out.append(trimmed)
        }
        for a in attendees { add(a) }
        for value in overlay.labels.values { add(value) }
        for value in overlay.segments.values { add(value) }
        return out
    }

    // MARK: - Rename carry

    /// The overlay that makes `old` display as `new` in one meeting, or nil when
    /// this meeting needs no change.
    ///
    /// `mp roster rename` renames the roster entry and nothing else: transcripts
    /// and summaries keep the name they were written with. Without a carry, the
    /// rail's own rename would empty the person's history, so the rename writes
    /// the new name into the reversible speaker-label overlay (FEAT3-UNDO's
    /// mechanism, never `<stem>.json`) for the meetings the person appears in.
    ///
    /// Two cases, both covered:
    ///   - the name came from the overlay (raw `THEM-A` named in-app): rewrite
    ///     every overlay value that reads as `old`;
    ///   - the name was baked into `<stem>.json` by the pipeline's roster match
    ///     at finalize: there is no overlay entry, so map the raw label `old` to
    ///     `new`. Gated on the summary's attendees actually carrying `old`, so a
    ///     meeting that only ever knew the person through the overlay does not
    ///     collect an entry for a cluster it does not have.
    ///
    /// Identity mappings are dropped, which is what makes a rename reversible:
    /// renaming back collapses the entry this added instead of leaving it
    /// pointing at the previous name.
    static func renamed(
        _ overlay: SpeakerLabelStore.Overlay,
        attendees: [String],
        from old: String,
        to new: String
    ) -> SpeakerLabelStore.Overlay? {
        let key = normalized(old)
        guard key != normalized(new) else { return nil }
        var next = overlay
        for (label, value) in overlay.labels where normalized(value) == key {
            next.labels[label] = new
        }
        for (index, value) in overlay.segments where normalized(value) == key {
            next.segments[index] = new
        }
        if attendees.contains(where: { normalized($0) == key }) {
            next.labels[old] = new
        }
        next.labels = next.labels.filter { $0.key != $0.value }
        return next == overlay ? nil : next
    }

}

// MARK: - Date helpers

/// The rail's one date helper of its own. Day parsing and short-date formatting
/// come from `FactsDate` rather than being duplicated here: DV3 originally carried
/// its own copies because that type was file-private to the Facts projection, and
/// AI7 promoted it to `Facts.swift` at file scope. Now that both rails age the same
/// `ActionCluster` off the same `due` strings, two parsers would be two ways for
/// the same commitment to read differently in two places.
enum PeopleDate {
    static func short(_ date: Date) -> String { FactsDate.short(date) }

    /// "today" / "yesterday" / "3d ago" / a short date past a week. The rail's
    /// last-seen column, where recency is the signal and an exact date is not.
    static func lastSeen(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents(
            [.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)
        ).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        return short(date)
    }
}
