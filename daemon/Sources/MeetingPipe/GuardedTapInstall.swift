import AVFoundation
import Foundation
import MeetingPipeObjC
import os

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
/// **Two layers, and they answer different things.** The format check (item 1) answers the
/// raise condition readable without inference: `inputNode.outputFormat(forBus: 0)` returns
/// 0 Hz / 0 ch while the HAL has no usable input, which is the state a meeting client
/// acquiring the device puts it in, and that is the moment the prompt fires. It cannot
/// answer whether the format still agrees with the node's hardware format at the instant
/// `installTap` re-reads it, because no check made beforehand can: on 2026-08-13 the device
/// was AirPods Pro renegotiating to 24000 Hz as the call came up. The `@try` barrier (item
/// 2, `MPRunCatchingObjCException` in the `MeetingPipeObjC` target) is what covers the rest,
/// and it is a barrier rather than a check precisely because the remainder is a race and
/// not a state.
///
/// **A caught raise is terminal for the engine, and that is enforced here rather than asked
/// of callers.** Catching an `NSException` out of AVFAudio's C++ frames leaves the engine
/// unspecified: the raise unwound through Swift frames whose cleanups did not run, part-way
/// through whatever `InstallTapOnNode` was doing. So the engine is condemned on the way out,
/// and this seam refuses to hand a condemned engine another tap for as long as that engine
/// exists. A barrier used as "try again" would be worse than the abort it replaces, and
/// leaving that to a comment is how it would have become one: `MeetingRecorder.recoverCapture`
/// runs on every device change, so its caller has a live retry path into this call. (The
/// prompt's level meter, the other caller and the one that crashed, was removed by REC18.)
///
/// The way back is a **new** engine, which is why the condemnation is keyed on engine
/// identity and held weakly rather than being a global latch. `MeetingRecorder` already
/// replaces its engine on the abandoned-start path and now does the same for a condemned
/// one.
enum GuardedTapInstall {

    /// What happened at the seam. Four cases because two of them are retryable on this
    /// engine and two are not, and a `Bool` cannot say which: item 1's refusal has to stay
    /// retryable (a transient format during a route change is exactly the case it exists
    /// for) while a caught raise must never be retried on the same engine.
    enum Outcome: Equatable {
        /// The tap is on the bus.
        case installed
        /// Refused on the format alone, before `installTap` was reached. Nothing was
        /// touched, so a later attempt with a usable format is free to run on this engine.
        case refusedFormat
        /// Refused because an earlier raise condemned this engine. Terminal, always: the
        /// only way forward is a different engine.
        case refusedCondemnedEngine
        /// `installTap` raised and the barrier caught it. The engine is condemned as of
        /// now, so this is the last tap it will be offered.
        case raised
        /// REC29: the macOS 27 install reported failure as an error rather than a raise.
        /// Handled exactly as `raised` (the engine is condemned, the caller takes the
        /// fresh-engine path), kept apart only so the log says which of the two it was.
        case failed

        var isInstalled: Bool { self == .installed }

        /// Whether the caller has to replace its engine before the next attempt can do
        /// anything but refuse. `MeetingRecorder` acts on this.
        var requiresFreshEngine: Bool {
            self == .raised || self == .failed || self == .refusedCondemnedEngine
        }

        /// The `reason` an event row gets for a failed device-change recovery, so the two
        /// failures stay distinguishable in the log a year from now.
        var recoveryReason: String {
            switch self {
            case .installed: return "installed"
            case .refusedFormat: return "tap_format_unusable"
            case .refusedCondemnedEngine: return "tap_engine_condemned"
            case .raised: return "tap_install_raised"
            case .failed: return "tap_install_failed"
            }
        }
    }

    /// Pure: whether `installTap` can be handed this format without raising on it.
    ///
    /// `AVAudioFormat` will hold both of these (measured: `AVAudioFormat(standardFormatWithSampleRate: 0,
    /// channels: 1)` returns a live object reporting 0 Hz), so a non-nil format is not
    /// evidence of a usable one.
    static func isInstallable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    /// Install a tap through the guard and the barrier, or refuse and say so in the logs.
    ///
    /// `engine` is the identity the terminal contract is keyed on; it is not otherwise
    /// touched here. `site` names the caller in the event row (`mic_level_monitor` /
    /// `meeting_recorder`), because the two have very different costs: one loses a prompt
    /// animation and the other loses a meeting's mic channel.
    static func install(
        format: AVAudioFormat,
        site: String,
        engine: AVAudioEngine,
        installTap: () -> Void
    ) -> Outcome {
        // Not `withoutActuallyEscaping` into `.raising`: a raise unwinds past its release, and
        // the escape check then traps (measured). The core takes a non-escaping body instead.
        run(format: format, site: site, engine: engine) { installTap(); return nil }
    }

    /// The two shapes of `installTap` call, chosen once at the call site by
    /// `inputTapInstaller` under a pure `#available` check and injectable as either in tests.
    enum Installer {
        /// macOS 27 and later: `__installTap(...error:block:)`, which reports failure as an error.
        case throwing(() throws -> Void)
        /// macOS 14 to 26: `installTap(onBus:bufferSize:format:block:)`, which raises.
        case raising(() -> Void)
    }

