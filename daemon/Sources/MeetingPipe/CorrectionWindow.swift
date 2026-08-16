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
        // UX65: capture what was loaded, so `handleOutcome` can tell whether the
        // file moved under the window. Read here and nowhere else; a capture
        // taken later would be a capture of somebody else's write.
        let loadedIdentity = SummaryIdentity.read(at: summaryURL)

        let model = CorrectionViewModel(
            stem: stem,
            recordingsDir: recordingsDir,
            runMeta: runMeta,
            originalSummary: originalSummary,
            loadedIdentity: loadedIdentity
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
            // Deliberately no `WindowActivationManager` handshake: this is a one-shot grading window off a notification, not a place the user Cmd+Tabs to (UX39).
            NSApp.activate()
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
        NSApp.activate()
    }

    private func handleOutcome(_ outcome: CorrectionOutcome) {
        switch outcome {
        case .cancel:
            window?.performClose(nil)
        case .saveEdited(let model), .saveBad(let model):
            let verdict: CorrectionStore.Verdict = outcome.isBad ? .bad : .edited
            let corrected: [String: Any]? = outcome.isBad ? nil : model.makeCorrectedSummary().jsonObject()
            do {
                switch try Self.performSave(
                    model: model,
                    verdict: verdict,
                    corrected: corrected,
                    resolveStale: Self.resolveStaleSave
                ) {
                case .written:
                    Log.event(category: "correction", action: "saved", attributes: [
                        "stem": model.stem,
                        "verdict": verdict.rawValue,
                        "backend": model.backend,
                        "model_id": model.modelId,
                    ])
                    Log.writeLine("daemon", "correction saved → \(model.stem).json verdict=\(verdict.rawValue)")
                    window?.performClose(nil)
                case .reopened:
                    // Rebuilds the model from disk in the same window. The
                    // in-progress edit goes, which is the honest outcome of that
                    // choice and exactly what the dialog said it would be.
                    Log.event(category: "correction", action: "stale_reopened", attributes: [
                        "stem": model.stem,
                        "verdict": verdict.rawValue,
                    ])
                    show(stem: model.stem, recordingsDir: model.recordingsDir)
                }
            } catch {
                Self.presentSaveError(stem: model.stem, error: error)
            }
        }
    }

    /// What the owner chose when the summary moved under the window (UX65).
    enum StaleSaveChoice { case keep, reopen }

    enum SaveOutcome: Equatable {
        case written(URL)
        /// Nothing was written; the caller reopens against the current summary.
        case reopened
    }

    /// The save path, with the dialog injected (UX65).
    ///
    /// Extracted from `handleOutcome` so the thing that actually matters is
    /// assertable on the **bytes** of `corrections/<stem>.json` rather than
    /// through a modal: the whole point is that a stale save writes no record,
    /// and a test that could only check a return value would pass over a write
    /// that happened first.
    ///
    /// The record's `original_summary` is what `CorrectionsTab.performRevert`
    /// restores over the live summary, and it is the corpus `mp train-adapter`
    /// learns from, so it has to be prose the model actually emitted for the run
    /// being graded. That is the whole reason the comparison exists.
    static func performSave(
        model: CorrectionViewModel,
        verdict: CorrectionStore.Verdict,
        corrected: [String: Any]?,
        resolveStale: (CorrectionStore.Verdict) -> StaleSaveChoice,
        correctionsDirectoryOverride: URL? = nil
    ) throws -> SaveOutcome {
        let summaryURL = model.recordingsDir.appendingPathComponent("\(model.stem).summary.json")
        var original = model.originalSummary

        if SummaryStaleness.hasMoved(
            loaded: model.loadedIdentity,
            current: SummaryIdentity.read(at: summaryURL)
        ) {
            switch resolveStale(verdict) {
            case .reopen:
                return .reopened
            case .keep:
                // Record it against what is on disk now. Anything else recreates
                // the defect one step later: a record whose original is prose
                // this run never produced, waiting for a Revert to write it back.
                guard let current = MeetingSummary.load(from: summaryURL) else {
                    throw CorrectionStore.Error.summaryUnreadable(summaryURL)
                }
                original = current
            }
        }

        let url = try CorrectionStore.write(
            stem: model.stem,
            transcriptPath: model.transcriptPath,
            summaryJsonPath: model.summaryJsonPath,
            modelId: model.modelId,
            backend: model.backend,
            verdict: verdict,
            originalSummary: original.jsonObject(),
            correctedSummary: corrected,
            notes: model.notes.isEmpty ? nil : model.notes,
            directoryOverride: correctionsDirectoryOverride
        )
        return .written(url)
    }

    /// The copy is `SummaryStaleness.choice`'s, unmodified, so it is assertable
    /// without a window; this only decides which button is which.
    private static func resolveStaleSave(verdict: CorrectionStore.Verdict) -> StaleSaveChoice {
        let choice = SummaryStaleness.choice(verdict: verdict)
        let alert = NSAlert()
        alert.messageText = choice.title
        alert.informativeText = choice.message
        alert.alertStyle = .warning
        // First button added is the default one Return activates, which is the
        // whole of the per-verdict split.
        if choice.defaultIsKeep {
            alert.addButton(withTitle: choice.keepButton)
            alert.addButton(withTitle: choice.reopenButton)
            return alert.runModal() == .alertFirstButtonReturn ? .keep : .reopen
        }
        alert.addButton(withTitle: choice.reopenButton)
        alert.addButton(withTitle: choice.keepButton)
        return alert.runModal() == .alertFirstButtonReturn ? .reopen : .keep
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
    // Carried through the editor untouched (no resolve control here; that is
    // DV1's surface) so a text edit does not reopen a resolved action. AI1.
    var resolved: Bool = false
    // FEAT10: the item's verified anchors, plus the task text they were verified
    // against. The pair is what lets the save decide whether they still apply:
    // an untouched task keeps them, a rewritten one drops them. A row the user
    // adds in the editor has neither, so it starts uncited.
    var evidence: [MeetingSummary.Evidence] = []
    var originalTask: String = ""
}

