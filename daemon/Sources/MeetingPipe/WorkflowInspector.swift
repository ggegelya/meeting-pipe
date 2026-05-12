import SwiftUI

/// Right-side inspector pane shown when the rail selection is a
/// workflow scope. Anatomy matches `pattern-b.jsx`'s
/// `PB_WorkflowInspector`:
///
///   ● {emoji} {name}
///   one-line summary
///
///   TRIGGER · "Zoom + Teams · auto"
///   MODES   · "NDA on · Record system audio"
///   OUTPUT  · "Notion · Clients DB"
///   TAGS    · whatever
///
///   RECENT
///     • Customer call — Helix Diagnostics
///     • QMS audit prep — release 3.2
///     • Daily Standup — eng team
///
///   [ Edit workflow ]
///
/// We don't store explicit "tags" on a workflow, and the per-workflow
/// trigger/modes lines are derived from existing fields rather than
/// added net-new metadata.
struct WorkflowInspector: View {
    let workflow: Workflow
    /// Pre-filtered meetings that belong to this workflow. The list view
    /// already filters by scope, so we just take the first 5 newest.
    let recentMeetings: [Meeting]
    let onEdit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                rows
                if !recentMeetings.isEmpty {
                    recentSection
                }
                Spacer(minLength: 0)
                Button(action: onEdit) {
                    Label("Edit workflow", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        }
        .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
        .background(Color(MPColors.bg))
    }

    // MARK: pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let emoji = workflow.emoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 16))
                } else {
                    Circle()
                        .fill(swiftUIColor(forHex: workflow.color))
                        .frame(width: 12, height: 12)
                }
                Text(workflow.name)
                    .font(.system(size: 14, weight: .semibold))
                if workflow.isDefault {
                    Text("Default")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.06 * 10)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(MPColors.borderFaint), lineWidth: 0.5)
                        )
                }
            }
            if !workflow.contextPrompt.isEmpty {
                Text(workflow.contextPrompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorRow(label: "Trigger", value: triggerLine)
            InspectorRow(label: "Modes",   value: modesLine)
            InspectorRow(label: "Output",  value: outputLine)
            InspectorRow(label: "Backend", value: backendLine)
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.08 * 10)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(recentMeetings.prefix(5)) { m in
                    Text(m.displayTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.02))
                        )
                }
            }
        }
    }

    // MARK: derived strings

    private var triggerLine: String {
        if workflow.matchingRules.isEmpty {
            return workflow.isDefault ? "Default fallback" : "No matching rules"
        }
        let parts = workflow.matchingRules.compactMap { rule -> String? in
            if !rule.bundleID.isEmpty {
                return rule.bundleID
            }
            if !rule.titleRegex.isEmpty {
                return "/\(rule.titleRegex)/"
            }
            return nil
        }
        return parts.isEmpty ? "Any meeting" : parts.joined(separator: ", ")
    }

    private var modesLine: String {
        workflow.flags.ndaMode ? "NDA on (local-only enforced)" : "—"
    }

    private var outputLine: String {
        let sinks = workflow.effectiveSinks
        if sinks.isEmpty { return "No sinks configured" }
        return sinks.map { sink -> String in
            switch sink {
            case .notion(let id) where !id.isEmpty:
                // Database IDs are noisy; show the leading slug so the
                // user recognises it without taking up the whole row.
                let preview = String(id.prefix(8))
                return "Notion · \(preview)…"
            case .notion:
                return "Notion · (global default)"
            case .obsidian:
                return "Obsidian"
            case .filesystem:
                return "Local filesystem"
            }
        }.joined(separator: ", ")
    }

    private var backendLine: String {
        switch workflow.effectiveBackend {
        case .anthropic: return "Anthropic (cloud)"
        case .local:     return "Local (on-device)"
        case .auto:      return "Auto"
        }
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.08 * 10)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func swiftUIColor(forHex hex: String) -> Color {
    if let ns = HexColor.parse(hex) { return Color(ns) }
    return Color.secondary
}
