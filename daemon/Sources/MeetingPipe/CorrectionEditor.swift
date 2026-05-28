import AppKit
import SwiftUI

/// Shared editor form driving a `CorrectionViewModel`. Used by `CorrectionWindow` (standalone) and the Summary tab (TECH-A5 inline). No header, footer, or buttons - call sites compose those.
struct CorrectionEditorBody: View {
    @ObservedObject var model: CorrectionViewModel
    /// Inline pane (Library ~480px) passes a smaller value to avoid squeezing the fields further; standalone window uses the default 20pt.
    var contentPadding: CGFloat = 20
    /// Library inline form hides the Notes field to reduce visual weight (the header chip already shows backend/model). Standalone window shows it.
    var showsNotesField: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleField
                listSection(
                    title: "Summary", items: $model.summary,
                    placeholder: "One summary bullet"
                )
                listSection(
                    title: "Decisions", items: $model.decisions,
                    placeholder: "Explicit commitment, e.g. \"agreed to ship Friday\""
                )
                actionsSection
                listSection(
                    title: "Open questions", items: $model.questions,
                    placeholder: "Unresolved question raised in the meeting"
                )
                listSection(
                    title: "Attendees", items: $model.attendees,
                    placeholder: "Name or speaker label"
                )
                languageRow
                if showsNotesField {
                    notesField
                }
            }
            .padding(contentPadding)
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Title").font(.subheadline).bold()
            TextField("Meeting title", text: $model.title)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func listSection(
        title: String,
        items: Binding<[String]>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline).bold()
                Spacer()
                Button {
                    items.wrappedValue.append("")
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
            VStack(spacing: 6) {
                ForEach(items.wrappedValue.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        TextField(placeholder, text: items[i], axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...6)
                        Button {
                            items.wrappedValue.remove(at: i)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if items.wrappedValue.isEmpty {
                Text("No entries.").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Action items").font(.subheadline).bold()
                Spacer()
                Button {
                    model.actions.append(EditableAction(
                        task: "", owner: "", due: "", confidence: "medium"
                    ))
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
            VStack(spacing: 10) {
                ForEach($model.actions) { $action in
                    actionRow(action: $action)
                }
            }
            if model.actions.isEmpty {
                Text("No action items.").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func actionRow(action: Binding<EditableAction>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Task", text: action.task, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            HStack(spacing: 8) {
                TextField("Owner", text: action.owner)
                    .textFieldStyle(.roundedBorder)
                TextField("Due (YYYY-MM-DD)", text: action.due)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: action.confidence) {
                    Text("low").tag("low")
                    Text("medium").tag("medium")
                    Text("high").tag("high")
                }
                .labelsHidden()
                .frame(width: 110)
                Button {
                    if let i = model.actions.firstIndex(where: { $0.id == action.wrappedValue.id }) {
                        model.actions.remove(at: i)
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    private var languageRow: some View {
        HStack {
            Text("Detected language").font(.subheadline).bold()
            Spacer()
            TextField("en", text: $model.detectedLanguage)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.subheadline).bold()
            TextEditor(text: $model.notes)
                .frame(minHeight: 60, maxHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3))
                )
        }
    }
}
