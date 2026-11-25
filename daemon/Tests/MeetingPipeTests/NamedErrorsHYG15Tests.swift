import XCTest
@testable import MeetingPipe

/// HYG15: each `NSError(domain:)` became a named `LocalizedError` case, and the text a person
/// reads did not change. Every expected string here is the `NSLocalizedDescriptionKey` the
/// replaced `NSError` carried, copied from the code before the change.
final class NamedErrorsHYG15Tests: XCTestCase {

    func test_pipeline_launcher_result_errors_keep_their_messages() {
        typealias E = PipelineLauncher.ResultError
        XCTAssertEqual(E.answerReported("index is stale").localizedDescription, "index is stale")
        XCTAssertEqual(E.unreadableResult("ask produced no readable result").localizedDescription,
                       "ask produced no readable result")
        XCTAssertEqual(E.unreadableResult("restore --dry-run produced no readable plan").localizedDescription,
                       "restore --dry-run produced no readable plan")
        XCTAssertEqual(E.unreadableResult("actions --cluster produced no readable result").localizedDescription,
                       "actions --cluster produced no readable result")
    }

    /// The one string that did change: the `NSError` it replaced had no description at all, so a
    /// person read Foundation's "(LibraryListView error 1.)".
    func test_library_closed_is_a_sentence() {
        XCTAssertEqual(MeetingLibraryService.LibraryError.libraryClosed.localizedDescription,
                       "The Library closed before this could run. Open the Library and try again.")
    }

    @MainActor
    func test_notion_errors_keep_their_messages() {
        typealias E = NotionDatabaseList.NotionError
        XCTAssertEqual(E.invalidDatabaseID.localizedDescription, "Database id is not a valid value.")
        XCTAssertEqual(E.noResponse.localizedDescription, "No HTTP response from Notion.")
        XCTAssertEqual(E.databaseNotFound.localizedDescription,
                       "Database not found, or the integration is not connected to it. In Notion, open the database, then the '\u{2026}' menu -> Connections -> add your integration.")
        XCTAssertEqual(E.tokenRejected(status: 401).localizedDescription,
                       "Notion rejected the token (HTTP 401). Check the integration token.")
        XCTAssertEqual(E.http(status: 500, body: "oops").localizedDescription, "Notion returned HTTP 500: oops")
        XCTAssertEqual(E.searchFailed(status: 502, body: "bad gateway").localizedDescription,
                       "Notion API returned 502: bad gateway")
    }

    func test_fluid_audio_buffer_failures_keep_their_messages() {
        typealias E = FluidAudioRunner.BufferFailure
        XCTAssertEqual(E.inputBufferAllocation.localizedDescription, "could not allocate input buffer")
        XCTAssertEqual(E.resamplerUnavailable.localizedDescription, "resampler unavailable")
        XCTAssertEqual(E.resamplerInputAllocation.localizedDescription, "resampler input alloc failed")
        XCTAssertEqual(E.resamplerOutputAllocation.localizedDescription, "resampler output alloc failed")
        let url = URL(fileURLWithPath: "/tmp/a.wav")
        XCTAssertEqual(TranscriptionError.audioReadFailed(url, underlying: E.resamplerUnavailable).localizedDescription,
                       "Failed to read audio at /tmp/a.wav: resampler unavailable")
    }

    func test_correction_schema_refusal_is_the_refusal_text() {
        let refusal = "The title is 300 characters; the limit is 200. Shorten it before saving."
        XCTAssertEqual(CorrectionWindow.SaveError.schemaRefused(refusal).localizedDescription, refusal)
    }
}
