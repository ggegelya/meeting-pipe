import AppKit
import SwiftUI

/// Editor sheet for grading a published meeting summary.
///
/// Two entry points (SPEC §17):
/// 1. The "Edit summary" action on the done-meeting notification.
/// 2. The Recent meetings… menu under the status bar.
///
/// One window at a time. Reopening with a different stem swaps the
/// loaded summary in-place rather than stacking sheets. All public
/// methods must be called on the main thread (matches PreferencesWindow).
final class CorrectionWindow {
    private static var shared: CorrectionWindow?

    static func present(stem: String, recordingsDir: URL) {
        let w = shared ?? CorrectionWindow()
        shared = w
        w.show(stem: stem, recordingsDir: recordingsDir)
    }

    private var window: NSWindow?
    private var hosting: NSHostingController<CorrectionView>?
    private var viewModel: CorrectionViewModel?

    private func show(stem: String, recordingsDir: URL) {
        let runURL = recordingsDir.appendingPathComponent("\(stem).run.json")
        let summaryURL = recordingsDir.appendingPathComponent("\(stem).summary.json")
        let runMeta: [String: Any]
        let originalSummary: [String: Any]
        do {
            runMeta = try CorrectionStore.loadRunSidecar(at: runURL)
            originalSummary = try CorrectionStore.loadOriginalSummary(at: summaryURL)
        } catch {
            Self.presentLoadError(stem: stem, error: error)
            return
        }

        let model = CorrectionViewModel(
            stem: stem,
            recordingsDir: recordingsDir,
            runMeta: runMeta,
            originalSummary: originalSummary
        )
        self.viewModel = model

        let view = CorrectionView(
            model: model,
            onCommit: { [weak self] outcome in self?.handleOutcome(outcome) }
        )

        if let host = self.hosting, let win = self.window {
            host.rootView = view
            win.title = "Edit summary, \(model.headerTitle)"
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Edit summary, \(model.headerTitle)"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 600, height: 700))
        win.minSize = NSSize(width: 520, height: 560)
        win.isReleasedWhenClosed = false
        win.center()

        let delegate = CorrectionWindowDelegate { [weak self] in
            self?.window = nil
            self?.hosting = nil
            self?.viewModel = nil
            CorrectionWindow.shared = nil
        }
        objc_setAssociatedObject(win, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        win.delegate = delegate

        self.window = win
        self.hosting = host
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleOutcome(_ outcome: CorrectionOutcome) {
        switch outcome {
        case .cancel:
            window?.performClose(nil)
        case .saveEdited(let model), .saveBad(let model):
            let verdict: CorrectionStore.Verdict = outcome.isBad ? .bad : .edited
            let corrected: [String: Any]? = outcome.isBad ? nil : model.makeCorrectedSummary()
            do {
                try CorrectionStore.write(
                    stem: model.stem,
                    transcriptPath: model.transcriptPath,
                    summaryJsonPath: model.summaryJsonPath,
                    modelId: model.modelId,
                    backend: model.backend,
                    verdict: verdict,
                    originalSummary: model.originalSummary,
                    correctedSummary: corrected,
                    notes: model.notes.isEmpty ? nil : model.notes
                )
                Log.event(category: "correction", action: "saved", attributes: [
                    "stem": model.stem,
                    "verdict": verdict.rawValue,
                    "backend": model.backend,
                    "model_id": model.modelId,
                ])
                Log.writeLine("daemon", "correction saved → \(model.stem).json verdict=\(verdict.rawValue)")
                window?.performClose(nil)
            } catch {
                Self.presentSaveError(stem: model.stem, error: error)
            }
        }
    }

    private static func presentLoadError(stem: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not open the summary for \(stem)"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func presentSaveError(stem: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not save the correction for \(stem)"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static var delegateKey: UInt8 = 0
}

private final class CorrectionWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - View model

enum CorrectionOutcome {
    case cancel
    case saveEdited(CorrectionViewModel)
    case saveBad(CorrectionViewModel)

    var isBad: Bool {
        if case .saveBad = self { return true }
        return false
    }
}

struct EditableAction: Identifiable, Equatable {
    let id = UUID()
    var task: String
    var owner: String
    var due: String
    var confidence: String
}

final class CorrectionViewModel: ObservableObject {
    let stem: String
    let recordingsDir: URL
    let runMeta: [String: Any]
    let originalSummary: [String: Any]

    @Published var title: String
    @Published var summary: [String]
    @Published var decisions: [String]
    @Published var actions: [EditableAction]
    @Published var questions: [String]
    @Published var attendees: [String]
    @Published var detectedLanguage: String
    @Published var notes: String = ""

    init(
        stem: String,
        recordingsDir: URL,
        runMeta: [String: Any],
        originalSummary: [String: Any]
    ) {
        self.stem = stem
        self.recordingsDir = recordingsDir
        self.runMeta = runMeta
        self.originalSummary = originalSummary

        self.title = (originalSummary["title"] as? String) ?? ""
        self.summary = Self.stringList(originalSummary["summary"])
        self.decisions = Self.stringList(originalSummary["decisions"])
        self.questions = Self.stringList(originalSummary["questions"])
        self.attendees = Self.stringList(originalSummary["attendees"])
        self.detectedLanguage = (originalSummary["detected_language"] as? String) ?? "en"
        self.actions = Self.actionList(originalSummary["actions"])
    }

    var backend: String { (runMeta["backend"] as? String) ?? "" }
    var modelId: String { (runMeta["model"] as? String) ?? "" }
    var transcriptPath: String {
        (runMeta["transcript_path"] as? String)
            ?? recordingsDir.appendingPathComponent("\(stem).md").path
    }
    var summaryJsonPath: String {
        (runMeta["summary_json_path"] as? String)
            ?? recordingsDir.appendingPathComponent("\(stem).summary.json").path
    }

    var headerTitle: String {
        (originalSummary["title"] as? String).map { $0.isEmpty ? stem : $0 } ?? stem
    }

    func makeCorrectedSummary() -> [String: Any] {
        let actionDicts: [[String: Any]] = actions
            .filter { !$0.task.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { a in
                var d: [String: Any] = [
                    "task": a.task,
                    "confidence": a.confidence.isEmpty ? "medium" : a.confidence,
                ]
                d["owner"] = a.owner.isEmpty ? NSNull() : a.owner
                d["due"] = a.due.isEmpty ? NSNull() : a.due
                return d
            }
        return [
            "title": title,
            "summary": Self.trimmed(summary),
            "decisions": Self.trimmed(decisions),
            "actions": actionDicts,
            "questions": Self.trimmed(questions),
            "attendees": Self.trimmed(attendees),
            "detected_language": detectedLanguage,
        ]
    }

    private static func stringList(_ raw: Any?) -> [String] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { ($0 as? String) }
    }

    private static func actionList(_ raw: Any?) -> [EditableAction] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.map {
            EditableAction(
                task: ($0["task"] as? String) ?? "",
                owner: ($0["owner"] as? String) ?? "",
                due: ($0["due"] as? String) ?? "",
                confidence: ($0["confidence"] as? String) ?? "medium"
            )
        }
    }

    private static func trimmed(_ items: [String]) -> [String] {
        items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - SwiftUI view

private struct CorrectionView: View {
    @ObservedObject var model: CorrectionViewModel
    let onCommit: (CorrectionOutcome) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metaHeader
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleField
                    listSection(title: "Summary", items: $model.summary,
                                placeholder: "One summary bullet")
                    listSection(title: "Decisions", items: $model.decisions,
                                placeholder: "Explicit commitment, e.g. \"agreed to ship Friday\"")
                    actionsSection
                    listSection(title: "Open questions", items: $model.questions,
                                placeholder: "Unresolved question raised in the meeting")
                    listSection(title: "Attendees", items: $model.attendees,
                                placeholder: "Name or speaker label")
                    languageRow
                    notesField
                }
                .padding(20)
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
    }

    private var metaHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.stem)
                .font(.system(.headline, design: .monospaced))
            HStack(spacing: 14) {
                Label(model.backend.isEmpty ? "(unknown backend)" : model.backend,
                      systemImage: "cpu")
                Label(modelDisplayName, systemImage: "cube")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var modelDisplayName: String {
        let id = model.modelId
        if id.isEmpty { return "(unknown model)" }
        if let slash = id.lastIndex(of: "/") {
            return String(id[id.index(after: slash)...])
        }
        return id
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

    private var footer: some View {
        HStack {
            Button("Mark as unusable") { onCommit(.saveBad(model)) }
                .help("Record verdict=bad without keeping any edits")
            Spacer()
            Button("Cancel") { onCommit(.cancel) }
            Button("Save correction") { onCommit(.saveEdited(model)) }
                .keyboardShortcut(.defaultAction)
        }
    }
}
