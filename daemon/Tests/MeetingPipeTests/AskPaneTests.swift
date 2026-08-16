import XCTest
@testable import MeetingPipe

/// UX38: what the Ask pane shows, decided away from the view that shows it.
///
/// The pane this replaced derived all of it inline, so the states worth pinning
/// (an empty Ask inviting rather than sitting blank, the input docking once
/// there is something under it, and a running line that stays honest when the
/// engine reports nothing useful) were unreachable from a test.
final class AskPaneTests: XCTestCase {

    private func entry(_ question: String, answer text: String = "an answer") -> AskEntry {
        AskEntry(
            id: UUID(),
            question: question,
            askedAt: Date(),
            outcome: .answered(AskAnswer(
                question: question,
                answer: text,
                citations: [],
                sourcesConsidered: [],
                backend: "local",
                model: nil,
                verified: true,
                empty: false,
                error: nil,
                substitutedFrom: nil
            ))
        )
    }

    private func run(indexing: AskIndexProgress? = nil) -> AskInFlight {
        AskInFlight(id: UUID(), question: "why", startedAt: Date(), indexing: indexing)
    }

    // MARK: - Empty

    func testEmptyModelRendersTheCentredInvitation() {
        let pane = AskPane.derive(inFlight: nil, history: [], meetingCount: 12)

        XCTAssertEqual(pane.layout, .centered)
        XCTAssertFalse(pane.isDocked)
        XCTAssertEqual(pane.headline, "Ask about your meetings.")
        XCTAssertEqual(pane.subhead, "Answers cite the meetings they came from.")
        XCTAssertTrue(pane.entries.isEmpty)
        XCTAssertNil(pane.running)
        XCTAssertNil(pane.inputNote)
    }

    /// The two placeholders are different on purpose: centred, the field carries
    /// the whole invitation's example; docked, it only has to say that asking
    /// again happens right here.
    func testPlaceholderFramesAnsweringCentredAndAskingAgainOnceDocked() {
        let empty = AskPane.derive(inFlight: nil, history: [], meetingCount: 3)
        let docked = AskPane.derive(inFlight: nil, history: [entry("q")], meetingCount: 3)

        XCTAssertEqual(empty.fieldPlaceholder, "What did we decide about\u{2026}?")
        XCTAssertEqual(docked.fieldPlaceholder, "Ask another question\u{2026}")
        // Neither is a search prompt: Cmd+K owns find-a-meeting (UX25), and a
        // placeholder that reads like a search blurs the two surfaces.
        XCTAssertFalse(empty.fieldPlaceholder.lowercased().contains("search"))
        XCTAssertFalse(docked.fieldPlaceholder.lowercased().contains("search"))
    }

    /// A fresh install has nothing to answer from, and an invitation that
    /// pretends otherwise is the aspirational copy PRODUCT.md rules out.
    func testAnEmptyLibrarySaysSoAndOffersNoSuggestions() {
        let pane = AskPane.derive(inFlight: nil, history: [], meetingCount: 0)

        XCTAssertEqual(pane.subhead, "No meetings recorded yet.")
        XCTAssertTrue(pane.suggestions.isEmpty)
    }

    // MARK: - Docking

    func testHistoryDocksTheInputAndRendersTheList() {
        let newest = entry("what did we decide about the budget?")
        let older = entry("what are my open action items?")
        let pane = AskPane.derive(inFlight: nil, history: [newest, older], meetingCount: 40)

        XCTAssertEqual(pane.layout, .docked)
        XCTAssertEqual(pane.entries.map(\.id), [newest.id, older.id], "newest first, as the model holds it")
        // The invitation is the empty state, not a permanent header.
        XCTAssertNil(pane.headline)
        XCTAssertNil(pane.subhead)
        XCTAssertTrue(pane.suggestions.isEmpty)
    }

    /// The first question docks the input before any answer exists, which is
    /// what makes the move read as a response to asking rather than to landing.
    func testARunInFlightDocksBeforeThereIsAnyHistory() {
        let pane = AskPane.derive(inFlight: run(), history: [], meetingCount: 5)

        XCTAssertEqual(pane.layout, .docked)
        XCTAssertNil(pane.headline)
        XCTAssertTrue(pane.entries.isEmpty)
    }

    // MARK: - Running

    func testRunningWithoutIndexWorkIsTheThinkingState() {
        let pane = AskPane.derive(inFlight: run(), history: [], meetingCount: 5)

        XCTAssertEqual(pane.running, .thinking)
        XCTAssertEqual(pane.running?.line, "Reading your meetings\u{2026}")
    }

    func testRunningRendersAI11sCountsWhileTheIndexRebuilds() {
        let pane = AskPane.derive(
            inFlight: run(indexing: AskIndexProgress(done: 86, total: 87)),
            history: [],
            meetingCount: 87
        )

        XCTAssertEqual(pane.running, .indexing(done: 86, total: 87))
        XCTAssertEqual(pane.running?.line, "Updating the index, 86 of 87 meetings\u{2026}")
    }

