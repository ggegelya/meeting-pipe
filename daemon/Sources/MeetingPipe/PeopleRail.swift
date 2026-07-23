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
enum PeopleRail {

    // MARK: - Inputs

    /// One meeting reduced to what the rail needs. Built by the view off the
    /// sidecars; kept separate from `Meeting` so `derive` is pure and testable
    /// without a library on disk.
    struct MeetingFacts: Equatable {
        let stem: String
        let title: String
        let date: Date
        /// Display names this meeting resolves to (summary attendees mapped
        /// through the overlay, plus names the overlay itself introduced).
        let people: [String]
        /// Unresolved actions only; a resolved one is history, not a to-do.
        let openActions: [OpenAction]
    }

    struct OpenAction: Equatable {
        /// Index into `MeetingSummary.actions`, so a row can point at its source.
        let index: Int
        let task: String
        let owner: String?
        let due: String?
    }

    // MARK: - Outputs

    struct Person: Identifiable, Equatable {
        let name: String
        let sampleCount: Int
        /// Every meeting they appear in, newest first.
        let meetings: [MeetingRef]
        /// The open actions they own, soonest due first, undated last.
        let actions: [ActionRef]

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

    struct ActionRef: Identifiable, Equatable {
        let stem: String
        let meetingTitle: String
        let meetingDate: Date
        let index: Int
        let task: String
        let due: String?

        var id: String { "\(stem)#a\(index)" }
        var dueDate: Date? { PeopleDate.day(from: due) }
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
    static func derive(roster: [RosterProfile.Person], meetings: [MeetingFacts]) -> [Person] {
        guard !roster.isEmpty else { return [] }
        let ordered = meetings.sorted { $0.date > $1.date }
        return roster.map { entry in
            let key = normalized(entry.name)
            var refs: [MeetingRef] = []
            var actions: [ActionRef] = []
            for m in ordered {
                var owned: [ActionRef] = []
                for a in m.openActions where normalized(a.owner ?? "") == key {
                    owned.append(ActionRef(
                        stem: m.stem, meetingTitle: m.title, meetingDate: m.date,
                        index: a.index, task: a.task, due: a.due
                    ))
                }
                let attended = m.people.contains { normalized($0) == key }
                // Owning an action counts as being in the meeting: the summarizer
                // names owners the diarizer never labelled, so attendance alone
                // would hide meetings whose actions the rail is already showing.
                if attended || !owned.isEmpty {
                    refs.append(MeetingRef(stem: m.stem, title: m.title, date: m.date))
                }
                actions.append(contentsOf: owned)
            }
            actions.sort(by: dueSooner)
            return Person(
                name: entry.name, sampleCount: entry.sampleCount,
                meetings: refs, actions: actions
            )
        }
    }

    /// Dated actions first (soonest, so overdue floats up), undated last, ties
    /// broken by meeting recency. Mirrors `FactsView`'s open-action ordering.
    private static func dueSooner(_ lhs: ActionRef, _ rhs: ActionRef) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (l?, r?): return l < r
        case (nil, _?):    return false
        case (_?, nil):    return true
        case (nil, nil):   return lhs.meetingDate > rhs.meetingDate
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

/// Day-granular parsing / formatting for the rail. Parallels `FactsView`'s
/// private `FactsDate`; kept separate rather than shared because that one is
/// file-private to the Facts projection.
enum PeopleDate {
    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// Parse the leading `yyyy-MM-dd` of an ISO `due` value (which may carry a time).
    static func day(from s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        return dayParser.date(from: String(s.prefix(10)))
    }

    static func short(_ date: Date) -> String { shortDate.string(from: date) }

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