final class CorrectionViewModel: ObservableObject {
    let stem: String
    let recordingsDir: URL
    let runMeta: [String: Any]
    let originalSummary: MeetingSummary
    /// UX65: the identity of `<stem>.summary.json` as `show()` read it. Compared
    /// in `handleOutcome`, never re-read here: a capture that is never compared
    /// is exactly the failure mode this task is about, and a capture taken later
    /// would be a capture of whatever overwrote it.
    let loadedIdentity: SummaryIdentity?

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
        originalSummary: MeetingSummary,
        loadedIdentity: SummaryIdentity? = nil
    ) {
        self.stem = stem
        self.recordingsDir = recordingsDir
        self.runMeta = runMeta
        self.originalSummary = originalSummary
        self.loadedIdentity = loadedIdentity

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
                confidence: $0.confidence,
                resolved: $0.resolved,
                evidence: $0.evidence,
                originalTask: $0.task
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
                    confidence: a.confidence.isEmpty ? "medium" : a.confidence,
                    resolved: a.resolved,
                    // FEAT10: the quote backed the task as it was written. Rewrite
                    // the task and the citation no longer supports it, so it goes.
                    // Owner / due / confidence edits are not text edits and keep it.
                    evidence: a.task == a.originalTask ? a.evidence : []
                )
            }
        let summaryOut = Self.trimmed(summary)
        let decisionsOut = Self.trimmed(decisions)
        let questionsOut = Self.trimmed(questions)
        return MeetingSummary(
            title: title,
            summary: summaryOut,
            decisions: decisionsOut,
            actions: items,
            questions: questionsOut,
            attendees: Self.trimmed(attendees),
            detectedLanguage: detectedLanguage,
            // WF7: the editor renders extra sections read-only; carry the
            // originals through unchanged so a correction save never drops them.
            extraSections: originalSummary.extraSections,
            // FEAT10: rebuild the index alignment against the edited sections,
            // since the editor freely adds, deletes, and reorders rows.
            evidence: Self.remappedEvidence(
                original: originalSummary,
                summary: summaryOut,
                decisions: decisionsOut,
                questions: questionsOut
            )
        )
    }

    /// FEAT10: the anchors that survive a correction save, per string section.
    private static func remappedEvidence(
        original: MeetingSummary,
        summary: [String],
        decisions: [String],
        questions: [String]
    ) -> [String: [[MeetingSummary.Evidence]]] {
        let edited = ["summary": summary, "decisions": decisions, "questions": questions]
        var out: [String: [[MeetingSummary.Evidence]]] = [:]
        for section in MeetingSummary.evidenceSections {
            guard let anchors = original.evidence[section], let lines = edited[section] else { continue }
            let carried = MeetingSummary.carryEvidence(
                original: originalLines(of: original, section: section),
                anchors: anchors,
                edited: lines
            )
            if carried.contains(where: { !$0.isEmpty }) { out[section] = carried }
        }
        return out
    }

    private static func originalLines(of summary: MeetingSummary, section: String) -> [String] {
        switch section {
        case "summary":   return summary.summary
        case "decisions": return summary.decisions
        case "questions": return summary.questions
        default:          return []
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
            .foregroundStyle(Color(MPColors.fgMuted))
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
