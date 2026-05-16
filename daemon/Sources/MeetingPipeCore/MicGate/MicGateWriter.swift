import Foundation

/// Per-buffer writer that converts a `MicGateVerdict` into an
/// amplitude-shaped buffer the recorder can emit. The writer is
/// stateless across buffers in the sense that the verdict carries
/// the truth; it does carry the *previous* verdict so transitions
/// can apply a 20 ms (configurable) linear fade between live mic
/// audio and zero-amplitude frames.
///
/// The writer never skips frames: skipping breaks sample alignment
/// with the ScreenCaptureKit right channel (per TECH-G-MIC spec).
/// The output buffer always has the same length as the input.
///
/// Threading: instances are not safe for concurrent use across
/// queues. The natural owner is the audio tap thread.
public final class MicGateWriter {

    public let sampleRate: Double
    public let fadeDurationMillis: Int
    private let fadeSamples: Int
    private var lastVerdictWasHot: Bool = false
    private var samplesIntoTransition: Int = 0
    private var inFade: Bool = false
    private var fadingFromHotToMuted: Bool = false

    public init(sampleRate: Double, fadeDurationMillis: Int = 20) {
        self.sampleRate = sampleRate
        self.fadeDurationMillis = fadeDurationMillis
        self.fadeSamples = max(1, Int(sampleRate * Double(fadeDurationMillis) / 1000.0))
    }

    public struct ApplyResult: Equatable {
        public let action: Action
        public let samplesFaded: Int

        public enum Action: Equatable {
            case passedThrough
            case zeroed
            case fadedOut
            case fadedIn
        }
    }

    /// Apply the verdict to the buffer in place. Returns the
    /// transformation kind for the audit log.
    @discardableResult
    public func apply(
        verdict: MicGateVerdict,
        to buffer: UnsafeMutableBufferPointer<Float>
    ) -> ApplyResult {
        let isHot = verdict.passesLiveAudio
        if inFade {
            return continueFade(buffer)
        }
        if isHot == lastVerdictWasHot {
            if isHot {
                lastVerdictWasHot = true
                return ApplyResult(action: .passedThrough, samplesFaded: 0)
            } else {
                fillZero(buffer)
                lastVerdictWasHot = false
                return ApplyResult(action: .zeroed, samplesFaded: 0)
            }
        }
        return startFade(buffer, becomingHot: isHot)
    }

    /// Reset transition state. Call between meetings so a fade in
    /// progress from a prior session doesn't bleed into the next.
    public func reset() {
        lastVerdictWasHot = false
        samplesIntoTransition = 0
        inFade = false
        fadingFromHotToMuted = false
    }

    private func startFade(_ buffer: UnsafeMutableBufferPointer<Float>, becomingHot: Bool) -> ApplyResult {
        inFade = true
        samplesIntoTransition = 0
        fadingFromHotToMuted = !becomingHot
        return continueFade(buffer)
    }

    private func continueFade(_ buffer: UnsafeMutableBufferPointer<Float>) -> ApplyResult {
        let length = buffer.count
        var i = 0
        while i < length && samplesIntoTransition < fadeSamples {
            let gain = Float(samplesIntoTransition) / Float(fadeSamples)
            let scaled = fadingFromHotToMuted ? (1 - gain) : gain
            buffer[i] = buffer[i] * scaled
            samplesIntoTransition += 1
            i += 1
        }
        if samplesIntoTransition >= fadeSamples {
            inFade = false
            if fadingFromHotToMuted {
                // Tail of the buffer past the fade is silent.
                while i < length {
                    buffer[i] = 0
                    i += 1
                }
                lastVerdictWasHot = false
                return ApplyResult(action: .fadedOut, samplesFaded: fadeSamples)
            } else {
                // Tail of the buffer past the fade passes through.
                lastVerdictWasHot = true
                return ApplyResult(action: .fadedIn, samplesFaded: fadeSamples)
            }
        }
        // The fade spans more than this buffer; treat the remainder
        // as silent if fading out, or pass through if fading in.
        if fadingFromHotToMuted {
            while i < length {
                buffer[i] = 0
                i += 1
            }
            return ApplyResult(action: .fadedOut, samplesFaded: length)
        } else {
            return ApplyResult(action: .fadedIn, samplesFaded: length)
        }
    }

    private func fillZero(_ buffer: UnsafeMutableBufferPointer<Float>) {
        for i in 0..<buffer.count { buffer[i] = 0 }
    }
}
