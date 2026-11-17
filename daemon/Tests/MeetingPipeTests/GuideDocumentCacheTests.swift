import AppKit
import os
import XCTest
@testable import MeetingPipe

/// PERF29: the guide is built once per process, off main, and its window is kept across closes.
final class GuideDocumentCacheTests: XCTestCase {

    private let markdown = """
        ## First

        A **bold** paragraph.

        - a *bullet*

        ## Second

        | Key | Does |
        | --- | --- |
        | **K** | a [link](https://example.com) |
        """

    private final class Probe: Sendable {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let onMain = OSAllocatedUnfairLock(initialState: [Bool]())
    }

    private func makeCache(_ probe: Probe, queue: DispatchQueue = DispatchQueue(label: "guide-cache-test")) -> GuideDocumentCache {
        let md = markdown
        return GuideDocumentCache(read: {
            probe.reads.withLock { $0 += 1 }
            probe.onMain.withLock { $0.append(Thread.isMainThread) }
            return md
        }, queue: queue)
    }

    func test_the_build_runs_off_main_and_delivers_on_main() {
        let probe = Probe()
        let cache = makeCache(probe)
        let delivered = expectation(description: "delivered")
        cache.load { _ in
            XCTAssertTrue(Thread.isMainThread, "completions arrive on main")
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(probe.onMain.withLock { $0 }, [false], "the bundle is read and parsed off main")
    }

    func test_a_second_request_is_served_from_memory_without_rereading_the_bundle() {
        let probe = Probe()
        let cache = makeCache(probe)
        let first = expectation(description: "first")
        cache.load { _ in first.fulfill() }
        wait(for: [first], timeout: 5)
        XCTAssertNotNil(cache.cached)
        // Already built and asked from main: delivered before `load` returns, so a re-open paints at once.
        let ran = OSAllocatedUnfairLock(initialState: false)
        cache.load { _ in ran.withLock { $0 = true } }
        XCTAssertTrue(ran.withLock { $0 })
        cache.prewarm()
        XCTAssertEqual(probe.reads.withLock { $0 }, 1)
    }

    func test_requests_during_the_build_share_one_build() {
        let probe = Probe()
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "guide-cache-gated")
        queue.async { gate.wait() }  // holds the build queue until both requests are in
        let cache = makeCache(probe, queue: queue)
        let both = expectation(description: "both delivered")
        both.expectedFulfillmentCount = 2
        cache.load { _ in both.fulfill() }
        cache.load { _ in both.fulfill() }
        gate.signal()
        wait(for: [both], timeout: 5)
        XCTAssertEqual(probe.reads.withLock { $0 }, 1)
    }

    func test_the_cached_value_equals_what_the_view_used_to_compute_in_load() {
        let cache = makeCache(Probe())
        let done = expectation(description: "done")
        let box = OSAllocatedUnfairLock<GuideDocumentCache.Loaded?>(initialState: nil)
        cache.load { v in box.withLock { $0 = v }; done.fulfill() }
        wait(for: [done], timeout: 5)
        let parsed = GuideDocument.parse(markdown)
        let got = box.withLock { $0 }
        XCTAssertEqual(got?.blocks, GuideDocument.rendered(parsed))
        XCTAssertEqual(got?.sections, GuideDocument.sections(of: parsed))
    }

    func test_the_shipped_guide_renders_the_same_through_the_cache() throws {
        let guide = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/GUIDE.md"), encoding: .utf8)
        let cache = GuideDocumentCache(read: { guide }, queue: DispatchQueue(label: "guide-cache-shipped"))
        let done = expectation(description: "done")
        let box = OSAllocatedUnfairLock<GuideDocumentCache.Loaded?>(initialState: nil)
        cache.load { v in box.withLock { $0 = v }; done.fulfill() }
        wait(for: [done], timeout: 5)
        let parsed = GuideDocument.parse(guide)
        XCTAssertGreaterThan(parsed.count, 50, "the shipped guide, not a stub")
        XCTAssertEqual(box.withLock { $0 }?.blocks, GuideDocument.rendered(parsed))
        XCTAssertEqual(box.withLock { $0 }?.sections, GuideDocument.sections(of: parsed))
    }

    func test_a_missing_bundle_copy_renders_the_notice() {
        let cache = GuideDocumentCache(read: { nil }, queue: DispatchQueue(label: "guide-cache-missing"))
        let done = expectation(description: "done")
        let box = OSAllocatedUnfairLock<GuideDocumentCache.Loaded?>(initialState: nil)
        cache.load { v in box.withLock { $0 = v }; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(box.withLock { $0 }?.blocks, GuideDocument.rendered(GuideDocument.parse(GuideDocument.missingCopy)))
    }

    func test_the_default_queue_is_not_main() {
        let probe = Probe()
        let md = markdown
        let cache = GuideDocumentCache(read: { probe.onMain.withLock { $0.append(Thread.isMainThread) }; return md })
        let done = expectation(description: "done")
        cache.load { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(probe.onMain.withLock { $0 }, [false])
    }

    /// GuideView takes the document from the cache and never reads or parses it itself, so the
    /// cache's tests cannot pass over a view that went back to `onAppear` plus a main-thread parse.
    func test_the_view_takes_the_document_from_the_cache() throws {
        let view = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../Sources/MeetingPipe/GuideView.swift").standardized, encoding: .utf8)
        XCTAssertTrue(view.contains("GuideDocumentCache.shared"))
        for banned in ["bundledMarkdown(", "GuideDocument.parse(", "GuideDocument.rendered("] {
            XCTAssertFalse(view.contains(banned), "GuideView must not call \(banned) itself (PERF29)")
        }
    }

    @MainActor
    func test_the_guide_window_is_kept_across_a_close() {
        let guide = GuideWindow()
        guide.show()
        guard let first = guide.builtWindow else { return XCTFail("the guide window was not built") }
        defer { first.close() }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
        first.close()
        guide.show()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
        XCTAssertTrue(guide.builtWindow === first, "a re-open after a close reuses the window")
    }
}
