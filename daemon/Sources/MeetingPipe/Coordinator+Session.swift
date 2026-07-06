import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import MeetingPipeCore

extension Coordinator {
    // MARK: Live-config readers
    //
    // Prefer the ConfigStore's current value over the boot-time `config`
    // snapshot, so Preferences edits apply without a daemon restart. Read by
    // the MeetingSessionController (TECH-ARCH2) via `coordinator.liveX` and by
    // the startup wiring in Coordinator.

    var liveOutputDir: URL {
        guard let raw = configStore?.outputDirPath else { return config.recording.outputDir }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    var liveAutoConsentApps: [String] {
        configStore?.autoConsentApps ?? config.recording.autoConsentApps
    }

    var livePromptTimeoutSec: Double {
        configStore?.promptTimeoutSec ?? config.detection.promptTimeoutSec
    }

    var liveRepromptCooldownSec: Double {
        configStore?.repromptCooldownSec ?? config.detection.repromptCooldownSec
    }

    var liveHonorAppMute: Bool {
        configStore?.honorAppMute ?? config.recording.honorAppMute
    }

    var liveVoiceProcessing: Bool {
        // Recorder binds this at start time, so live edits only take
        // effect on the next recording. The Preferences sublabel
        // documents that.
        configStore?.voiceProcessing ?? config.recording.voiceProcessing
    }

    var liveManualHotkey: String {
        configStore?.manualHotkey ?? config.detection.manualHotkey
    }

    var liveForceStopHotkey: String {
        configStore?.forceStopHotkey ?? config.detection.forceStopHotkey
    }

    var liveFlagMomentHotkey: String {
        configStore?.flagMomentHotkey ?? config.detection.flagMomentHotkey
    }
}
