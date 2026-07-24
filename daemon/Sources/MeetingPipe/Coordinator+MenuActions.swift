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

    /// Open the read-only Diagnostics window over the event logs (UX20).
    @objc func menuOpenDiagnostics() {
        diagnosticsWindow.show()
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

    /// Deeplink to Preferences -> Integrations, the fix for the "Finish setup"
    /// checklist's Anthropic-key and Notion items (UX22).
    @objc func menuPreferencesIntegrations() {
        preferencesWindow?.show(initial: .integrations)
    }

    /// Start (or resume) the on-device model download from the "Finish setup"
    /// checklist's model item (UX22). Routes through the shared supervisor like
    /// the failed-row remedy, so it works even when the global backend is not
    /// local (a local / NDA workflow under a global anthropic backend).
    @objc func menuFinishSetupDownloadModel() {
        downloadLocalModelNow()
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

    // ARCH4: the twelve one-line `library.foo(stem:)` forwarders that used to sit
    // here are gone. `LibraryWindowModel` holds the `MeetingLibraryService` and
    // calls it directly; a Coordinator hop that only re-typed the arguments was a
    // middle man, not a boundary. What survives below is what is genuinely the
    // Coordinator's: the job dispatcher and the config store.
    //
    // `recentCorrectableMeetings` / `failedMeetingCount` further down stay, because
    // `StatusBarController` (not the Library window) is their caller and it holds a
    // Coordinator, not a service.

    /// Cancel the active pipeline subprocess (TECH-UX5), e.g. from a stalled row.
    func cancelActiveJob() {
        jobDispatcher.cancelActive()
    }

    /// Configured summarization backend, so the UI can gate the local re-run
    /// preview (TECH-A16) to `local` / `apple_intelligence`.
    var summarizationBackend: String {
        configStore?.summarizationBackend ?? "anthropic"
    }

    /// AI8: `summarization.user_label`, the name stamped on the owner's own
    /// diarized speaker. Empty when unset, and empty is meaningful: without it no
    /// transcript can say which voice is the owner's.
    var summarizationUserLabel: String {
        configStore?.summarizationUserLabel ?? ""
    }

    /// Show the first-run onboarding window unless it has already been completed
    /// (TECH-UX1). The flow requests each TCC one at a time, so the caller skips
    /// the startup permission prewarm on a fresh install.
    func presentOnboardingIfNeeded() {
        guard !OnboardingGate.isCompleted else { return }
        // The publish-target step needs both stores; they are always present in
        // production (App builds them) and nil only in headless/test, which has
        // no UI to onboard. Skip rather than show a half-wired flow.
        guard let configStore = configStore, let secretsStore = secretsStore else { return }
        let controller = OnboardingWindowController(deps: OnboardingDependencies(
            workflowStore: workflowStore,
            configStore: configStore,
            secretsStore: secretsStore,
            toggleRecording: { [weak self] in self?.menuStart() },
            isRecording: { [weak self] in self?.recorder.isRecording ?? false },
            localModelPreflight: localModelPreflight,
            onFinish: { [weak self] in self?.onboardingDidComplete() }
        ))
        onboardingController = controller
        controller.show()
    }

    /// UX21: onboarding finished (or was skipped). The framed permissions step
    /// has already requested each TCC one at a time, so instead of re-firing the
    /// startup burst we only warm ScreenCaptureKit (so the first recording never
    /// re-prompts Screen Recording) and re-read the published permission state the
    /// menu bar and Preferences show. Called on the completion of the onboarding
    /// window, the one path `Coordinator.start()` skipped the burst for.
    func onboardingDidComplete() {
        Task.detached { await SystemAudioCapture.prewarm() }
        Task { @MainActor in
            await PermissionsCenter.shared.refreshAll()
            self.statusBar.refreshMenuForPermissionChange()
        }
    }

    /// UX21: the local-model preflight the workflow editor and onboarding's
    /// on-device preset use to offer an inline "Download now" when a workflow will
    /// summarize on-device but the MLX model is not yet cached. Backed by the
    /// daemon's one long-lived `ModelDownloadSupervisor` (via ConfigRefresh), so
    /// the download persists past a transient sheet and its progress shows in the
    /// menu bar like the eager prefetch.
    var localModelPreflight: LocalModelPreflight {
        configRefresh.makeLocalModelPreflight()
    }

    /// UX21: start (or resume) a download of the configured local model on demand,
    /// independent of the global backend. The failed-row "Download model" remedy
    /// and the inline affordance both route here.
    func downloadLocalModelNow() {
        configRefresh.downloadLocalModelNow()
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

    /// Assemble the "Finish setup" checklist snapshot (UX22) from the same
    /// signals `mp doctor` reads: config, workflows, secrets, permissions, and
    /// the local-model cache. Called by `StatusBarController` on each menu
    /// rebuild; all in-memory except `isModelMissing()` (a bounded cache scan).
    /// Nil stores (headless/test) read as "configured", so no phantom items.
    func setupChecklistInputs() -> SetupChecklist.Inputs {
        let center = PermissionsCenter.shared
        let globalBackend = configStore?.summarizationBackend ?? "anthropic"
        let workflows = workflowStore.workflows
        return SetupChecklist.Inputs(
            regulatedMode: configStore?.regulatedMode ?? false,
            globalBackend: globalBackend,
            globalSinks: configStore?.outputSinks ?? ["notion"],
            // A nil backend pin inherits the global backend; resolve it here so
            // the pure model never has to know about inheritance.
            workflowBackends: workflows.map { $0.effectiveBackend?.rawValue ?? globalBackend },
            workflowSinks: workflows.map { $0.effectiveSinkTypeNames },
            anthropicKeyPresent: secretsStore.map { !$0.anthropicAPIKey.isEmpty } ?? true,
            notionTokenPresent: secretsStore.map { !$0.notionToken.isEmpty } ?? true,
            notionDatabaseIdPresent: configStore.map { !$0.notionDatabaseId.isEmpty } ?? true,
            localModelMissing: localModelPreflight.isModelMissing(),
            hasPermissionIssue: StatusBarModel.hasPendingPermissionIssue(.init(
                microphone: center.microphone,
                screenRecording: center.screenRecording,
                accessibility: center.accessibility
            ))
        )
    }
}
