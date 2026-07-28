import XCTest
@testable import MeetingPipe

/// FEAT11: the empty-context nudge. Both of the owner's NDA workflows carried an empty
/// `context_prompt`, so the meetings on the weakest backend summarized with no team
/// context at all and nothing anywhere said so.
final class WorkflowContextHintTests: XCTestCase {

    private func workflow(context: String) -> Workflow {
        Workflow(name: "Client work", contextPrompt: context)
    }

    func test_an_empty_context_needs_one() {
        XCTAssertTrue(WorkflowContextHint.needsContext(workflow(context: "")))
    }

    func test_whitespace_only_counts_as_empty() {
        // A prompt of spaces and newlines reaches the model as nothing, so treating it
        // as "set" would make the marker lie in exactly the case it exists for.
        XCTAssertTrue(WorkflowContextHint.needsContext(workflow(context: "   \n\t  \n")))
    }

    func test_real_context_needs_nothing() {
        XCTAssertFalse(
            WorkflowContextHint.needsContext(workflow(context: "Rana runs QA."))
        )
    }

    func test_leading_whitespace_does_not_hide_a_real_context() {
        XCTAssertFalse(WorkflowContextHint.needsContext(workflow(context: "\n  Rana runs QA.")))
    }

    /// The placeholder is the whole point of the nudge: an empty box with a one-line
    /// footer is what shipped, and it taught nobody what good context contains.
    func test_the_placeholder_names_the_three_things_that_help() {
        let text = WorkflowContextHint.placeholder
        XCTAssertTrue(text.contains("Who is usually here"), text)
        XCTAssertTrue(text.contains("words this team says"), text)
        XCTAssertTrue(text.contains("kind of meeting"), text)
    }

    func test_the_list_marker_is_short_enough_for_a_rail_row() {
        // It sits beside `default` in a 200pt-ish sidebar row; a sentence there would
        // push the meeting count off the end.
        XCTAssertLessThanOrEqual(WorkflowContextHint.listMarker.count, 16)
        XCTAssertFalse(WorkflowContextHint.listMarkerHelp.isEmpty)
    }
}
