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
    /// Toggle a manual recording (start, then stop) for the test-recording step.
    let toggleRecording: () -> Void
    /// True while a recording is in flight, so the test step can reflect state.
    let isRecording: () -> Bool
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

/// Step navigator. Welcome -> Permissions -> Workflow -> Test recording, with a
/// Skip that completes onboarding from any step (power-user escape hatch).
struct OnboardingRootView: View {
    let deps: OnboardingDependencies
    let onComplete: () -> Void

    @State private var step = 0
    private static let stepCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Step \(step + 1) of \(Self.stepCount)")
                    .font(.system(size: 11, weight: .semibold))
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
                case 2: OnboardingStepWorkflow(workflowStore: deps.workflowStore)
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
