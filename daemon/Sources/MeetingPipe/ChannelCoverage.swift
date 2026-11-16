import Foundation

/// REC30: whether each capture channel covers the recording it belongs to, and where the audio
/// went when one does not.
///
/// `RecordingDurationParity` compares the merged final with the wallclock, and REC9's merge pads
/// both legs to the target, so a channel that is short inside the final is invisible to it. In the
/// field, `20261015-170719`'s system channel ended 15.9 s short of the mic beyond its 33.21 s head
/// loss and `20261015-144207`'s 14.4 s short, both reading 99% parity with no stall, loss or
/// parity event. This compares each channel with the capture span and with the other, and uses
/// each channel's first and last buffer and delivered seconds to name the cause.
///
/// Pure and static, beside `RecordingDurationParity`. All times are seconds from the recording's
/// start (`startedAtUptime`); the span ends at capture stop, not after the merge.
enum ChannelCoverage {

    /// Above every era-3 recording and the field baselines' p90 (channel gap 0.52 s, mic
    /// shortfall 0.15 s); the head offset's p90 is 4.24 s, so a late system start is logged often.
    static let eventThresholdSec = 2.0
    /// Separates the 14 to 33 s field cases from the 2.0 to 3.7 s ones and from REC33's suspected
    /// 1.3 to 2.6 s overstatement of the head offset.
    static let noticeThresholdSec = 10.0

    /// What one channel's delivery path saw: its first and latest buffer and the audio it handed
    /// to the writer, for the file that is being measured.
    struct Delivery: Equatable {
        var firstSec: Double
        var lastSec: Double
        var deliveredSec: Double
    }

    struct Input: Equatable {
        /// Recording start to capture stop.
        var spanSec: Double
        /// Seconds in each written intermediate, nil when the file is absent or unreadable.
        var micAudioSec: Double?
        var systemAudioSec: Double?
        /// REC9: where the system file's audio begins.
        var headOffsetSec: Double
        var mic: Delivery?
        var system: Delivery?
    }

    enum Cause: String, Equatable {
        /// The channel's first buffer came late.
        case startedLate = "started_late"
        /// Its last buffer came well before capture stop.
        case stoppedEarly = "stopped_early"
        /// Buffers kept coming but carried less audio than the time between them.
        case gapsMidCall = "gaps_mid_call"
        /// Delivered to the writer, missing from the file.
        case notWritten = "not_written"
        /// Short, and none of the four accounts for it.
        case unexplained
    }

    struct Verdict: Equatable {
        var spanSec: Double
        /// Capture span minus mic audio; positive is a short mic.
        var micShortfallSec: Double?
        /// Mic audio minus the head offset minus system audio; positive is a short system side
        /// beyond the announced head loss.
        var channelGapSec: Double?
        var headOffsetSec: Double
        /// Capture stop minus the system's last buffer.
        var systemTailSec: Double?
        /// Delivered minus written, per channel.
        var micUnwrittenSec: Double?
        var systemUnwrittenSec: Double?
        var micCause: Cause?
        var systemCause: Cause?

        /// Worth one `channel_coverage_short` row.
        var isShort: Bool {
            (micShortfallSec ?? 0) > ChannelCoverage.eventThresholdSec
                || (channelGapSec ?? 0) > ChannelCoverage.eventThresholdSec
                || headOffsetSec > ChannelCoverage.eventThresholdSec
        }

        /// Seconds of the far side missing from the recording in all: the late head plus the
        /// shortfall after it, or the tail when that is larger.
        var farSideMissingSec: Double {
            max(headOffsetSec + max(0, channelGapSec ?? 0), systemTailSec ?? 0)
        }

        /// Whole seconds of the far side missing when that is worth a stop notice, else nil.
        var noticeMissingSeconds: Int? {
            farSideMissingSec >= ChannelCoverage.noticeThresholdSec ? Int(farSideMissingSec.rounded()) : nil
        }
    }

    /// Nil when there is nothing to measure (no span).
    static func evaluate(_ input: Input) -> Verdict? {
        guard input.spanSec > 0 else { return nil }
        let micShortfall = input.micAudioSec.map { input.spanSec - $0 }
        let gap: Double? = {
            guard let mic = input.micAudioSec, let system = input.systemAudioSec else { return nil }
            return mic - input.headOffsetSec - system
        }()
        let tail = input.system.map { input.spanSec - $0.lastSec }
        let micUnwritten = zip(input.mic?.deliveredSec, input.micAudioSec).map { $0 - $1 }
        let systemUnwritten = zip(input.system?.deliveredSec, input.systemAudioSec).map { $0 - $1 }

        let micCause = (micShortfall ?? 0) > eventThresholdSec
            ? cause(late: input.mic?.firstSec, tail: input.mic.map { input.spanSec - $0.lastSec },
                    delivery: input.mic, unwritten: micUnwritten)
            : nil
        let systemShort = (gap ?? 0) > eventThresholdSec || input.headOffsetSec > eventThresholdSec
        let systemCause = systemShort
            ? cause(late: input.headOffsetSec, tail: tail, delivery: input.system, unwritten: systemUnwritten)
            : nil

        return Verdict(
            spanSec: input.spanSec,
            micShortfallSec: micShortfall,
            channelGapSec: gap,
            headOffsetSec: input.headOffsetSec,
            systemTailSec: tail,
            micUnwrittenSec: micUnwritten,
            systemUnwrittenSec: systemUnwritten,
            micCause: micCause,
            systemCause: systemCause
        )
    }

    /// The largest of the four measured losses names the cause; none over the threshold is
    /// `unexplained`.
    private static func cause(late: Double?, tail: Double?, delivery: Delivery?, unwritten: Double?) -> Cause {
        let midCall = delivery.map { ($0.lastSec - $0.firstSec) - $0.deliveredSec }
        let candidates: [(Cause, Double)] = [
            (.startedLate, late ?? 0),
            (.stoppedEarly, tail ?? 0),
            (.gapsMidCall, midCall ?? 0),
            (.notWritten, unwritten ?? 0),
        ]
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > eventThresholdSec else { return .unexplained }
        return best.0
    }

    private static func zip(_ a: Double?, _ b: Double?) -> (Double, Double)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    /// The `recorder`/`channel_coverage_short` attributes.
    static func eventAttributes(_ v: Verdict) -> [String: Any] {
        func r(_ x: Double?) -> Any { x.map { ($0 * 100).rounded() / 100 } as Any }
        return [
            "span_sec": r(v.spanSec),
            "mic_shortfall_sec": r(v.micShortfallSec),
            "channel_gap_sec": r(v.channelGapSec),
            "head_offset_sec": r(v.headOffsetSec),
            "system_tail_sec": r(v.systemTailSec),
            "mic_unwritten_sec": r(v.micUnwrittenSec),
            "system_unwritten_sec": r(v.systemUnwrittenSec),
            "mic_cause": v.micCause?.rawValue as Any,
            "system_cause": v.systemCause?.rawValue as Any,
            "far_side_missing_sec": r(v.farSideMissingSec),
        ]
    }
}
