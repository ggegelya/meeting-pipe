import Foundation
import XCTest
@testable import MeetingPipe

/// UX43: the three Preferences defects that shipped together in one surface.
///
/// (c) is pure and tested as such: the Local model picker's rules live on
/// `LocalModelPreset` so "what does selecting Custom do" is answerable without a
/// view or a config. (a) and (b) are SwiftUI layout and window geometry, neither
/// observable headlessly, so they are pinned where they are decided, in the
/// source, the way `SummaryLayoutTests` and `WorkflowDeletionTests` pin theirs.
/// T7 source fence (pins implementation): seven tests assert how PreferencesView, SettingsRow, PreferencesWindow and the Pipeline pane are written (scroll anchor order, min sizes, fixedSize, model-row bindings, a ConfigStore default literal). Missing seam: rendered view and NSWindow geometry tests.
final class PreferencesSurfaceTests: XCTestCase {

    // MARK: - Helpers

    /// Source of a file in the daemon target.
    private func daemonSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The same source with whole-line comments dropped. Every fence below that
    /// asserts a shape is *absent* runs on this: the code comments explaining these
    /// fixes name the shapes they replaced, and a fence that reads them cannot tell
    /// a rejected form from a description of one.
    private func code(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The capture groups of the first match, as integers. Used to compare two
    /// numbers that have to agree across two files.
    private func numbers(in text: String, matching pattern: String) throws -> [Int] {
        let re = try NSRegularExpression(pattern: pattern)
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            XCTFail("no match for \(pattern); re-point this fence")
            return []
        }
        return (1 ..< m.numberOfRanges).compactMap { i in
            Range(m.range(at: i), in: text).flatMap { Int(text[$0]) }
        }
    }

    // MARK: - (a) Scroll resets on a pane switch

    /// The detail `ScrollView` is created outside the pane switch, so its backing
    /// `NSScrollView` (and its offset) survives it: scrolled to the bottom of
    /// Storage, General opened at the bottom. The fix moves the scroller and
    /// nothing else, which is why `.id(selectionState.current)` is pinned *out*:
    /// re-identifying the content resets the offset as a side effect, but it also
    /// tears down every pane's own `@State`.
    func test_a_pane_switch_scrolls_the_detail_pane_back_to_the_top() throws {
        let view = try daemonSource("Sources/MeetingPipe/Preferences/PreferencesView.swift")
        XCTAssertTrue(view.contains("ScrollViewReader { proxy in"),
                      "the reset needs a proxy over the ScrollView that survives the switch")
        XCTAssertTrue(view.contains(".id(Self.topAnchor)"),
                      "scrollTo needs a target, and a constant id re-identifies nothing")
        XCTAssertTrue(view.contains(".onChange(of: selectionState.current)"),
                      "the pane switch is the trigger")
        XCTAssertTrue(view.contains("proxy.scrollTo(Self.topAnchor, anchor: .top)"))
        XCTAssertFalse(code(view).contains(".id(selectionState.current)"),
                       "identity reset would also discard pane-local @State; the reader only moves the scroller")
    }

    // MARK: - UX68: the anchor has to be outside the padding

    /// The half of the test above that calling `scrollTo` cannot prove. UX43's code
    /// called it correctly and still landed 28pt low, because the anchor was the
    /// padded stack's **first child** while `.padding(.vertical, 28)` was on the
    /// stack, putting the anchor's top edge below the scrollable content's true
    /// top. `anchor: .top` then did exactly as asked and left the padding scrolled
    /// off above the viewport.
    ///
    /// Pinned on ordering in the source, which is where this is decided: SwiftUI
    /// offers no runtime read of what a modifier is applied to, and the failure is
    /// invisible to anything that merely constructs the view.
    func test_the_top_anchor_is_not_a_child_of_the_padded_container() throws {
        let view = code(try daemonSource("Sources/MeetingPipe/Preferences/PreferencesView.swift"))
        guard let scroller = view.range(of: "ScrollView {"),
              let onChange = view.range(of: ".onChange(of: selectionState.current)",
                                        range: scroller.upperBound ..< view.endIndex) else {
            return XCTFail("the detail ScrollView no longer has this shape; re-point this fence")
        }
        let block = String(view[scroller.upperBound ..< onChange.lowerBound])

        guard let anchor = block.range(of: ".id(Self.topAnchor)"),
              let padding = block.range(of: ".padding(.vertical,",
                                        range: anchor.upperBound ..< block.endIndex) else {
            return XCTFail("the anchor or the vertical padding moved out of the ScrollView block")
        }
        // Source order alone proves nothing here: a modifier on a container is
        // written after the container's closing brace, so the anchor precedes the
        // padding in the text under both the broken and the fixed shape. The
        // discriminator is the brace. A `}` between them means the padding is
        // applied to the stack the anchor sits inside, which is the defect; none
        // means it is applied to `detailContent` beside the anchor, which is the
        // fix. A fence built on ordering passes on the bug, and this one was,
        // until it was checked against a deliberate revert.
        let between = String(block[anchor.upperBound ..< padding.lowerBound])
        XCTAssertFalse(between.contains("}"),
                       "the vertical padding must belong to detailContent, not to the stack holding the anchor")
        XCTAssertTrue(between.contains("detailContent"),
                      "the padding has to be the content's own, so the anchor stays at the true top")

        // The tempting one-liner, fenced out: a numeric compensation would look
        // right today and rot the moment the constant moves, which is the class
        // HYG5 spent a task removing.
        XCTAssertFalse(block.contains("anchor: UnitPoint("),
                       "a hand-built UnitPoint is how a padding offset gets compensated for")
        XCTAssertFalse(block.contains(".offset(y: -"),
                       "no negative offset may stand in for putting the anchor in the right place")
        XCTAssertTrue(block.contains("proxy.scrollTo(Self.topAnchor, anchor: .top)")
                      || view.contains("proxy.scrollTo(Self.topAnchor, anchor: .top)"),
                      "the scroll target stays a plain .top; UX68 moved the anchor, not the alignment")
    }

