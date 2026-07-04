import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import MeetingPipeCore

extension Coordinator {
    // MARK: Menu actions

    @objc func menuStart() { session.toggleManual() }
    @objc func menuStop() { session.toggleManual() }

    @objc func menuOpenLogs() {
        NSWorkspace.shared.open(Log.logsDir)
    }

    @objc func menuOpenRecordings() {
        let dir = liveOutputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func menuPreferences() {
        preferencesWindow?.show()
    }

    /// Deeplink to the Preferences Permissions section (from the warning
    /// row and the mic-permission-blocked path).
    @objc func menuPreferencesPermissions() {
        preferencesWindow?.show(initial: .permissions)
    }

    /// Retry a failed model prefetch (LOCAL1), from the failed download row.
    /// Re-runs the same eager-prefetch decision; the supervisor re-spawns
    /// `mp prefetch-model` (a partial cache resumes), or short-circuits to
    /// completed if the cache turns out whole.
    @objc func menuRetryModelDownload() {
        configRefresh.ensureModelPrefetchIfNeeded()
    }

    @objc func menuOpenLibrary() {
        libraryWindow.show()
    }

    @objc func menuQuickFind() {
        quickFindWindow.show()
    }

    /// Open the Library (TECH-WF5): a findable top-level home for workflow
    /// management. The WORKFLOWS rail there is the manager (edit any workflow, or
    /// "+ New workflow"). Deliberately does NOT auto-open the New sheet, which
    /// persists an orphan "Untitled workflow" stub if closed without naming.
    @objc func menuManageWorkflows() {
        libraryWindow.show()
    }

    /// Open the Library window and select the given stem (from Quick Find).
    func openMeeting(stem: String) {
        libraryModel.pendingSelection = stem
        libraryWindow.show()
    }

    func retryMeeting(stem: String) -> Result<Void, Error> {
        library.retryMeeting(stem: stem)
    }

    func regenerateMeeting(
        stem: String,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        library.regenerateMeeting(stem: stem, completion: completion)
    }

    func softDeleteMeeting(stem: String) -> Result<Void, Error> {
        library.softDeleteMeeting(stem: stem)
    }

    func exportMeeting(stem: String, to destination: URL) -> Result<Int, Error> {
        library.exportMeeting(stem: stem, to: destination)
    }

    func republishMeeting(
        stem: String,
        completion: @escaping (Result<URL?, Error>) -> Void
    ) {
        library.republishMeeting(stem: stem, completion: completion)
    }

    func publishFromPaste(
        stem: String,
        summaryText: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        library.publishFromPaste(stem: stem, summaryText: summaryText, completion: completion)
    }

    /// Ask a natural-language question across the library (AI3). Forwards to the
    /// library service, which spawns `mp ask` on-device.
    func askMeetings(question: String, completion: @escaping (Result<AskAnswer, Error>) -> Void) {
        library.askMeetings(question: question, completion: completion)
    }

    /// Cancel the active pipeline subprocess (TECH-UX5), e.g. from a stalled row.
    func cancelActiveJob() {
        jobDispatcher.cancelActive()
    }

    // MARK: - Local re-run summary preview (TECH-A16)

    /// Configured summarization backend, so the UI can gate the local re-run
    /// preview to `local` / `apple_intelligence`.
    var summarizationBackend: String {
        configStore?.summarizationBackend ?? "anthropic"
    }

    func previewSummary(stem: String, contextOverride: String? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        library.previewSummary(stem: stem, contextOverride: contextOverride, completion: completion)
    }

    /// TECH-FEAT7: passthrough so the Library can prefill the reprocess editor.
    func effectiveContextPrompt(stem: String) -> String {
        library.effectiveContextPrompt(stem: stem)
    }

    @discardableResult
    func keepCandidateSummary(stem: String) -> Result<Void, Error> {
        library.keepCandidate(stem: stem)
    }

    func discardCandidateSummary(stem: String) {
        library.discardCandidate(stem: stem)
    }

    /// Show the first-run onboarding window unless it has already been completed
    /// (TECH-UX1). The flow requests each TCC one at a time, so the caller skips
    /// the startup permission prewarm on a fresh install.
    func presentOnboardingIfNeeded() {
        guard !OnboardingGate.isCompleted else { return }
        let controller = OnboardingWindowController(deps: OnboardingDependencies(
            workflowStore: workflowStore,
            toggleRecording: { [weak self] in self?.menuStart() },
            isRecording: { [weak self] in self?.recorder.isRecording ?? false }
        ))
        onboardingController = controller
        controller.show()
    }

    @objc func menuOpenScreenRecordingSettings() {
        SystemAudioCapture.openScreenRecordingSettings()
    }

    /// "Quit (do not relaunch)" (TECH-UX7): a one-off quit that suppresses the
    /// LaunchAgent relaunch even when the auto-restart preference is on.
    @objc func menuQuitWithoutRelaunch() {
        AppDelegate.pendingRelaunchOverride = false
        NSApp.terminate(nil)
    }

    /// Open the correction sheet for the stem in the menu item's
    /// `representedObject` (submenu built from `recentCorrectableMeetings()`).
    @objc func menuRecentMeeting(_ sender: NSMenuItem) {
        guard let stem = sender.representedObject as? String else { return }
        CorrectionWindow.present(stem: stem, recordingsDir: liveOutputDir)
    }

    func recentCorrectableMeetings(limit: Int = 10) -> [(stem: String, displayName: String)] {
        library.recentCorrectableMeetings(limit: limit)
    }

    func failedMeetingCount() -> Int {
        library.failedMeetingCount()
    }
}
