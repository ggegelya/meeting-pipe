import AppKit
import SwiftUI

/// Standalone summary-grading window (see ADR 0015). Entry points: done-meeting notification and the Recent meetings menu. One window at a time; reopening with a different stem swaps the summary in-place. Must be called on the main thread.
final class CorrectionWindow {
    private static var shared: CorrectionWindow?

    static func present(stem: String, recordingsDir: URL) {
        let w = shared ?? CorrectionWindow()
        shared = w
        w.show(stem: stem, recordingsDir: recordingsDir)
    }

    private var window: NSWindow?
    private var hosting: NSHostingController<MPControlAccent<CorrectionView>>?
    private var viewModel: CorrectionViewModel?

    private func show(stem: String, recordingsDir: URL) {
        let runURL = recordingsDir.appendingPathComponent("\(stem).run.json")
        let summaryURL = recordingsDir.appendingPathComponent("\(stem).summary.json")
        let runMeta: [String: Any]
        do {
            runMeta = try CorrectionStore.loadRunSidecar(at: runURL)
        } catch {
            Self.presentLoadError(stem: stem, error: error)
            return
        }
        guard let originalSummary = MeetingSummary.load(from: summaryURL) else {
            Self.presentLoadError(stem: stem, error: CorrectionStore.Error.summaryUnreadable(summaryURL))
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
            host.rootView = MPControlAccent(view)
            win.title = "Edit summary, \(model.headerTitle)"
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: MPControlAccent(view))
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
            let corrected: [String: Any]? = outcome.isBad ? nil : model.makeCorrectedSummary().jsonObject()
            do {
                try CorrectionStore.write(
                    stem: model.stem,
                    transcriptPath: model.transcriptPath,
                    summaryJsonPath: model.summaryJsonPath,
                    modelId: model.modelId,
                    backend: model.backend,
                    verdict: verdict,
                    originalSummary: model.originalSummary.jsonObject(),
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
    let originalSummary: MeetingSummary

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
        originalSummary: MeetingSummary
    ) {
        self.stem = stem
        self.recordingsDir = recordingsDir
        self.runMeta = runMeta
        self.originalSummary = originalSummary

        self.title = originalSummary.title
        self.summary = originalSummary.summary
        self.decisions = originalSummary.decisions
        self.questions = originalSummary.questions
        self.attendees = originalSummary.attendees
        self.detectedLanguage = originalSummary.detectedLanguage ?? "en"
        self.actions = originalSummary.actions.map {
            EditableAction(
                task: $0.task,
                owner: $0.owner ?? "",
                due: $0.due ?? "",
                confidence: $0.confidence
            )
        }
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
        originalSummary.title.isEmpty ? stem : originalSummary.title
    }

    func makeCorrectedSummary() -> MeetingSummary {
        let items = actions
            .filter { !$0.task.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { a in
                MeetingSummary.ActionItem(
                    task: a.task,
                    owner: a.owner.isEmpty ? nil : a.owner,
                    due: a.due.isEmpty ? nil : a.due,
                    confidence: a.confidence.isEmpty ? "medium" : a.confidence
                )
            }
        return MeetingSummary(
            title: title,
            summary: Self.trimmed(summary),
            decisions: Self.trimmed(decisions),
            actions: items,
            questions: Self.trimmed(questions),
            attendees: Self.trimmed(attendees),
            detectedLanguage: detectedLanguage
        )
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
            CorrectionEditorBody(model: model)
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
