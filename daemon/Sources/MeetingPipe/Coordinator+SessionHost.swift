import AVFoundation
import Foundation
import MeetingPipeCore

/// Coordinator is the production `SessionHost` (ARCH4).
///
/// Every member below is either already a stored property under the same name
/// (satisfied implicitly) or a one-line bridge from the stored property to its
/// role-named protocol view. Nothing here makes a decision; if a body here ever
/// grows past `subsystem`, the logic belongs in `MeetingSessionController`.
extension Coordinator: SessionHost {

    // The six UI / I/O collaborators. A protocol requirement cannot be witnessed
    // by a stored property of a different type, so these bridge rather than
    // rename `statusBar` / `notifier` / ... which the rest of the daemon uses.
    var statusUI: any SessionStatusPresenting { statusBar }
    var notifications: any SessionNotifying { notifier }
    var audioRecorder: any SessionRecording { recorder }
    var hud: any SessionHUDPresenting { recordingHUD }
    var prompt: any SessionPromptPresenting { promptWindow }

    /// `jobDispatcher` is an implicitly-unwrapped optional (it is wired after
    /// init). Unwrapping here keeps that wart at the Coordinator boundary instead
    /// of pushing it into the protocol; ARCH4 deliberately leaves the IUO alone.
    var jobs: any SessionJobDispatching { jobDispatcher }

    /// The microphone permission, read live rather than cached: a just-granted
    /// permission has to count without a daemon restart. Behind the protocol so a
    /// test can deny it without touching TCC.
    var micAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
}