    // MARK: - (b) The window's floor, and the control column under a squeeze

    /// The window used to allow 720x560 while the SwiftUI root inside it declared
    /// 780x660, so resizing squeezed a hierarchy past its own stated minimum. The
    /// two numbers are read from the two files rather than restated here: a future
    /// change to either that forgets the other is exactly the drift this catches.
    func test_the_window_cannot_be_squeezed_past_the_floor_its_own_root_declares() throws {
        let window = try daemonSource("Sources/MeetingPipe/PreferencesWindow.swift")
        let view = try daemonSource("Sources/MeetingPipe/Preferences/PreferencesView.swift")

        let windowFloor = try numbers(
            in: window, matching: #"contentMinSize = NSSize\(width: (\d+), height: (\d+)\)"#
        )
        // The root's frame, not the doctor sheet's further down the same file.
        guard let bodyStart = view.range(of: "var body: some View {"),
              let bodyEnd = view.range(of: "private var detailContent",
                                       range: bodyStart.upperBound ..< view.endIndex) else {
            return XCTFail("PreferencesView's body no longer has the shape this fence reads; re-point it")
        }
        let body = String(view[bodyStart.lowerBound ..< bodyEnd.lowerBound])
        let rootFloor = try numbers(
            in: body, matching: #"\.frame\(minWidth: (\d+), minHeight: (\d+)\)"#
        )

        XCTAssertEqual(windowFloor.count, 2)
        XCTAssertEqual(windowFloor, rootFloor,
                       "the window's minimum must be the one its content declares, not a smaller number")
        XCTAssertFalse(code(window).contains("w.minSize = NSSize"),
                       "minSize is frame-space, so it would allow a content box a title bar shorter than the root asks for")
    }

    /// The info column is greedy and the controls carry no compression resistance,
    /// so the squeeze landed on the buttons: Storage's "Choose destination…" read
    /// as an ellipsis, and People and Caches carry the same two-ghost-button shape.
    /// One modifier on the shared row covers all three.
    func test_the_control_column_hugs_so_a_ghost_button_cannot_be_squeezed_into_an_ellipsis() throws {
        let controls = try daemonSource("Sources/MeetingPipe/Preferences/PreferencesControls.swift")
        guard let start = controls.range(of: "struct SettingsRow<Content: View>: View {"),
              let end = controls.range(of: "struct SettingsToggleRow",
                                       range: start.upperBound ..< controls.endIndex) else {
            return XCTFail("SettingsRow no longer has the shape this fence reads; re-point it")
        }
        let row = String(controls[start.lowerBound ..< end.lowerBound])
        XCTAssertTrue(row.contains(".fixedSize(horizontal: !controlFills, vertical: false)"),
                      "the control column keeps its natural width; vertical stays free so a control can still wrap")
        XCTAssertTrue(row.contains("controlFills: Bool = false"),
                      "hugging is the default; filling is the exception a scrolling preview asks for")

        let storage = try daemonSource("Sources/MeetingPipe/Preferences/PreferencesView+Storage.swift")
        XCTAssertFalse(code(storage).contains("controlFills: true"),
                       "the reported truncation was Storage's backup row; opting it out would put it straight back")
    }

    // MARK: - (c) Custom is a selection, not a dead branch

