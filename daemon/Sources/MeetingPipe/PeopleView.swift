import SwiftUI

/// DV3: the People projection. One row per enrolled roster person, expanding to
/// the open actions they own and the meetings they appear in, each linking back
/// to its meeting the way a Facts row does. Rendered in the Library's center
/// column when the `.people` rail scope is active.
///
/// Read-only over the sidecars the pipeline already wrote (ADR 0003), with one
/// write: Rename, which goes through `RosterRename` so the roster, this rail,
/// Preferences ▸ Pipeline ▸ People, and past transcripts all read the same name.
/// The derivation itself is `PeopleRail.derive`; this view only does the I/O and
/// the chrome.
///
/// The open actions are not loaded here: `commitments` is the same grouped
/// `[ActionCluster]` the Facts projection renders, handed down by the host (AI7).
/// That is what makes a restated commitment one row in both rails, and what makes
/// resolving it in Facts drop it from here in the same breath instead of leaving
/// this rail stale until the next reload.
struct PeopleView: View {
    @ObservedObject var store: MeetingStore
    /// The library's open commitments, already grouped and ordered by the host.
    let commitments: [ActionCluster]
    /// Navigate to a meeting (set by the host: All Meetings + selected row).
    let onOpenMeeting: (String) -> Void

    @State private var people: [PeopleRail.Person] = []
    @State private var expanded: Set<String> = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var renaming: String?
    @State private var launcher = PipelineLauncher()
    /// The last loaded per-meeting attendee facts, kept so a change in
    /// `commitments` (the async clustering landing, or a Facts resolve) re-derives
    /// in memory instead of re-reading every summary off disk.
    @State private var facts: [PeopleRail.MeetingFacts] = []
    @State private var roster: [RosterProfile.Person] = []

