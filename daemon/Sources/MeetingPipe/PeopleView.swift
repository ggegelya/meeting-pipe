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
struct PeopleView: View {
    @ObservedObject var store: MeetingStore
    /// Navigate to a meeting (set by the host: All Meetings + selected row).
    let onOpenMeeting: (String) -> Void

    @State private var people: [PeopleRail.Person] = []
    @State private var expanded: Set<String> = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var renaming: String?
    @State private var launcher = PipelineLauncher()

    var body: some View {
        VStack(spacing: 0) {
            if let errorText {
                errorBanner(errorText)
            }
            content
        }
        .onAppear(perform: reaggregate)
        .onChange(of: store.revision) { _, _ in reaggregate() }
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

    /// Rebuild every person's meetings + owned actions off-main. Triggered on
    /// appear and on each `MeetingStore.revision` bump, so a finished pipeline
    /// run or a rename's overlay writes land here.
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
                var actions: [PeopleRail.OpenAction] = []
                for (i, a) in (summary?.actions ?? []).enumerated() where !a.resolved {
                    let task = a.task.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !task.isEmpty else { continue }
                    actions.append(PeopleRail.OpenAction(
                        index: i, task: task, owner: a.owner, due: a.due))
                }
                facts.append(PeopleRail.MeetingFacts(
                    stem: m.stem,
                    title: m.displayTitle,
                    date: m.startedAt,
                    people: PeopleRail.resolvedPeople(
                        attendees: summary?.attendees ?? [], overlay: overlay),
                    openActions: actions
                ))
            }
            let derived = PeopleRail.derive(roster: roster, meetings: facts)
            await MainActor.run {
                self.people = derived
                self.loading = false
            }
        }
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
                ForEach(person.actions) { action in
                    PersonActionRow(action: action, onOpen: { onOpenMeeting(action.stem) })
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

/// One owned open action: the task, its aging, and a link back to the meeting it
/// came from. Read-only here; "mark done" stays in Facts, which owns the
/// resolved-flag write.
private struct PersonActionRow: View {
    let action: PeopleRail.ActionRef
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(action.task)
                .foregroundStyle(Color(MPColors.fg))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let aging = agingLabel {
                    Text(aging.text)
                        .foregroundStyle(aging.overdue ? Color.mpWarning : Color(MPColors.fgSubtle))
                    Text("·")
                }
                Button(action: onOpen) {
                    Text(action.meetingTitle)
                        .lineLimit(1)
                        .foregroundStyle(Color.mpSignal)
                }
                .buttonStyle(.plain)
                .help("Open meeting")
                .accessibilityLabel("Open meeting \(action.meetingTitle)")
                Spacer(minLength: 8)
            }
            .font(.mpTextXS)
            .foregroundStyle(Color(MPColors.fgSubtle))
        }
        .padding(.vertical, 2)
    }

    /// Day-granular aging off the ISO `due` date, matching the Facts row wording.
    private var agingLabel: (text: String, overdue: Bool)? {
        guard let due = action.dueDate else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents(
            [.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: due)
        ).day ?? 0
        if days < 0 { return ("\(-days)d overdue", true) }
        if days == 0 { return ("due today", true) }
        return ("in \(days)d", false)
    }
}