    func test_every_preset_round_trips_between_its_id_and_its_model_id() {
        XCTAssertFalse(LocalModelPreset.all.isEmpty)
        for preset in LocalModelPreset.all {
            XCTAssertEqual(LocalModelPreset.id(forModelId: preset.modelId), preset.id)
            XCTAssertEqual(LocalModelPreset.modelId(forID: preset.id), preset.modelId)
            XCTAssertFalse(LocalModelPreset.showsModelIdField(forID: preset.id),
                           "a preset writes its own id; the field would have nothing to do")
        }
    }

    /// The fall-through the preset comment describes: a config holding an id no
    /// preset pins (the dropped 32B, or anything hand-edited) keeps it and reads as
    /// Custom, rather than being silently rewritten to a preset.
    func test_a_model_id_no_preset_pins_reads_as_custom() {
        for id in ["mlx-community/Qwen2.5-32B-Instruct-4bit", "mlx-community/whatever", ""] {
            XCTAssertEqual(LocalModelPreset.id(forModelId: id), LocalModelPreset.customId,
                           "\(id) is pinned by no preset")
        }
    }

    /// The heart of the defect. Custom writes nothing, so a selection derived from
    /// the store alone could never hold it: the setter dropped the tag, the getter
    /// re-derived the previous preset, and the field gated on Custom could never
    /// appear. The field is now revealed for exactly the selections that write
    /// nothing, so the two rules cannot drift into a dead option again.
    func test_custom_writes_nothing_and_is_exactly_when_the_model_id_field_appears() {
        XCTAssertNil(LocalModelPreset.modelId(forID: LocalModelPreset.customId))
        XCTAssertTrue(LocalModelPreset.showsModelIdField(forID: LocalModelPreset.customId))
        for preset in LocalModelPreset.all {
            XCTAssertEqual(LocalModelPreset.showsModelIdField(forID: preset.id),
                           LocalModelPreset.modelId(forID: preset.id) == nil)
        }
    }

    /// `ConfigStore`'s save is debounced 500 ms, so a field cleared on the way to a
    /// new value would be persisted as a config naming no model at all. Shape 1 was
    /// picked over the sentinel shape for exactly this: nothing invalid is ever
    /// written on the way to something valid.
    /// The Anthropic model row persists through the same rule as the local Custom
    /// field. Here a blank write is worse than there: `summarization.model` serves the
    /// default backend, so `model = ""` would fail every summary until someone noticed.
    func test_a_blank_anthropic_model_id_never_reaches_the_store() {
        for blank in ["", " ", "\t", "\n", "   \n  "] {
            XCTAssertNil(ModelIdField.persistable(blank))
        }
        XCTAssertEqual(ModelIdField.persistable("  claude-opus-5-5 \n"), "claude-opus-5-5")
        for typed in ["", " x ", "mlx-community/Foo-4bit"] {
            XCTAssertEqual(ModelIdField.persistable(typed), LocalModelPreset.persistableModelId(typed),
                           "one rule for every typed model id, not two that can drift")
        }
    }

