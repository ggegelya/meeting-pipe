import SwiftUI

/// DV1 + AI7: the cross-meeting facts projection. A read-only aggregate of open
/// actions (with AI1's resolved flag + aging) and recent decisions across the whole
/// library, each row linking back to its source meeting, plus a mark-done control
/// that writes the resolved flag into `<stem>.summary.json` (so it round-trips
/// through a later republish as AI1's upsert). Rendered in the Library's center
/// column when the `.facts` rail scope is active.
///
/// AI7 makes the open-actions section a list of *commitments* rather than
/// instances: a recurring series' restatements of one promise group into a single
/// `ActionCluster`, and marking it done resolves every restatement at once. The
/// aggregation itself lives in `Facts.swift` and is owned by `LibraryRootView`, so
/// the rail's amber overdue badge counts exactly what this view shows.
struct FactsView: View {
    let snapshot: FactsSnapshot
    /// Resolve a whole commitment (every restatement). The host performs the write.
    let onResolve: (ActionCluster) -> Void
    /// Navigate to a fact's source meeting (set by the host: All Meetings + selected row).
    let onOpenMeeting: (String) -> Void

    var body: some View {
        let now = Date()
        Group {
            if !snapshot.loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot.clusters.isEmpty && snapshot.decisions.isEmpty {
                emptyState
            } else {
                List {
                    if !snapshot.clusters.isEmpty {
                        Section {
                            ForEach(snapshot.clusters) { cluster in
                                OpenActionRow(
                                    cluster: cluster,
                                    now: now,
                                    onDone: { onResolve(cluster) },
                                    onOpen: { onOpenMeeting(cluster.representative.stem) }
                                )
                            }
                        } header: { sectionHeader("Open actions", snapshot.clusters.count) }
                    }
                    if !snapshot.decisions.isEmpty {
                        Section {
                            ForEach(snapshot.decisions) { fact in
                                DecisionRow(fact: fact, onOpen: { onOpenMeeting(fact.stem) })
                            }
                        } header: { sectionHeader("Recent decisions", snapshot.decisions.count) }
                    }
                }
                .listStyle(.inset)
            }
        }
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("No open actions or recent decisions.")
                .foregroundStyle(Color(MPColors.fgMuted))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Rows

private struct OpenActionRow: View {
    let cluster: ActionCluster
    let now: Date
    let onDone: () -> Void
    let onOpen: () -> Void

    private var fact: OpenActionFact { cluster.representative }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onDone) {
                Image(systemName: "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
            .buttonStyle(.plain)
            .help(cluster.count > 1
                  ? "Mark done in all \(cluster.count) meetings"
                  : "Mark done")
            .accessibilityLabel(cluster.count > 1
                                ? "Mark action done in all \(cluster.count) meetings"
                                : "Mark action done")

            VStack(alignment: .leading, spacing: 2) {
                Text(fact.task)
                    .foregroundStyle(Color(MPColors.fg))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let owner = fact.owner, !owner.isEmpty {
                        Text(owner)
                    }
                    if let aging = cluster.agingLabel(now: now) {
                        if fact.owner?.isEmpty == false { Text("·") }
                        Text(aging.text)
                            .foregroundStyle(aging.overdue ? Color.mpWarning : Color(MPColors.fgSubtle))
                    }
                    // AI7: say the series restated this, so one row standing for
                    // several meetings never reads as a lost action.
                    if cluster.count > 1 {
                        Text("·")
                        Text("restated \(cluster.count)×")
                            .help(restatementHelp)
                            .accessibilityLabel("restated in \(cluster.count) meetings")
                    }
                    Spacer(minLength: 8)
                    meetingLink(fact.meetingTitle, onOpen: onOpen)
                }
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
            }
        }
        .padding(.vertical, 2)
    }

    /// Name the meetings behind the count, so the grouping is inspectable without
    /// a disclosure control the quiet register does not want.
    private var restatementHelp: String {
        cluster.instances
            .map { "\($0.meetingTitle) · \(FactsDate.short($0.meetingDate))" }
            .joined(separator: "\n")
    }
}

private struct DecisionRow: View {
    let fact: DecisionFact
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fact.text)
                .foregroundStyle(Color(MPColors.fg))
                .fixedSize(horizontal: false, vertical: true)
            meetingLink("\(fact.meetingTitle) · \(FactsDate.short(fact.meetingDate))", onOpen: onOpen)
                .font(.mpTextXS)
        }
        .padding(.vertical, 2)
    }
}

/// Quiet text-button link back to a meeting (signal-teal, no underline chrome).
private func meetingLink(_ label: String, onOpen: @escaping () -> Void) -> some View {
    Button(action: onOpen) {
        Text(label)
            .lineLimit(1)
            .foregroundStyle(Color.mpSignal)
    }
    .buttonStyle(.plain)
    .help("Open meeting")
    .accessibilityLabel("Open meeting \(label)")
}
