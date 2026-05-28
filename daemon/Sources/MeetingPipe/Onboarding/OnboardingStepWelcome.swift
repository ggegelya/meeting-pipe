import SwiftUI

/// Step 1 (TECH-UX1): welcome + the local-first promise.
struct OnboardingStepWelcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color(MPColors.signal600))
            Text("Meeting notes that never leave your Mac")
                .font(.system(size: 26, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("MeetingPipe detects your calls, records and transcribes them on-device, and writes a summary. Audio capture and transcription stay local; nothing is uploaded unless you configure a publish target.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
