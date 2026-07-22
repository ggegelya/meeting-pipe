import AppKit
import SwiftUI

/// First-run gate (TECH-UX1). A single `UserDefaults` bool decides whether the
/// onboarding window shows on launch. Pure/testable; `reset()` lets `mp doctor`
/// (or a future "redo setup") replay the flow.
enum OnboardingGate {
    static let key = "mp.onboarding.completed"
    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markCompleted() { UserDefaults.standard.set(true, forKey: key) }
    static func reset() { UserDefaults.standard.set(false, forKey: key) }
}

/// Dependencies the onboarding flow needs from the app, injected so the window
/// stays decoupled from the Coordinator.
struct OnboardingDependencies {
    let workflowStore: WorkflowStore
    /// UX22: the publish-target step binds the Notion database picker to the
    /// global config and the token field to the secrets store, so a clean-Mac
    /// user sets their publish target in-app instead of hand-editing config.toml.
    let configStore: ConfigStore
    let secretsStore: SecretsStore
    /// Toggle a manual recording (start, then stop) for the test-recording step.
    let toggleRecording: () -> Void
    /// True while a recording is in flight, so the test step can reflect state.
    let isRecording: () -> Bool
    /// UX21: lets the on-device workflow preset offer an inline model download
    /// when the picked backend is local but the MLX model is not yet cached.
    let localModelPreflight: LocalModelPreflight
    /// UX21: called once onboarding is completed or skipped, so the app can warm
    /// ScreenCaptureKit and re-read permission state in the startup burst's place
    /// (the burst is gated off during onboarding).
    let onFinish: () -> Void
}

/// Hosts the 4-step first-run flow in a borderless-titlebar window (TECH-UX1).
/// Mirrors `LibraryWindow`'s `NSHostingController` + `NSWindow` pattern.
final class OnboardingWindowController {
    private var window: NSWindow?
    private let deps: OnboardingDependencies

    init(deps: OnboardingDependencies) {
        self.deps = deps
    }

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = OnboardingRootView(deps: deps) { [weak self] in
            OnboardingGate.markCompleted()
            // UX21: stands in for the startup TCC burst that `Coordinator.start()`
            // gated off while onboarding was open (prewarm + refresh, not a re-prompt).
            self?.deps.onFinish()
            self?.close()
        }
        let host = NSHostingController(rootView: MPControlAccent(root))
        let w = NSWindow(contentViewController: host)
        w.title = "Welcome to MeetingPipe"
        w.styleMask = [.titled, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: 560, height: 520))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

/// Step navigator. Welcome -> Permissions -> Workflow -> Publish target -> Test
/// recording, with a Skip that completes onboarding from any step (power-user
/// escape hatch).
struct OnboardingRootView: View {
    let deps: OnboardingDependencies
    let onComplete: () -> Void

    @State private var step = 0
    private static let stepCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Step \(step + 1) of \(Self.stepCount)")
                    .font(.mpTextXS.weight(.semibold))
                    .tracking(0.08 * 11)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(MPColors.fgMuted))
                Spacer()
                Button("Skip setup") { onComplete() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            Group {
                switch step {
                case 0: OnboardingStepWelcome()
                case 1: OnboardingStepPermissions()
                case 2: OnboardingStepWorkflow(
                    workflowStore: deps.workflowStore,
                    localModelPreflight: deps.localModelPreflight
                )
                case 3: OnboardingStepPublishTarget(
                    store: deps.configStore,
                    secrets: deps.secretsStore
                )
                default: OnboardingStepTest(toggleRecording: deps.toggleRecording, isRecording: deps.isRecording)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)

            Divider()
            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Spacer()
                Button(step == Self.stepCount - 1 ? "Finish" : "Continue") {
                    if step == Self.stepCount - 1 {
                        onComplete()
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(width: 560, height: 520)
    }
}
