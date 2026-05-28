import SwiftUI

/// Step 4 (TECH-UX1): a 60-second manual test recording so the user proves the
/// capture path before trusting a real meeting to it.
struct OnboardingStepTest: View {
    let toggleRecording: () -> Void
    let isRecording: () -> Bool

    @State private var recording = false
    @State private var remaining = 60
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try a test recording")
                .font(.system(size: 22, weight: .semibold))
            Text("Record about a minute and say a few words. When it finishes, the transcript and summary appear in your Library, so you know the whole path works before a real meeting.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(recording ? "Stop test recording" : "Start 60-second test") {
                    toggle()
                }
                .controlSize(.large)
                if recording {
                    Text("Recording \(remaining)s")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Color(MPColors.pulse600))
                }
            }

            Text("Optional. You can skip this and record your first real meeting whenever you're ready.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(tick) { _ in
            guard recording else { return }
            // Reconcile with the real recorder: a silence backstop or manual
            // stop elsewhere ends the recording out from under us.
            if !isRecording() {
                recording = false
                return
            }
            remaining -= 1
            if remaining <= 0 {
                toggleRecording()
                recording = false
            }
        }
    }

    private func toggle() {
        toggleRecording()
        if recording {
            recording = false
        } else {
            recording = true
            remaining = 60
        }
    }
}
