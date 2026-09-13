import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import MeetingPipeCore

extension Coordinator: NotifierDelegate {
    func notifier(_ notifier: Notifier, didChooseRecord source: AppSource) {
        guard case .prompting(let pending) = stateMachine.current, pending == source else { return }
        session.beginRecording(source: source, summaryMode: .auto)
    }

    func notifier(_ notifier: Notifier, didChooseSkip source: AppSource) {
        guard case .prompting(let pending) = stateMachine.current, pending == source else { return }
        // Skip (and the prompt's × close, which routes here) = don't record this meeting.
        // Return to idle (so meetings in other apps are still detected) and cool down this
        // bundle so a post-call mic flicker - or the same still-live meeting - can't
        // re-prompt immediately.
        stateMachine.abandonPrompt(source: source)
        // DET7: an explicit skip now gets the same two quiet surfaces a timeout-skip has
        // had since UX10, because the way back in is the whole point of this task and the
        // owner's report was about an explicit skip. The menu-bar label reads the skip
        // latch and collapses to Idle on its own once the meeting ends (~15 s), and it is
        // what makes the "Record this <app> meeting" row legible in context. The banner is
        // silent here: the user chose this, so it is an undo affordance, not an alert.
        let bundleID = source.bundleID
        statusBar.setSuppressed(source) { [weak self] in
            self?.stateMachine.isSkipLatched(bundleID: bundleID) ?? false
        }
        notifier.notifySkippedMeeting(source: source, origin: .dismissed)
        Log.writeLine("daemon", "user skipped (\(source.bundleID))")
        Log.event(category: "coordinator", action: "user_skipped", attributes: [
            "bundle_id": source.bundleID,
        ])
    }

    func notifier(_ notifier: Notifier, didChooseAlways source: AppSource) {
        consent.setAutoConsented(bundleID: source.bundleID, value: true)
        Log.writeLine("daemon", "user always-consented (\(source.bundleID))")
        Log.event(category: "coordinator", action: "user_consented_always", attributes: [
            "bundle_id": source.bundleID,
        ])
        // Explicit "always": clear every suppression (cooldown + skip latch) so a
        // stale skip/end can't block it (as with the manual hotkey path).
        stateMachine.clearSuppression(bundleID: source.bundleID)
        session.beginRecording(source: source, summaryMode: .auto)
    }

    func notifier(_ notifier: Notifier, didOpenPage url: URL) {
        NSWorkspace.shared.open(url)
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
    // Panel and banner share one handler per outcome.
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecord source: AppSource) {
        notifier(notifier, didChooseRecord: source)
    }
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseSkip source: AppSource) {
        notifier(notifier, didChooseSkip: source)
    }
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseAlways source: AppSource) {
        notifier(notifier, didChooseAlways: source)
    }
    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseRecordBYO source: AppSource) {
        guard case .prompting(let pending) = stateMachine.current, pending == source else { return }
        session.beginRecording(source: source, summaryMode: .byo)
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
