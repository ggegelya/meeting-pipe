import AVFoundation
import Combine
import XCTest
@testable import MeetingPipe

/// PERF22: what a `MeetingStore` scan costs and when it publishes. The watcher's cancel handler,
/// the duration cache that survives a relaunch, the aged failed row the row cache now keeps, and
/// the publish a scan that found nothing skips. Every store here keeps its durations in memory or
/// in a temp file; none reads the real cache.
final class MeetingStoreScanCostTests: XCTestCase {

    private var dirs: [URL] = []

    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        dirs = []
        super.tearDown()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-scancost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return dir
    }

    private func write(_ url: URL, _ contents: String = "") throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func setMtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func writeWAV(_ url: URL, seconds: Double) throws {
        let sampleRate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    private func stem(hoursAgo: Double) -> String {
        MeetingFormatters.stem.string(from: Date().addingTimeInterval(-hoursAgo * 3600))
    }

    /// Wait out everything queued on the scan queue, then the main-queue hop a scan queued
    /// before it, so a `refresh()` that publishes nothing has still finished.
    private func settle(_ store: MeetingStore) {
        let done = expectation(description: "scan queue drained")
        store.enqueueOnScanQueue { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 5)
    }

    private func refreshAndSettle(_ store: MeetingStore) {
        store.refresh()
        settle(store)
    }

    // MARK: Item 2: the cancel handler closes its own descriptor

    /// The defect: the cancel handler closed the *current* `watcherFD`, and it runs on the scan
    /// queue behind any scan in flight, so a stop and a start inside one scan had the old handler
    /// close the new watcher's descriptor. The Library then stopped auto-refreshing and the old
    /// descriptor leaked.
    func test_a_stop_then_start_inside_one_scan_keeps_the_new_watcher_and_closes_the_old_descriptor() throws {
        let dir = try tempDir()
        let store = MeetingStore(recordingsDir: dir)
        let closedBox = ClosedDescriptors()
        store.watcherDescriptorClosed = { closedBox.append($0) }
        store.start()
        settle(store)
        let oldFD = try XCTUnwrap(store.watchedDescriptor)

        // Hold a scan in flight: the gate blocks the scan queue, and the refresh queues behind it.
        let gate = DispatchSemaphore(value: 0)
        store.enqueueOnScanQueue { gate.wait() }
        store.refresh()
        store.stop()
        store.start()
        let newFD = try XCTUnwrap(store.watchedDescriptor)
        XCTAssertNotEqual(newFD, oldFD)
        gate.signal()
        settle(store)
        settle(store)   // the follow-up rescan the second start folded in

        XCTAssertEqual(closedBox.values, [oldFD], "the old source closes exactly its own descriptor")
        XCTAssertNotEqual(fcntl(newFD, F_GETFD), -1, "the live watcher's descriptor is still open")

        let before = store.revision
        let bumped = expectation(description: "a write after the restart rescans")
        let cancel = store.$revision.dropFirst().sink { if $0 > before { bumped.fulfill() } }
        try write(dir.appendingPathComponent("\(stem(hoursAgo: 0.1)).summary.json"), "{}")
        wait(for: [bumped], timeout: 5)
        cancel.cancel()
        store.stop()
    }

    // MARK: Item 3: durations survive a relaunch

    private func durationFixture() throws -> (dir: URL, stems: [String]) {
        let dir = try tempDir()
        // Audio reclaimed: only the transcript answers.
        let a = stem(hoursAgo: 30)
        try write(dir.appendingPathComponent("\(a).summary.json"), "{}")
        try write(dir.appendingPathComponent("\(a).json"), #"{"audio_seconds": 1830.5, "segments": []}"#)
        // Transcript with no audio_seconds: the header answers.
        let b = stem(hoursAgo: 20)
        try writeWAV(dir.appendingPathComponent("\(b).wav"), seconds: 2.5)
        try write(dir.appendingPathComponent("\(b).summary.json"), "{}")
        try write(dir.appendingPathComponent("\(b).json"), #"{"segments": []}"#)
        // Both: audio_seconds wins (UX74).
        let c = stem(hoursAgo: 10)
        try write(dir.appendingPathComponent("\(c).wav"))
        try write(dir.appendingPathComponent("\(c).summary.json"), "{}")
        try write(dir.appendingPathComponent("\(c).json"), #"{"audio_seconds": 9.0453125}"#)
        return (dir, [a, b, c])
    }

    private func durations(_ rows: [Meeting]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { m in m.durationSec.map { (m.stem, $0) } })
    }

    /// The measured cost: every launch's first scan parsed every `<stem>.json` for one number. A
    /// second store over the same library with the cache warm answers the same lengths and opens
    /// no transcript.
    func test_a_warm_duration_cache_answers_identical_durations_and_parses_no_transcript() throws {
        let (dir, stems) = try durationFixture()
        let cacheURL = try tempDir().appendingPathComponent("durations.json")

        let cold = MeetingStore(recordingsDir: dir, durationCacheURL: cacheURL)
        settle(cold)
        let first = durations(cold.performScan(directory: dir))
        XCTAssertEqual(cold.transcriptDurationReads, 3)
        XCTAssertEqual(first[stems[0]], 1830.5)
        XCTAssertEqual(first[stems[1]] ?? -1, 2.5, accuracy: 0.01)
        XCTAssertEqual(first[stems[2]], 9.0453125)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "a scan that filled the cache writes it")

        let warm = MeetingStore(recordingsDir: dir, durationCacheURL: cacheURL)
        settle(warm)
        let second = durations(warm.performScan(directory: dir))
        XCTAssertEqual(second, first)
        XCTAssertEqual(warm.transcriptDurationReads, 0, "a relaunch with a warm cache parses no transcript")
    }

    func test_a_changed_transcript_mtime_invalidates_only_that_stems_duration() throws {
        let (dir, stems) = try durationFixture()
        let cacheURL = try tempDir().appendingPathComponent("durations.json")
        let cold = MeetingStore(recordingsDir: dir, durationCacheURL: cacheURL)
        settle(cold)
        _ = cold.performScan(directory: dir)

        try setMtime(dir.appendingPathComponent("\(stems[0]).json"), Date().addingTimeInterval(-5))
        let warm = MeetingStore(recordingsDir: dir, durationCacheURL: cacheURL)
        settle(warm)
        let rows = durations(warm.performScan(directory: dir))
        XCTAssertEqual(warm.transcriptDurationReads, 1, "only the touched transcript is re-read")
        XCTAssertEqual(rows[stems[0]], 1830.5)
    }

    /// The mtime span is not a measurement, so it is never kept: a header that could not be read
    /// once is retried on the next rebuild rather than pinned across launches.
    func test_the_mtime_fallback_is_not_kept_across_launches() throws {
        let dir = try tempDir()
        let s = stem(hoursAgo: 5)
        let started = try XCTUnwrap(MeetingStore.parseStem(s))
        let wav = dir.appendingPathComponent("\(s).wav")
        try write(wav)
        try setMtime(wav, started.addingTimeInterval(600))
        try write(dir.appendingPathComponent("\(s).summary.json"), "{}")
        let cacheURL = try tempDir().appendingPathComponent("durations.json")

        let store = MeetingStore(recordingsDir: dir, durationCacheURL: cacheURL)
        settle(store)
        XCTAssertEqual(store.performScan(directory: dir).first?.durationSec ?? -1, 600, accuracy: 1)
        XCTAssertTrue(MeetingDurationCache.load(from: cacheURL).entries.isEmpty)
    }

    /// PERF20's lesson for the index, applied here: an unreadable root is not an empty library.
    func test_an_unreadable_root_does_not_prune_the_duration_cache() throws {
        let (dir, _) = try durationFixture()
        let cacheURL = try tempDir().appendingPathComponent("durations.json")
        let store = MeetingStore(recordingsDir: dir, durationCacheURL: cacheURL)
        settle(store)
        _ = store.performScan(directory: dir)
        XCTAssertEqual(MeetingDurationCache.load(from: cacheURL).entries.count, 3)

        XCTAssertEqual(store.performScan(directory: dir.appendingPathComponent("missing")), [])
        XCTAssertEqual(MeetingDurationCache.load(from: cacheURL).entries.count, 3)
    }

    func test_a_corrupt_or_foreign_duration_cache_loads_empty() throws {
        let url = try tempDir().appendingPathComponent("durations.json")
        try write(url, "not json")
        XCTAssertTrue(MeetingDurationCache.load(from: url).entries.isEmpty)
        try write(url, #"{"version": 999, "entries": {}}"#)
        XCTAssertTrue(MeetingDurationCache.load(from: url).entries.isEmpty)
    }

    // MARK: Item 4: an aged failed row is cached

    /// Past the staleness window only a file change can move an age-inferred `.failed` row, so it
    /// is served from the row cache: no rebuild, and so no `hasReusableTranscript` read either.
    func test_an_aged_failed_row_is_served_from_the_row_cache_on_the_next_scan() throws {
        let dir = try tempDir()
        let s = stem(hoursAgo: 5)
        try write(dir.appendingPathComponent("\(s).wav"))
        try write(dir.appendingPathComponent("\(s).md"), "Speaker 1: hello")
        try write(dir.appendingPathComponent("\(s).json"), #"{"segments": []}"#)
        let store = MeetingStore(recordingsDir: dir)

        let first = store.performScan(directory: dir)
        XCTAssertEqual(first.first?.status, .failed)
        XCTAssertEqual(store.rowBuilds, 1)
        let second = store.performScan(directory: dir)
        XCTAssertEqual(second, first)
        XCTAssertEqual(store.rowBuilds, 1, "the aged row is not rebuilt, so its transcript is not re-read")
    }

    /// The one exception: a row that exists only because its capture intermediate is fresh. Caching
    /// it would keep a phantom row after the capture went stale with no file change (TECH-A17).
    func test_an_aged_row_on_a_capture_intermediate_is_still_rebuilt() throws {
        let dir = try tempDir()
        let s = stem(hoursAgo: 5)
        try write(dir.appendingPathComponent("\(s).mic.wav"))
        let store = MeetingStore(recordingsDir: dir)

        XCTAssertEqual(store.performScan(directory: dir).first?.status, .failed)
        _ = store.performScan(directory: dir)
        XCTAssertEqual(store.rowBuilds, 2)
    }

    func test_a_processing_row_is_still_rebuilt_every_scan() throws {
        let dir = try tempDir()
        try write(dir.appendingPathComponent("\(stem(hoursAgo: 0.5)).wav"))
        let store = MeetingStore(recordingsDir: dir)
        XCTAssertEqual(store.performScan(directory: dir).first?.status, .processing)
        _ = store.performScan(directory: dir)
        XCTAssertEqual(store.rowBuilds, 2)
    }

    // MARK: Item 5: a scan that found nothing publishes nothing

    private func doneMeeting(in dir: URL) throws -> String {
        let s = stem(hoursAgo: 3)
        try write(dir.appendingPathComponent("\(s).wav"))
        try write(dir.appendingPathComponent("\(s).summary.json"), #"{"title":"Budget"}"#)
        try write(dir.appendingPathComponent("\(s).md"), "Speaker 1: hello")
        return s
    }

    func test_the_first_scan_of_an_empty_library_publishes() throws {
        let store = MeetingStore(recordingsDir: try tempDir())
        refreshAndSettle(store)
        XCTAssertEqual(store.revision, 1, "the indexer and the Library wait on the first revision")
        XCTAssertTrue(store.hasLoadedOnce)
    }

    func test_refresh_over_an_unchanged_directory_does_not_bump_revision() throws {
        let dir = try tempDir()
        _ = try doneMeeting(in: dir)
        let store = MeetingStore(recordingsDir: dir)
        refreshAndSettle(store)
        XCTAssertEqual(store.revision, 1)
        refreshAndSettle(store)
        refreshAndSettle(store)
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(store.meetings.count, 1)
    }

    /// The UX52 guard. A re-transcribe rewrites `<stem>.md` and may change no `Meeting` field; the
    /// open transcript pane reloads on the revision, so the bump must still come.
    func test_touching_one_sidecar_with_no_meeting_change_still_bumps_revision() throws {
        let dir = try tempDir()
        let s = try doneMeeting(in: dir)
        let store = MeetingStore(recordingsDir: dir)
        refreshAndSettle(store)
        let before = store.meetings

        try setMtime(dir.appendingPathComponent("\(s).md"), Date().addingTimeInterval(-30))
        refreshAndSettle(store)
        XCTAssertEqual(store.meetings, before, "no Meeting field changed")
        XCTAssertEqual(store.revision, 2, "a file changed, so the pane's reload key moves")
    }

    func test_a_processing_row_ageing_into_failed_with_no_file_change_bumps_revision() throws {
        let dir = try tempDir()
        try write(dir.appendingPathComponent("\(stem(hoursAgo: 1)).wav"))
        let store = MeetingStore(recordingsDir: dir)
        refreshAndSettle(store)
        XCTAssertEqual(store.meetings.first?.status, .processing)

        store.now = { Date().addingTimeInterval(2 * 3600) }
        refreshAndSettle(store)
        XCTAssertEqual(store.revision, 2)
        XCTAssertEqual(store.meetings.first?.status, .failed)
    }

    /// A listing that fails answers `[]`, as an emptied library does; the indexer tells them apart
    /// by `lastScanListedDirectory`, so the flip publishes even with rows that compare equal.
    func test_a_listing_that_starts_failing_publishes() throws {
        let parent = try tempDir()
        let dir = parent.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MeetingStore(recordingsDir: dir)
        refreshAndSettle(store)
        XCTAssertTrue(store.lastScanListedDirectory)

        try FileManager.default.removeItem(at: dir)
        refreshAndSettle(store)
        XCTAssertEqual(store.revision, 2)
        XCTAssertFalse(store.lastScanListedDirectory)
    }

    func test_publishes_compares_signatures_as_well_as_rows() {
        let rows: [Meeting] = []
        let a = MeetingStore.ScanSnapshot(
            listedDirectory: true, signatures: ["s": ["s.md": Date(timeIntervalSince1970: 1)]],
            correctionsModified: nil, meetings: rows
        )
        let b = MeetingStore.ScanSnapshot(
            listedDirectory: true, signatures: ["s": ["s.md": Date(timeIntervalSince1970: 2)]],
            correctionsModified: nil, meetings: rows
        )
        XCTAssertTrue(MeetingStore.ScanSnapshot.publishes(a, after: nil))
        XCTAssertFalse(MeetingStore.ScanSnapshot.publishes(a, after: a))
        XCTAssertTrue(MeetingStore.ScanSnapshot.publishes(b, after: a))
    }
}

/// The descriptors a store's cancel handlers closed. The handlers run on the scan queue; the test
/// reads after draining it.
private final class ClosedDescriptors: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CInt] = []
    func append(_ fd: CInt) { lock.lock(); stored.append(fd); lock.unlock() }
    var values: [CInt] { lock.lock(); defer { lock.unlock() }; return stored }
}