    /// REC29: the `installTap` this OS has. On macOS 27 and later the SDK 27 call that returns
    /// an error (the old one is deprecated there); below 27, the old one. Both go through the
    /// same barrier in `install`, because the error variants do not promise never to raise:
    /// measured 2026-11-17 on macOS 27.2, `__installTap` returned errors for a second tap on a
    /// bus (-10863) and `connectNode` for a 0 Hz format (-10868), the cases that used to raise,
    /// but `playAudio()` on a node with no engine still raised.
    ///
    /// `compiler(>=6.4)` is the SDK gate: the call does not exist in the SDK CI's macos-15
    /// runner compiles against, and `#available` is a runtime check only. Swift 6.4 is the
    /// toolchain that ships with SDK 27.
    static func inputTapInstaller(
        _ node: AVAudioNode, bufferSize: AVAudioFrameCount, format: AVAudioFormat,
        block: @escaping AVAudioNodeTapBlock
    ) -> Installer {
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            return .throwing {
                try node.__installTap(onBus: 0, bufferSize: bufferSize, format: format, error: (), block: block)
            }
        } else {
            return .raising { node.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block) }
        }
        #else
        return .raising { node.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block) }
        #endif
    }

    /// Install a tap through the guard and the barrier with whichever `Installer` this OS takes.
    static func install(
        format: AVAudioFormat,
        site: String,
        engine: AVAudioEngine,
        installer: Installer
    ) -> Outcome {
        run(format: format, site: site, engine: engine) {
            switch installer {
            case .raising(let call):
                call()
                return nil
            case .throwing(let call):
                do { try call() } catch { return error }
                return nil
            }
        }
    }

    /// The guards, then `body` inside the barrier. `body` answers the error a throwing install
    /// reported, or nil; a raise never returns through it.
    private static func run(
        format: AVAudioFormat,
        site: String,
        engine: AVAudioEngine,
        body: () -> Error?
    ) -> Outcome {
        guard !isCondemned(engine) else {
            Log.writeLine(
                "recorder",
                "WARN: refusing to install a mic tap at \(site) on an engine a previous "
                    + "installTap raise condemned - it needs replacing, not retrying"
            )
            Log.event(category: "recorder", action: "mic_tap_install_refused", attributes: [
                "site": site,
                "reason": "engine_condemned",
            ])
            return .refusedCondemnedEngine
        }

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
            return .refusedFormat
        }

        var thrown: Error?
        let raise = MPRunCatchingObjCException { thrown = body() }
        if raise == nil, let thrown {
            // REC29: the same terminal handling as a caught raise, so both callers take the
            // fresh-engine path they already take for one. A clean error leaves the engine in
            // a defined state where a raise does not, but the race that produced it (a format
            // moving under the install) is the same one, and REC15 measured that a fresh read
            // on a fresh engine is what succeeds.
            condemn(engine)
            let detail = String(describing: thrown)
            Log.writeLine(
                "recorder",
                "ERROR: installTap failed at \(site) with an error: \(detail) "
                    + "(format \(format.sampleRate) Hz, \(format.channelCount) ch). The engine is "
                    + "condemned and this tap is not retried on it."
            )
            Log.event(category: "recorder", action: "mic_tap_install_failed", attributes: [
                "site": site,
                "reason": detail,
                "sample_rate": format.sampleRate,
                "channels": Int(format.channelCount),
            ])
            return .failed
        }
        guard let raise else { return .installed }

        // Condemn first, log second. Everything below this line is best-effort reporting,
        // and the one thing that must not be skipped is making sure nobody hands this
        // engine another tap.
        condemn(engine)
        Log.writeLine(
            "recorder",
            "ERROR: installTap raised at \(site) and the barrier caught it: \(raise) "
                + "(format \(format.sampleRate) Hz, \(format.channelCount) ch). The process "
                + "survived, the engine is condemned, and this tap is not retried on it."
        )
        Log.event(category: "recorder", action: "mic_tap_install_raised", attributes: [
            "site": site,
            "reason": raise,
            "sample_rate": format.sampleRate,
            "channels": Int(format.channelCount),
        ])
        return .raised
    }

    // MARK: - The terminal contract

    /// Engines a caught raise has retired. Weak on purpose, so the condemnation lives
    /// exactly as long as the engine does: an engine that is released takes its record
    /// with it, and a replacement allocated at the same address is not tarred with it.
    /// Locked because the two callers meter and record on different private queues.
    private static let condemnedEngines = OSAllocatedUnfairLock(
        uncheckedState: NSHashTable<AVAudioEngine>.weakObjects()
    )

    /// Whether a raise has already retired this engine. Public so a caller holding a
    /// replaceable engine can swap it *before* an attempt rather than spending one on a
    /// refusal: `MeetingRecorder.start` does exactly that, which is what keeps a raise
    /// during one meeting's device-change recovery from costing the next meeting's start.
    static func isCondemned(_ engine: AVAudioEngine) -> Bool {
        condemnedEngines.withLock { $0.contains(engine) }
    }

    private static func condemn(_ engine: AVAudioEngine) {
        condemnedEngines.withLock { $0.add(engine) }
    }
}