    var body: some View {
        VStack(spacing: 0) {
            if let errorText {
                errorBanner(errorText)
            }
            content
        }
        .onAppear(perform: reaggregate)
        .onChange(of: store.revision) { _, _ in reaggregate() }
        .onChange(of: commitments) { _, _ in rederive() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if people.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(people) { person in
                        PersonDisclosure(
                            person: person,
                            isExpanded: expansionBinding(person.name),
                            isRenaming: renaming == person.name,
                            onRename: { beginRename(person) },
                            onOpenMeeting: onOpenMeeting
                        )
                    }
                } header: { sectionHeader("People", people.count) }
            }
            .listStyle(.inset)
        }
    }

    private func expansionBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(name) },
            set: { isOn in
                if isOn { expanded.insert(name) } else { expanded.remove(name) }
            }
        )
    }

    private func sectionHeader(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(count.formatted(.number))
                .monospacedDigit()
        }
        .font(.mpTextXS.weight(.semibold))
        .tracking(0.08 * 10)
        .textCase(.uppercase)
        .foregroundStyle(Color(MPColors.fgMuted))
    }

    /// The empty-roster state names the one way in: nobody is enrolled until a
    /// speaker is named from a transcript, so pointing at Facts or Preferences
    /// here would be a dead end.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.mpText2XL)
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("No named people yet.")
                .foregroundStyle(Color(MPColors.fgMuted))
            Text("Open a meeting's Transcript tab, right-click a speaker, and name them. Named voices are matched across meetings and show up here with their meetings and open actions.")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Inline, dismissible failure row for a failed rename, in the AskView /
    /// DigestsView vocabulary (warning triangle + muted text).
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.mpWarning)
            Text(message)
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { errorText = nil } label: {
                Image(systemName: "xmark")
                    .font(.mpTextXS.weight(.semibold))
                    .foregroundStyle(Color(MPColors.fgMuted))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.mpWarning.opacity(0.1))
    }

    // MARK: - Aggregation

    /// Reload the roster + every meeting's resolved attendee names off-main.
    /// Triggered on appear and on each `MeetingStore.revision` bump, so a finished
    /// pipeline run or a rename's overlay writes land here. The open actions are
    /// not read here at all; they arrive as `commitments` from the host.
    private func reaggregate() {
        let meetings = store.meetings        // value snapshot
        Task.detached(priority: .userInitiated) {
            let roster = RosterProfile.people()
            var facts: [PeopleRail.MeetingFacts] = []
            facts.reserveCapacity(meetings.count)
            for m in meetings {
                let overlay = SpeakerLabelStore.read(stem: m.stem, in: m.recordingsDir)
                let summary = m.hasSummaryJSON
                    ? MeetingSummary.load(
                        from: m.recordingsDir.appendingPathComponent("\(m.stem).summary.json"))
                    : nil
                facts.append(PeopleRail.MeetingFacts(
                    stem: m.stem,
                    title: m.displayTitle,
                    date: m.startedAt,
                    people: PeopleRail.resolvedPeople(
                        attendees: summary?.attendees ?? [], overlay: overlay)
                ))
            }
            let loaded = facts, people = roster
            await MainActor.run {
                self.facts = loaded
                self.roster = people
                self.loading = false
                rederive()
            }
        }
    }

    /// Re-run the pure derivation against the current `commitments`. No disk read:
    /// a clustering pass landing (or a Facts resolve removing one) changes which
    /// commitments a person owns, never which meetings they were in.
    private func rederive() {
        people = PeopleRail.derive(roster: roster, meetings: facts, commitments: commitments)
    }

    // MARK: - Rename

    /// Rename through `RosterRename`: `mp roster rename` plus the overlay carry,
    /// the same call Preferences makes, so the two surfaces cannot drift.
    private func beginRename(_ person: PeopleRail.Person) {
        guard let newName = RosterRename.prompt(currentName: person.name) else { return }
        errorText = nil
        renaming = person.name
        RosterRename.run(from: person.name, to: newName, launcher: launcher) { result in
            renaming = nil
            switch result {
            case .success:
                // The carry's overlay writes bump the store's watcher, which
                // reaggregates; do it here too so a rename with nothing to carry
                // still refreshes the row's name.
                reaggregate()
            case .failure(let error):
                errorText = "Rename failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Rows

/// One person: a summary line that expands to their open actions and meetings.
private struct PersonDisclosure: View {
    let person: PeopleRail.Person
    @Binding var isExpanded: Bool
    let isRenaming: Bool
    let onRename: () -> Void
    let onOpenMeeting: (String) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if person.meetings.isEmpty {
                Text("Not matched in any meeting yet.")
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .padding(.vertical, 2)
            }
            if !person.actions.isEmpty {
                subheader("Open actions")
                ForEach(person.actions) { commitment in
                    PersonActionRow(
                        commitment: commitment,
                        onOpen: { onOpenMeeting(commitment.representative.stem) }
                    )
                }
            }
            if !person.meetings.isEmpty {
                subheader("Meetings")
                ForEach(person.meetings) { meeting in
                    Button { onOpenMeeting(meeting.stem) } label: {
                        HStack(spacing: 6) {
                            Text(meeting.title)
                                .lineLimit(1)
                                .foregroundStyle(Color.mpSignal)
                            Spacer(minLength: 8)
                            Text(PeopleDate.short(meeting.date))
                                .font(.mpTextXS)
                                .foregroundStyle(Color(MPColors.fgSubtle))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open meeting")
                    .accessibilityLabel("Open meeting \(meeting.title)")
                    .padding(.vertical, 1)
                }
            }
        } label: {
            header
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.mpTextBase.weight(.semibold))
                    .foregroundStyle(Color(MPColors.fg))
                Text(metaLine)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
            Spacer(minLength: 8)
            if isRenaming {
                ProgressView().controlSize(.small)
            } else {
                Button(action: onRename) {
                    Image(systemName: "pencil")
                        .foregroundStyle(Color(MPColors.fgMuted))
                }
                .buttonStyle(.plain)
                .help("Rename this person everywhere")
                .accessibilityLabel("Rename \(person.name)")
            }
        }
        .padding(.vertical, 2)
    }

    /// "12 meetings · 3 open actions · last seen 3d ago". Counts are dropped when
    /// zero rather than rendered as "0", so a quiet row stays quiet.
    ///
    /// The action count is **commitments, not restatements**, the same thing the
    /// Facts rail badge counts (AI7): a standup promise made once and repeated
    /// weekly is one thing this person owes, and counting the repeats turned a
    /// real roster row into "66 open actions", a number too inflated to act on.
    private var metaLine: String {
        var parts: [String] = []
        if person.meetings.isEmpty {
            parts.append("no meetings yet")
        } else {
            parts.append("\(person.meetings.count) meeting\(person.meetings.count == 1 ? "" : "s")")
        }
        if !person.actions.isEmpty {
            parts.append("\(person.actions.count) open action\(person.actions.count == 1 ? "" : "s")")
        }
        if let last = person.lastSeen {
            parts.append("last seen \(PeopleDate.lastSeen(last))")
        }
        return parts.joined(separator: " · ")
    }

    private func subheader(_ title: String) -> some View {
        Text(title)
            .font(.mpTextXS.weight(.semibold))
            .tracking(0.08 * 10)
            .textCase(.uppercase)
            .foregroundStyle(Color(MPColors.fgMuted))
            .padding(.top, 4)
    }
}

/// One owned commitment: the task, its aging, how often the series restated it,
/// and a link back to the meeting it came from. Aging comes from `ActionCluster`
/// itself rather than a local copy, so this row and the Facts row can never word
/// the same deadline differently. Read-only here; "mark done" stays in Facts,
/// which owns the resolved-flag write across every restatement.
private struct PersonActionRow: View {
    let commitment: ActionCluster
    let onOpen: () -> Void

    var body: some View {
        let fact = commitment.representative
        VStack(alignment: .leading, spacing: 2) {
            Text(fact.task)
                .foregroundStyle(Color(MPColors.fg))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let aging = commitment.agingLabel(now: Date()) {
                    Text(aging.text)
                        .foregroundStyle(aging.overdue ? Color.mpWarning : Color(MPColors.fgSubtle))
                    Text("·")
                }
                if commitment.count > 1 {
                    Text("restated \(commitment.count)×")
                        .accessibilityLabel("restated in \(commitment.count) meetings")
                    Text("·")
                }
                Button(action: onOpen) {
                    Text(fact.meetingTitle)
                        .lineLimit(1)
                        .foregroundStyle(Color.mpSignal)
                }
                .buttonStyle(.plain)
                .help("Open meeting")
                .accessibilityLabel("Open meeting \(fact.meetingTitle)")
                Spacer(minLength: 8)
            }
            .font(.mpTextXS)
            .foregroundStyle(Color(MPColors.fgSubtle))
        }
        .padding(.vertical, 2)
    }
}
