import AVFoundation
import Foundation

/// The one way this app hands a format to `AVAudioNode.installTap`.
///
/// REC12. `installTap(onBus:bufferSize:format:block:)` reports failure by **raising an
/// Objective-C `NSException`**, not by throwing a Swift error, and Swift cannot catch
/// that: there is no `try` that helps and no `catch` that runs, so `objc_terminate` calls
/// `abort()` and the process dies where a `do/catch` one statement below would have
/// survived. All four MeetingPipe crash reports on the owner's machine are that abort
/// (`EXC_CRASH` / `SIGABRT`, `AVAudioEngineImpl::InstallTapOnNode` -> `+[NSException raise:format:]`),
/// every one of them within 50 to 100 ms of a meeting prompt appearing, and they chain:
/// launchd relaunches and the replacement dies at the next prompt it loses the race on.
///
/// **What this rules out, and what it cannot.** `AVAudioEngineImpl::InstallTapOnNode`
/// raises on several conditions and the crash report carries none of them (`asi` holds
/// only "abort() called"), so which one fired is inferred from the call site and the
/// timing rather than read. This guard answers the one that needs no inference and is
/// readable from the format alone: `inputNode.outputFormat(forBus: 0)` returns 0 Hz / 0 ch
/// while the HAL has no usable input, which is the state a meeting client acquiring the
/// device puts it in, and that is the moment the prompt fires. It cannot answer whether
/// the format still agrees with the node's hardware format at the instant `installTap`
/// re-reads it, because no check made beforehand can: on 2026-08-13 the device was AirPods
/// Pro renegotiating to 24000 Hz as the call came up. Closing that last one needs an
/// Objective-C `@try` barrier, which is REC12's open question, not this file.
///
/// A skip is the documented degradation, not a failure. `MicLevelMonitor`'s own contract
/// already says "the callback never fires and the waveform stays flat", and a flat
/// waveform on a decorative prompt animation is worth incomparably less than the process
/// that would otherwise abort under it.
enum GuardedTapInstall {

    /// Pure: whether `installTap` can be handed this format without raising on it.
    ///
    /// `AVAudioFormat` will hold both of these (measured: `AVAudioFormat(standardFormatWithSampleRate: 0,
    /// channels: 1)` returns a live object reporting 0 Hz), so a non-nil format is not
    /// evidence of a usable one.
    static func isInstallable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    /// Install a tap through the guard, or skip it and say so in the logs. Returns whether
    /// `installTap` actually ran, so a caller on the recording path can treat a skip as a
    /// capture failure rather than recording silence.
    ///
    /// `site` names the caller in the event row (`mic_level_monitor` / `meeting_recorder`),
    /// because the two have very different costs: one loses a prompt animation and the
    /// other loses a meeting's mic channel.
    static func install(format: AVAudioFormat, site: String, installTap: () -> Void) -> Bool {
        guard isInstallable(format) else {
            Log.writeLine(
                "recorder",
                "WARN: refusing to install a mic tap at \(site) with an unusable input format "
                    + "(\(format.sampleRate) Hz, \(format.channelCount) ch) - installTap raises on it, "
                    + "and an uncaught ObjC raise aborts the process"
            )
            Log.event(category: "recorder", action: "mic_tap_install_skipped", attributes: [
                "site": site,
                "sample_rate": format.sampleRate,
                "channels": Int(format.channelCount),
            ])
            return false
        }
        installTap()
        return true
    }
}
