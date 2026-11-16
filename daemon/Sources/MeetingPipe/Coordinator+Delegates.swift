import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import MeetingPipeCore

extension Coordinator: NotifierDelegate {
    // DET18 item 5: the three outcomes resolve on the session against the source it holds, so a
    // pick that lands after the timeout collapsed the panel acts on the offer instead of vanishing.
    func notifier(_ notifier: Notifier, didChooseRecord source: AppSource) {
        session.resolvePromptPick(.record, source: source)
    }

    func notifier(_ notifier: Notifier, didChooseSkip source: AppSource) {
        // Skip (and the prompt's × close, which routes here) = don't record this meeting. The
        // session returns to idle (so meetings in other apps are still detected) and holds this
        // call's prompt off for its span, with DET7's quiet undo surfaces.
        session.resolvePromptPick(.skip, source: source)
    }

    func notifier(_ notifier: Notifier, didChooseAlways source: AppSource) {
        // END20: the body lives on the session, guarded like Record and Skip, so it is testable.
        session.resolvePromptPick(.always, source: source)
    }

    func notifier(_ notifier: Notifier, didOpenPage url: URL) {
        ExternalURLPolicy.openPublishTarget(url)  // SEC30: the sidecar's page_url is checked, not trusted
    }

    func notifier(_ notifier: Notifier, didRequestFailure failure: FailurePresentation, stem: String?) {
        if let stem { openMeeting(stem: stem) }
        else { Task { @MainActor in FailureDialog.show(failure) } }
    }

    func notifier(
        _ notifier: Notifier,
        didRequestEditSummaryFor stem: String,
        recordingsDir: URL
    ) {
        CorrectionWindow.present(stem: stem, recordingsDir: recordingsDir)
    }

    func notifier(
        _ notifier: Notifier,
        didMarkLooksGoodFor stem: String,
        recordingsDir: URL
    ) {
        // Write a verdict-good correction record (self-contained for Phase 3
        // training). Failure is logged, not surfaced: the user already
        // clicked "Looks good" and shouldn't get a sidecar banner.
        let runURL = recordingsDir.appendingPathComponent("\(stem).run.json")
        let summaryURL = recordingsDir.appendingPathComponent("\(stem).summary.json")
        do {
            let run = try CorrectionStore.loadRunSidecar(at: runURL)
            let summary = try CorrectionStore.loadOriginalSummary(at: summaryURL)
            let backend = (run["backend"] as? String) ?? ""
            let model = (run["model"] as? String) ?? ""
            let transcriptPath = (run["transcript_path"] as? String) ?? ""
            let summaryJsonPath = (run["summary_json_path"] as? String) ?? summaryURL.path
            let written = try CorrectionStore.write(
                stem: stem,
                transcriptPath: transcriptPath,
                summaryJsonPath: summaryJsonPath,
                modelId: model,
                backend: backend,
                verdict: .good,
                originalSummary: summary
            )
            Log.writeLine("daemon", "correction saved → \(written.lastPathComponent) verdict=good")
            Log.event(category: "correction", action: "saved", attributes: [
                "stem": stem,
                "verdict": "good",
                "backend": backend,
                "model_id": model,
            ])
        } catch {
            Log.main.warning(
                "Looks good: failed to record correction for \(stem): \(error.localizedDescription)"
            )
            Log.event(category: "correction", action: "failed", attributes: [
                "stem": stem,
                "verdict": "good",
                "error": error.localizedDescription,
            ])
        }
    }

    func notifierDidRequestScreenRecordingSettings(_ notifier: Notifier) {
        SystemAudioCapture.openScreenRecordingSettings()
    }

    func notifierDidRequestAccessibilitySettings(_ notifier: Notifier) {
        // Modern (Ventura+) anchor first, macOS 12 panel URL as fallback;
        // NSWorkspace.open returns false when a URL can't resolve.
        let modern = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(modern) {
            let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess")!
            NSWorkspace.shared.open(legacy)
        }
    }

    func notifierDidRequestStopRecording(_ notifier: Notifier) {
        // One stop entry point shared with hotkey-stop and HUD-stop.
        if case .recording = stateMachine.current { session.toggleManual() }
    }

    func notifierDidRequestKeepRecording(_ notifier: Notifier) {
        // "Keep recording" / banner tap on the silence nudge: restart the
        // silence countdown instead of stopping (TECH-C2).
        session.keepRecordingFromNudge()
    }

    func notifier(_ notifier: Notifier, didRequestStartLate source: AppSource) {
        // UX10: start-late from a skip notification. DET7 lifted this sequence (accepting-
        // state guard, clear the suppression the skip armed, record *with* the source) into
        // `recordAttached`, so the notification, the menu row, the hotkey, and the URL
        // scheme all take one path rather than four copies that can drift apart.
        session.recordAttached(to: source, trigger: "notification")
    }
}

extension Coordinator: MeetingPromptDelegate {
    // The panel's picks: refused visibly when neither the prompt nor its offer is still there.
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecord source: AppSource) {
        if !session.resolvePromptPick(.record, source: source) { NSSound.beep() }
    }
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseSkip source: AppSource) {
        if !session.resolvePromptPick(.skip, source: source) { NSSound.beep() }
    }
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseAlways source: AppSource) {
        if !session.resolvePromptPick(.always, source: source) { NSSound.beep() }
    }
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecordBYO source: AppSource) {
        if !session.resolvePromptPick(.recordBYO, source: source) { NSSound.beep() }
    }

    func meetingPrompt(_ prompt: MeetingPromptWindow, didPauseTimeout paused: Bool) {
        session.setPromptTimeoutPaused(paused)
    }

    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseWorkflow id: UUID?) {
        // Stash the override for the next beginRecording's matcher.
        session.setPendingWorkflowOverride(id)
        Log.event(category: "workflow", action: "override_picked", attributes: [
            "workflow_id": id?.uuidString ?? NSNull(),
        ])
    }
}

extension Coordinator: RecordingHUDDelegate {
    func recordingHUDDidRequestStop(_ hud: RecordingHUDWindow) {
        // One stop entry point shared with manual-stop and hotkey-stop.
        session.toggleManual()
    }

    func recordingHUDDidRequestRetrySystemAudio(_ hud: RecordingHUDWindow) {
        // TECH-UX4: re-attempt SCStream capture; the recorder fires
        // onSystemAudioRecovered to clear the banner on success.
        recorder.retrySystemAudio()
    }

    func recordingHUDDidRequestToggleOffTheRecord(_ hud: RecordingHUDWindow) {
        // MIC14 discoverability (UX23): same entry point the off-the-record hotkey uses. A no-op
        // when idle; `toggleOffTheRecord` calls back into `hud.setOffTheRecord` to reflect the state.
        session.toggleOffTheRecord()
    }

    func recordingHUDDidRequestFlagMoment(_ hud: RecordingHUDWindow) {
        // FEAT8 discoverability (UX46): same entry point the flag-moment hotkey uses, so there is
        // one marker writer. A no-op when idle; `flagMoment` calls back into
        // `hud.acknowledgeFlag(count:)` to acknowledge (UX73).
        session.flagMoment()
    }
}