    /// `0 of 0` says nothing anyone can act on, so an index beat that carries no
    /// meetings degrades to the honest thinking state instead.
    func testAnIndexBeatOverNoMeetingsFallsBackToThinking() {
        let pane = AskPane.derive(
            inFlight: run(indexing: AskIndexProgress(done: 0, total: 0)),
            history: [],
            meetingCount: 0
        )

        XCTAssertEqual(pane.running, .thinking)
    }

    /// A ratio reading past 100% would make the one honest number on the pane
    /// look like a guess.
    func testDoneIsClampedToTotal() {
        let pane = AskPane.derive(
            inFlight: run(indexing: AskIndexProgress(done: 91, total: 87)),
            history: [],
            meetingCount: 87
        )

        XCTAssertEqual(pane.running, .indexing(done: 87, total: 87))
    }

    /// UX37 refuses a second ask while one runs. A refusal that changes nothing
    /// on screen is indistinguishable from a dead button, so the pane says the
    /// rule and names the way out while the run is up, and drops it after.
    func testTheOneAtATimeRuleIsVisibleOnlyWhileARunIsUp() {
        let running = AskPane.derive(inFlight: run(), history: [], meetingCount: 5)
        let idle = AskPane.derive(inFlight: nil, history: [entry("q")], meetingCount: 5)

        XCTAssertEqual(running.inputNote, "One question at a time. Cancel to ask another.")
        XCTAssertTrue(running.isRunning)
        XCTAssertNil(idle.inputNote)
        XCTAssertFalse(idle.isRunning)
    }

    // MARK: - Suggestions

    func testSuggestionsComeOffTheLibraryAndAskQuestionsOfIt() {
        let pane = AskPane.derive(
            inFlight: nil,
            history: [],
            recentWorkflow: "Client work",
            recentTitle: "Pricing review",
            meetingCount: 9
        )

        XCTAssertEqual(pane.suggestions.map(\.text), [
            "What did we decide in Client work recently?",
            "What came out of Pricing review?",
            "What are my open action items?",
        ])
    }

    /// Every suggestion has to be answerable from the transcripts. A "find" or
    /// "show me" chip would send the user to the surface Cmd+K already owns.
    func testEverySuggestionAsksRatherThanSearches() {
        let pane = AskPane.derive(
            inFlight: nil, history: [],
            recentWorkflow: "Standup", recentTitle: "Monday standup", meetingCount: 4
        )

        for suggestion in pane.suggestions {
            XCTAssertTrue(suggestion.text.hasPrefix("What"), suggestion.text)
            XCTAssertTrue(suggestion.text.hasSuffix("?"), suggestion.text)
        }
    }

    func testAnUntaggedLibraryStillOffersWhatItCanAnswer() {
        let pane = AskPane.derive(
            inFlight: nil, history: [],
            recentWorkflow: nil, recentTitle: "Zoom at 14:32", meetingCount: 2
        )

        XCTAssertEqual(pane.suggestions.map(\.text), [
            "What came out of Zoom at 14:32?",
            "What are my open action items?",
        ])
    }

    func testABlankWorkflowNameIsNotASuggestion() {
        let pane = AskPane.derive(
            inFlight: nil, history: [],
            recentWorkflow: "   ", recentTitle: nil, meetingCount: 2
        )

        XCTAssertEqual(pane.suggestions.map(\.text), ["What are my open action items?"])
    }

    /// A chip is one line, not a place to read a sentence.
    func testALongMeetingTitleIsClippedOnAWordBoundary() {
        let title = "Quarterly planning and roadmap review with the whole platform team"
        let suggestions = AskPane.suggestions(
            recentWorkflow: nil, recentTitle: title, meetingCount: 1
        )

        let clipped = suggestions[0].text
        XCTAssertTrue(clipped.hasPrefix("What came out of Quarterly planning and roadmap"), clipped)
        XCTAssertTrue(clipped.hasSuffix("\u{2026}?"), clipped)
        XCTAssertFalse(clipped.contains("platform"), "the tail should be gone, not wrapped")
        // Word boundary, not mid-syllable.
        XCTAssertFalse(clipped.contains(" \u{2026}?"), clipped)
    }

    func testSuggestionsAreCappedAtTheStatedLimit() {
        let suggestions = AskPane.suggestions(
            recentWorkflow: "Weekly sync", recentTitle: "Monday standup", meetingCount: 30
        )

        XCTAssertLessThanOrEqual(suggestions.count, AskPane.suggestionLimit)
        XCTAssertEqual(Set(suggestions.map(\.text)).count, suggestions.count)
    }
}
