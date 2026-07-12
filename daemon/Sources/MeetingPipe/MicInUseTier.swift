import Foundation

/// DET1: the mic-in-use catch-all detection tier. Detection is otherwise whitelist-only, so a
/// WebRTC call on a domain absent from `meeting_apps.toml` (the lemon.io class), FaceTime, Discord,
/// WhatsApp, or Telegram never prompts. When the mic stays held by another process for a sustained
/// dwell AND no whitelist candidate won the scan, this raises one quiet generic prompt naming the
/// plausible holder. Permission-light by design: it needs neither Accessibility nor Screen
/// Recording, so it also gives the permission-degraded matrix a working tier instead of silence.
///
/// The decision is pure and unit-tested; the host (`MeetingDiscoveryWatcher`) supplies the dwell,
/// the scan outcome, and the resolved bundle sets, and routes the returned source through the
/// normal prompt path so the skip-latch, reprompt cooldown, and auto-consent all still apply.
///
/// Thresholds are deliberately conservative and PROVISIONAL: the spec pins tuning to DET3 data (the
/// dictation / voice-memo false-positive class must be measured before the dwell is lowered), so
/// this ships with a long dwell and leans on the plausible-app gate rather than aggressive timing.
enum MicInUseTier {

    /// Default sustained-dwell threshold before a mic-in-use prompt may fire (seconds). Long on
    /// purpose: a brief mic grab (a notification sound capture, a dictation burst) must not prompt.
    /// Provisional pending DET3 measurement (see the type doc).
    static let defaultDwellSec: TimeInterval = 30

    /// Decide whether a sustained mic-busy dwell with no whitelist winner should raise a generic
    /// prompt for `bundleID`. Pure.
    ///
    /// - Parameters:
    ///   - dwellSec: how long the current mic-busy span has been open.
    ///   - threshold: the sustained-dwell bar (`defaultDwellSec` in production).
    ///   - hasScannerWinner: whether the discovery scan produced a confident winner. When it did,
    ///     the normal path handles the meeting and this tier stays silent (guardrail: never compete
    ///     with, or double-prompt over, a whitelist detection).
    ///   - bundleID / displayName: the plausible mic holder (the app frontmost when the mic was
    ///     grabbed, the same attribution DET3 records).
    ///   - kind: `.browser` for a browser bundle, else `.native` — sets the synthesized source kind.
    ///   - plausibleBundles: browser + mic-plausible bundles (native whitelist apps are excluded -
    ///     discovery owns them; see the watcher). Only a plausibly meeting-capable app is named; a
    ///     random app holding the mic (or dictation into a non-meeting app, whose frontmost is that
    ///     app) is not, which keeps the register quiet and covers the "music / dictation do not
    ///     prompt" acceptance without a brittle denylist.
    static func decide(
        dwellSec: TimeInterval,
        threshold: TimeInterval,
        hasScannerWinner: Bool,
        bundleID: String?,
        displayName: String?,
        kind: AppSourceKind,
        plausibleBundles: Set<String>
    ) -> AppSource? {
        guard dwellSec >= threshold, !hasScannerWinner, let bundle = bundleID else { return nil }
        guard plausibleBundles.contains(bundle) else { return nil }
        return AppSource(bundleID: bundle, displayName: displayName ?? bundle, kind: kind)
    }
}
