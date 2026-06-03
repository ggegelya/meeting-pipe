import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import MeetingPipeCore

extension Coordinator {

    func handleMeetingStarted(source: AppSource) {
        guard stateMachine.isAcceptingPrompts else { return }

        // Auto-consent (config or persisted "Always").
        if liveAutoConsentApps.contains(source.bundleID) ||
           consent.isAutoConsented(bundleID: source.bundleID) {
            Log.writeLine("daemon", "auto-consent → recording (\(source.bundleID))")
            Log.event(category: "coordinator", action: "auto_consent", attributes: [
                "bundle_id": source.bundleID,
            ])
            beginRecording(source: source, summaryMode: .auto)
            return
        }

        stateMachine.setPrompting(source: source)
        statusBar.setPrompting(source)
        // The on-screen panel is the primary surface (not suppressed under
        // Focus modes); the banner stays off by default. Pass the resolved
        // workflow + full set so the chip and override menu render (TECH-B5).
        let promptWorkflow = workflowForPrompt(source: source)
        promptWindow.present(
            source: source,
            workflow: promptWorkflow,
            availableWorkflows: workflowStore.workflows,
            autoDismissAfter: livePromptTimeoutSec
        )
        startPromptTimeout(for: source)
        Log.writeLine("daemon", "meeting detected → prompting (\(source.bundleID))")
        Log.event(category: "coordinator", action: "prompt_shown", attributes: [
            "bundle_id": source.bundleID,
            "display_name": source.displayName,
            "timeout_sec": livePromptTimeoutSec,
        ])
    }

    func handleMeetingEnded() {
        switch stateMachine.current {
        case .recording(let file, let src, let mode):
            stopRecording(file: file, source: src, summaryMode: mode)
        case .prompting, .suppressed:
            handleMeetingEndedDuringPrompt()
        default:
            break
        }
    }

    /// Dismiss a stale prompt when the meeting ends before the user
    /// answers. Reached via the lifecycle `.ended` verdict.
    func handleMeetingEndedDuringPrompt() {
        switch stateMachine.current {
        case .prompting, .suppressed:
            stateMachine.cancelPromptTimeout()
            promptWindow.dismiss()
            stateMachine.setIdle()
            statusBar.setIdle()
        default:
            break
        }
    }
}

extension Coordinator: NotifierDelegate {
    func notifier(_ notifier: Notifier, didChooseRecord source: AppSource) {
        guard case .prompting(let pending) = stateMachine.current, pending == source else { return }
        beginRecording(source: source, summaryMode: .auto)
    }

    func notifier(_ notifier: Notifier, didChooseSkip source: AppSource) {
        guard case .prompting(let pending) = stateMachine.current, pending == source else { return }
        stateMachine.cancelPromptTimeout()
        stateMachine.setSuppressed(source: source)
        statusBar.setIdle()
        // Skip = don't ask again for this call: also cool down the bundle so
        // a post-call mic flicker can't re-prompt once suppression lifts.
        stateMachine.recordCooldownEnd(bundleID: source.bundleID)
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
        // Explicit "always": clear the cooldown so a stale skip/end can't
        // block it (as with the manual hotkey path).
        stateMachine.clearCooldown(bundleID: source.bundleID)
        beginRecording(source: source, summaryMode: .auto)
    }

    func notifier(_ notifier: Notifier, didOpenPage url: URL) {
        NSWorkspace.shared.open(url)
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
        if case .recording = stateMachine.current { toggleManual() }
    }

    func notifierDidRequestKeepRecording(_ notifier: Notifier) {
        // "Keep recording" / banner tap on the silence nudge: restart the
        // silence countdown instead of stopping (TECH-C2).
        keepRecordingFromNudge()
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
        beginRecording(source: source, summaryMode: .byo)
    }

    func meetingPrompt(_ prompt: MeetingPromptWindow, didChooseWorkflow id: UUID?) {
        // Stash the override for the next beginRecording's matcher.
        setPendingWorkflowOverride(id)
        Log.event(category: "workflow", action: "override_picked", attributes: [
            "workflow_id": id?.uuidString ?? NSNull(),
        ])
    }
}

extension Coordinator: RecordingHUDDelegate {
    func recordingHUDDidRequestStop(_ hud: RecordingHUDWindow) {
        // One stop entry point shared with manual-stop and hotkey-stop.
        toggleManual()
    }

    func recordingHUDDidRequestRetrySystemAudio(_ hud: RecordingHUDWindow) {
        // TECH-UX4: re-attempt SCStream capture; the recorder fires
        // onSystemAudioRecovered to clear the banner on success.
        recorder.retrySystemAudio()
    }
}