    /// The row is not gated on the Backend picker: Auto, a workflow pinning Anthropic,
    /// and Re-summarize with… all read `summarization.model` whatever the global
    /// backend is, so a row hidden behind `backend == "anthropic"` would leave those
    /// paths with a model nothing in the app can change.
    func test_the_anthropic_model_row_is_bound_through_the_draft_and_not_gated() throws {
        let pipeline = try daemonSource("Sources/MeetingPipe/Preferences/PreferencesView+Pipeline.swift")
        XCTAssertTrue(pipeline.contains(#"SettingsStackRow("Anthropic model""#))
        XCTAssertTrue(pipeline.contains("text: anthropicModelBinding"))
        XCTAssertTrue(pipeline.contains("ModelIdField.persistable(typed)"))
        XCTAssertFalse(pipeline.contains("text: $store.summarizationModel"),
                       "a direct binding would persist a cleared field as no model")
    }

    func test_a_blank_custom_id_never_reaches_the_store() {
        for blank in ["", " ", "\t", "\n", "   \n  "] {
            XCTAssertNil(LocalModelPreset.persistableModelId(blank))
        }
        XCTAssertEqual(LocalModelPreset.persistableModelId("  mlx-community/Foo-4bit \n"),
                       "mlx-community/Foo-4bit",
                       "a pasted repo id carries whitespace; it is trimmed, not rejected")
    }

    /// Not a restatement of the constant: if the shipped default model id and the
    /// preset table ever part company, a fresh config opens the picker on Custom
    /// with a model id nobody typed.
    func test_a_fresh_configs_default_model_is_a_preset_not_custom() throws {
        let store = try daemonSource("Sources/MeetingPipe/ConfigStore.swift")
        let re = try NSRegularExpression(
            pattern: #"local_model"\]\?\.string\s*\n?\s*\?\?\s*"([^"]+)""#
        )
        guard let m = re.firstMatch(in: store, range: NSRange(store.startIndex..., in: store)),
              let range = Range(m.range(at: 1), in: store) else {
            return XCTFail("ConfigStore's local_model fallback no longer has the shape this fence reads")
        }
        let fallback = String(store[range])
        XCTAssertNotEqual(LocalModelPreset.id(forModelId: fallback), LocalModelPreset.customId,
                          "\(fallback) is the default a fresh config gets; no preset pins it")
    }

    /// The owner walkthrough the task pre-registered, as a sequence rather than as
    /// four unrelated table lookups. `Picker` mirrors the two `@State`s and the two
    /// binding bodies in `PipelineSectionView`; the source fence below is what keeps
    /// it honest about the shape it is mirroring.
    private struct Picker {
        var stored: String
        var selection: String?
        var draft: String = ""

        var selectionId: String {
            selection ?? LocalModelPreset.id(forModelId: stored)
        }
        var showsField: Bool { LocalModelPreset.showsModelIdField(forID: selectionId) }

        mutating func pick(_ id: String) {
            selection = id
            guard let modelId = LocalModelPreset.modelId(forID: id) else {
                draft = stored
                return
            }
            stored = modelId
        }

        mutating func type(_ text: String) {
            draft = text
            if let modelId = LocalModelPreset.persistableModelId(text) { stored = modelId }
        }
    }

    func test_selecting_custom_typing_an_id_and_going_back_to_a_preset() {
        let recommended = LocalModelPreset.all[1]
        var picker = Picker(stored: recommended.modelId)
        XCTAssertEqual(picker.selectionId, recommended.id)
        XCTAssertFalse(picker.showsField)

        // Custom stays selected (it used to snap back) and seeds the field with the
        // id in force, so the owner edits from it rather than from an empty box.
        picker.pick(LocalModelPreset.customId)
        XCTAssertEqual(picker.selectionId, LocalModelPreset.customId)
        XCTAssertTrue(picker.showsField)
        XCTAssertEqual(picker.draft, recommended.modelId)
        XCTAssertEqual(picker.stored, recommended.modelId, "selecting Custom writes nothing by itself")

        // Clearing it does not clear the configured model.
        picker.type("")
        XCTAssertEqual(picker.stored, recommended.modelId)

        // A typed id persists, and the picker stays on Custom rather than being
        // re-derived out from under the user.
        picker.type("mlx-community/Ministral-8B-Instruct-2410-4bit")
        XCTAssertEqual(picker.stored, "mlx-community/Ministral-8B-Instruct-2410-4bit")
        XCTAssertEqual(picker.selectionId, LocalModelPreset.customId)

        // Re-selecting a preset writes that preset's id and hides the field.
        let small = LocalModelPreset.all[0]
        picker.pick(small.id)
        XCTAssertEqual(picker.stored, small.modelId)
        XCTAssertFalse(picker.showsField)

        // And a reopen with no explicit selection reads the store: still the preset.
        XCTAssertEqual(Picker(stored: picker.stored).selectionId, small.id)
        // A custom id survives the reopen as Custom, which is the acceptance's last step.
        XCTAssertEqual(Picker(stored: "mlx-community/Ministral-8B-Instruct-2410-4bit").selectionId,
                       LocalModelPreset.customId)
    }

    /// The wiring the pure seam cannot see: that the pane actually holds the
    /// selection and routes the field through a draft. Both halves are the defect
    /// itself, so both are pinned in source.
    func test_the_pane_holds_the_custom_selection_instead_of_dropping_it() throws {
        let pipeline = try daemonSource("Sources/MeetingPipe/Preferences/PreferencesView+Pipeline.swift")
        XCTAssertTrue(pipeline.contains("localModelSelection = newID"),
                      "the setter has to record the selection; Custom writes nothing else")
        XCTAssertFalse(code(pipeline).contains("if newID != LocalModelPreset.customId"),
                       "the dead branch: the setter dropped the one tag the picker always offered")
        XCTAssertFalse(code(pipeline).contains(#"text: $store.summarizationLocalModel"#),
                       "the field must write through the draft, so a cleared box cannot be saved")
        XCTAssertTrue(pipeline.contains("text: customModelIdBinding"))
        XCTAssertTrue(pipeline.contains("LocalModelPreset.showsModelIdField(forID: localModelSelectionId)"),
                      "the field is gated on the selection, not on what the store happens to hold")
    }
}
