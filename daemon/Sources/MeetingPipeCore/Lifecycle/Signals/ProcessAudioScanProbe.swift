import CoreAudio
import Foundation

/// Start-side reader for the same `kAudioProcessPropertyIsRunningInput` flag `ProcessAudioSignal`
/// watches end-side, scoped to one discovery scan (DET12).
///
/// The two sides ask the same question of the same HAL property and differ only in shape, which is
/// why this shares `ProcessAudioSignal`'s matcher and its property reads rather than growing a
/// second spelling of either. End-side there is exactly one detected app and the signal lives for
/// the length of a meeting, so `ProcessAudioSignal` resolves once and keeps a listener per matched
/// object. Start-side there are N concurrent candidates and the scan is a single synchronous pass
/// that runs every few seconds forever, so the unit that has to be cheap is the *scan*, not the
/// candidate.
///
/// That is the whole reason this type exists rather than a free function. Resolution is a whole-list
/// enumeration of `kAudioHardwarePropertyProcessObjectList` plus two property reads per object (33
/// objects on the owner's Mac when DET8 measured it), and the pre-DET2 start-side probe paid a HAL
/// round-trip per candidate per scan on a much cheaper mechanism. Doing that per candidate now would
/// be strictly worse than the cost DET2's cleanup removed it for, so the cache is the precondition
/// for wiring the read in at all, not an optimisation layered on afterwards: `beginScan` drops the
/// snapshot, the first `isRunningInput` of the pass takes a new one, and every later candidate in
/// that same pass matches against it.
///
/// The enumeration is lazy rather than eager on `beginScan`, so a scan whose candidates are all
/// browsers or all Webex (see `MeetingSourceScanner.readsProcessAudio`) does no HAL work at all.
///
/// Deliberately *not* cached across scans. `ProcessAudioSignal`'s cache can be long-lived because a
/// `kAudioHardwarePropertyProcessObjectList` listener tells it when to re-resolve; a synchronous
/// scan has no listener, and DET8's probe measured `replayd` taking a different object ID under the
/// same PID nine minutes later, so a snapshot held across scans would go stale with nothing to
/// notice. One scan is the longest window in which the list is known not to have moved underneath
/// the reader.
///
/// Threading: no internal synchronisation, matching `MeetingSourceScanner`, whose owner runs the
/// whole scan on one serial queue.
public final class ProcessAudioScanProbe {

    /// One enumeration of the HAL process-object list. `status` is the enumeration's own OSStatus,
    /// carried so a caller can tell "the list would not read" from "the list held nothing for this
    /// app", the distinction DET2 got wrong in the other direction.
    public struct Snapshot: Equatable {
        public let objects: [ProcessAudioSignal.ProcessObjectDescriptor]
        public let status: OSStatus

        public init(objects: [ProcessAudioSignal.ProcessObjectDescriptor], status: OSStatus) {
            self.objects = objects
            self.status = status
        }
    }

    /// Takes one snapshot of the process-object list. Tests inject a counting fake; production uses
    /// `defaultEnumerator`.
    public typealias Enumerator = () -> Snapshot

    /// Reads one object's `isRunningInput`. nil when the read failed.
    public typealias InputReader = (AudioObjectID) -> Bool?

    /// Parent-PID lookup for `ProcessAudioSignal.match`'s ancestry fallback.
    public typealias ParentLookup = (pid_t) -> pid_t?

    private let enumerator: Enumerator
    private let inputReader: InputReader
    private let parentOf: ParentLookup

    /// nil between scans. Non-nil for the rest of a scan once the first candidate forced an
    /// enumeration.
    private var snapshot: Snapshot?

    public init(
        enumerator: @escaping Enumerator = ProcessAudioScanProbe.defaultEnumerator,
        inputReader: @escaping InputReader = ProcessAudioScanProbe.defaultInputReader,
        parentOf: @escaping ParentLookup = ProcessAudioScanProbe.defaultParentLookup
    ) {
        self.enumerator = enumerator
        self.inputReader = inputReader
        self.parentOf = parentOf
    }

    /// Drop the cached snapshot. Called once at the top of a discovery scan, so the next read takes
    /// a fresh enumeration and every candidate after it shares that one.
    public func beginScan() {
        snapshot = nil
    }

    /// `isRunningInput` OR-ed across the HAL process objects carrying this app's audio.
    ///
    /// nil means UNKNOWN and covers three cases the caller cannot act on differently: the list would
    /// not enumerate, nothing matched this app, or not one matched object could be read. false is a
    /// real reading from at least one object, exactly as `ProcessAudioSignal.reduceIsRunningInput`
    /// defines it, so the two sides cannot disagree about what a mixed read means.
    ///
    /// The OR is not belt-and-braces: Teams splits its audio across ModuleHost and the WebView
    /// helpers, and which one carries input is a Teams implementation detail (only ModuleHost ever
    /// read true in DET8's two live calls).
    public func isRunningInput(bundleID: String, pid: pid_t) -> Bool? {
        let snapshot = currentSnapshot()
        guard snapshot.status == noErr else { return nil }
        let matched = ProcessAudioSignal.match(
            objects: snapshot.objects,
            bundleID: bundleID,
            pid: pid,
            parentOf: parentOf
        )
        guard !matched.isEmpty else { return nil }
        return ProcessAudioSignal.reduceIsRunningInput(matched.map(inputReader))
    }

    private func currentSnapshot() -> Snapshot {
        if let snapshot { return snapshot }
        let fresh = enumerator()
        snapshot = fresh
        return fresh
    }

    /// The real enumeration. Needs no TCC grant and no tap; DET8 measured it from a disclaimed
    /// harness shell holding no grant at all, which is what lets the start-side read sit outside
    /// `MeetingSourceScanner.collectSignals`' Accessibility gate.
    public static let defaultEnumerator: Enumerator = {
        var status = noErr
        let objects = ProcessAudioSignal.enumerateProcessObjects(status: &status)
        return Snapshot(objects: objects, status: status)
    }

    /// The two reads this shares with `ProcessAudioSignal`, re-exported as public seams only because
    /// a public initializer cannot default an argument to an internal member. There is still one
    /// implementation of each.
    public static let defaultInputReader: InputReader = { ProcessAudioSignal.readIsRunningInput($0) }
    public static let defaultParentLookup: ParentLookup = { ProcessAudioSignal.parentPID($0) }
}
