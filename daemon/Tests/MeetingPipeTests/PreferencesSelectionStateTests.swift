import Combine
import XCTest
@testable import MeetingPipe

/// Tests for `PreferencesSelectionState`, the shared ObservableObject
/// that lets external callers deeplink Preferences to a specific
/// section. The full SwiftUI binding path is exercised at runtime
/// (the sidebar List rebinds on @Published change); here we lock the
/// minimum contract: default is General, mutations publish, and the
/// state survives a re-read so an already-open Preferences window can
/// be switched to a new section without recreating the window.
final class PreferencesSelectionStateTests: XCTestCase {

    func test_default_section_is_general() {
        let state = PreferencesSelectionState()
        XCTAssertEqual(state.current, .general)
    }

    func test_mutation_publishes_change() {
        let state = PreferencesSelectionState()
        var observed: [PreferencesItem] = []
        let cancellable = state.$current.sink { observed.append($0) }
        defer { cancellable.cancel() }

        state.current = .permissions
        state.current = .recording

        // sink fires once at subscribe + once per mutation.
        XCTAssertEqual(observed, [.general, .permissions, .recording])
    }

    func test_read_after_write_reflects_latest_value() {
        let state = PreferencesSelectionState()
        state.current = .permissions
        XCTAssertEqual(state.current, .permissions)
        state.current = .advanced
        XCTAssertEqual(state.current, .advanced)
    }

    /// The deeplink contract: PreferencesWindow.show(initial:) mutates
    /// selectionState.current BEFORE bringing the window forward, so
    /// the SwiftUI sidebar re-renders on the new selection regardless
    /// of whether the window was already on screen.
    func test_setting_to_same_value_is_idempotent() {
        let state = PreferencesSelectionState()
        state.current = .permissions
        state.current = .permissions
        XCTAssertEqual(state.current, .permissions)
    }
}
