import XCTest
@testable import MeetingPipe

/// UX49: the done notification named Notion on every meeting, in its body and on
/// its Open button, while nine consecutive publishes had gone to the filesystem.
/// The phrase is derived now, so these pin the derivation and the copy it feeds.
final class PublishLandingTests: XCTestCase {

    private func result(
        _ sinks: [(name: String, ok: Bool)],
        pageURL: String?
    ) -> PublishResult {
        PublishResult(
            state: sinks.allSatisfy(\.ok) ? "full" : "partial",
            pageURL: pageURL.flatMap(URL.init(string:)),
            sinks: sinks.map {
                PublishResult.SinkOutcome(name: $0.name, ok: $0.ok, pageURL: nil)
            }
        )
    }

    private func landing(
        _ sinks: [(name: String, ok: Bool)],
        pageURL: String?
    ) -> PublishLanding {
        PublishLanding.decide(
            publish: result(sinks, pageURL: pageURL),
            pageURL: pageURL.flatMap(URL.init(string:))
        )
    }

    // MARK: - Which sink the surface names

    /// The bug itself. The owner's default workflow publishes here and nowhere
    /// else, and the banner said Notion for every one of them.
    func test_a_filesystem_publish_names_the_local_note_and_never_notion() {
        let landing = self.landing(
            [(name: "filesystem", ok: true)],
            pageURL: "file:///Users/me/Documents/Meetings/published/m.summary.md"
        )
        XCTAssertEqual(landing, .sink(.filesystem))
        XCTAssertEqual(landing.openPhrase, "Open the local note")
        XCTAssertFalse(landing.openPhrase!.contains("Notion"))
    }

    func test_a_notion_publish_still_names_notion() {
        let landing = self.landing(
            [(name: "notion", ok: true)], pageURL: "https://www.notion.so/Meeting-abc"
        )
        XCTAssertEqual(landing, .sink(.notion))
        XCTAssertEqual(landing.openPhrase, "Open in Notion")
    }

    /// Two landings, one URL: `page_url` is whichever sink came first in
    /// `output.sinks`, so naming it would promote a config detail into a claim
    /// about where the meeting lives.
    func test_two_sinks_landing_is_named_neutrally() {
        let landing = self.landing(
            [(name: "notion", ok: true), (name: "filesystem", ok: true)],
            pageURL: "https://www.notion.so/Meeting-abc"
        )
        XCTAssertEqual(landing, .unnamed)
        XCTAssertEqual(landing.openPhrase, "Open summary")
    }

    /// A failed sink is not a landing, so the one that did land is still named.
    func test_a_failed_sink_does_not_make_the_phrase_neutral() {
        let landing = self.landing(
            [(name: "notion", ok: false), (name: "filesystem", ok: true)],
            pageURL: "file:///Users/me/published/m.summary.md"
        )
        XCTAssertEqual(landing, .sink(.filesystem))
    }

    /// No URL means no Open affordance at all, rather than a button that cannot
    /// open anything. Decisive over whatever the sink map says.
    func test_nothing_openable_offers_no_open_affordance() {
        let landing = self.landing([(name: "obsidian", ok: true)], pageURL: nil)
        XCTAssertEqual(landing, .nowhere)
        XCTAssertNil(landing.openPhrase)
        XCTAssertNil(NotificationRouter.doneCategory(for: landing, canCorrect: false))
        XCTAssertNil(NotificationRouter.doneCategory(for: landing, canCorrect: true))
    }

    /// Every `run-all` short-circuit (no speech, BYO, too long, Apple hand-off)
    /// stops before publish and writes no sidecar. Absent is not a failure.
    func test_an_absent_publish_sidecar_with_no_url_is_nowhere() {
        XCTAssertEqual(PublishLanding.decide(publish: nil, pageURL: nil), .nowhere)
    }

    /// A live URL with nothing to attribute it to keeps the affordance and drops
    /// the name: never claim a sink on no evidence, never lose a working Open.
    func test_a_url_with_no_readable_sink_map_keeps_a_neutral_open() {
        XCTAssertEqual(
            PublishLanding.decide(publish: nil, pageURL: URL(string: "https://x.test/p")),
            .unnamed
        )
        XCTAssertEqual(landing([], pageURL: "https://x.test/p"), .unnamed)
    }

    func test_a_sink_name_this_build_does_not_know_is_not_guessed_at() {
        XCTAssertEqual(
            landing([(name: "carrier_pigeon", ok: true)], pageURL: "https://x.test/p"),
            .unnamed
        )
    }

    // MARK: - The copy

    func test_a_named_landing_leads_the_body_with_its_own_phrase() {
        let copy = DoneNotificationCopy.make(landing: .sink(.filesystem), canCorrect: false)
        XCTAssertEqual(copy.title, "Meeting published")
        XCTAssertEqual(copy.body, "Open the local note")
        XCTAssertEqual(copy.openPhrase, "Open the local note")
    }

    func test_a_gradeable_summary_appends_the_correction_question() {
        let copy = DoneNotificationCopy.make(landing: .sink(.notion), canCorrect: true)
        XCTAssertEqual(copy.body, "Open in Notion. How did this summary look?")
        XCTAssertEqual(copy.openPhrase, "Open in Notion")
    }

    /// The variant this replaces asserted "Local Markdown ready (regulated
    /// mode)" off a nil page URL, which is a claim about the *mode* keyed on
    /// something else entirely.
    func test_nothing_published_says_so_and_claims_no_mode() {
        for canCorrect in [true, false] {
            let copy = DoneNotificationCopy.make(landing: .nowhere, canCorrect: canCorrect)
            XCTAssertEqual(copy.title, "Meeting processed")
            XCTAssertNil(copy.openPhrase)
            XCTAssertTrue(copy.body.hasPrefix("Nothing was published."), copy.body)
            XCTAssertFalse(copy.body.lowercased().contains("regulated"), copy.body)
            XCTAssertEqual(copy.body.contains("How did this summary look?"), canCorrect)
        }
    }

    func test_no_copy_the_banner_can_reach_mentions_a_sink_that_did_not_run() {
        for landing in PublishLanding.openable + [.nowhere] {
            for canCorrect in [true, false] {
                let copy = DoneNotificationCopy.make(landing: landing, canCorrect: canCorrect)
                for sink in PublishSink.allCases where landing != .sink(sink) {
                    XCTAssertFalse(
                        copy.body.contains(sink.openPhrase),
                        "\(landing) claimed \(sink.rawValue): \(copy.body)"
                    )
                }
            }
        }
    }

    // MARK: - Categories

    /// An action's title is fixed when its category is registered, so a phrase
    /// that shares a category with another phrase cannot be shown. Distinctness
    /// is what makes the button honest.
    func test_every_open_phrase_gets_its_own_category() {
        var ids: Set<String> = []
        for landing in PublishLanding.openable {
            for canCorrect in [true, false] {
                let id = NotificationRouter.doneCategory(for: landing, canCorrect: canCorrect)
                XCTAssertNotNil(id, "\(landing) has an Open phrase but no category")
                XCTAssertTrue(ids.insert(id!).inserted, "duplicate category \(id!)")
            }
        }
        XCTAssertEqual(ids.count, (PublishSink.allCases.count + 1) * 2)
        // The one done category with no Open action must stay out of that set,
        // or a banner with nothing to open would offer a button.
        XCTAssertFalse(ids.contains(NotificationRouter.doneCorrectableLocalCategory))
    }

    /// The neutral landing keeps the two original identifiers, so a banner
    /// posted before this shipped still resolves its buttons.
    func test_the_neutral_landing_keeps_the_original_identifiers() {
        XCTAssertEqual(
            NotificationRouter.doneCategory(for: .unnamed, canCorrect: false),
            NotificationRouter.doneCategory
        )
        XCTAssertEqual(
            NotificationRouter.doneCategory(for: .unnamed, canCorrect: true),
            NotificationRouter.doneCorrectableCategory
        )
    }

    /// The correctable variants stay distinguishable from the plain ones, since
    /// only they carry the correction actions.
    func test_a_named_category_is_derived_from_its_base() {
        XCTAssertEqual(
            NotificationRouter.doneCategory(for: .sink(.filesystem), canCorrect: false),
            "MP_DONE_FILESYSTEM"
        )
        XCTAssertEqual(
            NotificationRouter.doneCategory(for: .sink(.filesystem), canCorrect: true),
            "MP_DONE_CORRECTABLE_FILESYSTEM"
        )
    }

    // MARK: - Vocabulary

    /// Three types carry the sink vocabulary and each answers a different
    /// question, so they are pinned to each other rather than merged: a fifth
    /// sink must not be nameable on one side only. The pipeline's own list is
    /// `publish_router._build_one`.
    func test_the_sink_vocabulary_matches_the_workflow_editors() {
        let workflowSinks: [WorkflowSink] = [
            .notion(databaseId: "db"), .obsidian, .filesystem, .lan,
        ]
        XCTAssertEqual(
            Set(PublishSink.allCases.map(\.sinkTypeName)),
            Set(workflowSinks.map(\.typeName))
        )
        for target in PublishTarget.allCases {
            XCTAssertNotNil(
                PublishSink(rawValue: target.sinkTypeName),
                "\(target.sinkTypeName) is a publish target with no name for a landing"
            )
        }
    }

    func test_every_sink_is_named_distinctly_and_says_what_to_do() {
        var phrases: Set<String> = []
        for sink in PublishSink.allCases {
            XCTAssertTrue(
                sink.openPhrase.hasPrefix("Open "),
                "\(sink.rawValue): \(sink.openPhrase)"
            )
            XCTAssertTrue(phrases.insert(sink.openPhrase).inserted, sink.openPhrase)
        }
        XCTAssertFalse(phrases.contains(PublishLanding.unnamed.openPhrase!))
    }

    /// UX62 added the icon register beside the phrase, for the same reason: the
    /// detail header spelled two icons inline and was about to spell a third.
    func test_every_sink_carries_its_own_symbol() {
        var symbols: Set<String> = []
        for sink in PublishSink.allCases {
            XCTAssertFalse(sink.symbolName.isEmpty, sink.rawValue)
            XCTAssertTrue(symbols.insert(sink.symbolName).inserted,
                          "\(sink.rawValue) shares an icon with another sink")
        }
    }

    // MARK: - The header's local-note affordance (UX62)

    private func withPageURLs(
        _ sinks: [(name: String, ok: Bool, page: String?)]
    ) -> PublishResult {
        PublishResult(
            state: sinks.contains(where: \.ok) ? "full" : "none",
            pageURL: sinks.first(where: \.ok)?.page.flatMap(URL.init(string:)),
            sinks: sinks.map {
                PublishResult.SinkOutcome(
                    name: $0.name, ok: $0.ok, pageURL: $0.page.flatMap(URL.init(string:))
                )
            }
        )
    }

    /// The defect: the owner's default workflow is filesystem-only, and that
    /// publish had no open action at all despite `page_url` being a `file://`
    /// URL `NSWorkspace.open` handles directly.
    func test_a_filesystem_publish_is_openable() {
        let note = PublishLanding.localNote(publish: withPageURLs([
            (name: "filesystem", ok: true, page: "file:///Users/me/published/m.summary.md"),
        ]))
        XCTAssertEqual(note?.sink, .filesystem)
        XCTAssertEqual(note?.url.path, "/Users/me/published/m.summary.md")
    }

    func test_a_lan_publish_is_openable() {
        let note = PublishLanding.localNote(publish: withPageURLs([
            (name: "lan", ok: true, page: "file:///Volumes/share/m.summary.md"),
        ]))
        XCTAssertEqual(note?.sink, .lan)
    }

    /// Notion and Obsidian keep their own buttons, built from their own
    /// sidecars: Obsidian's is an `obsidian://` deep link assembled from the
    /// vault relationship, and offering this one instead would open the note
    /// outside Obsidian.
    func test_notion_and_obsidian_are_not_this_buttons_business() {
        XCTAssertNil(PublishLanding.localNote(publish: withPageURLs([
            (name: "notion", ok: true, page: "https://notion.so/p"),
        ])))
        XCTAssertNil(PublishLanding.localNote(publish: withPageURLs([
            (name: "obsidian", ok: true, page: "file:///Users/me/vault/m.md"),
        ])))
    }

    func test_a_failed_filesystem_sink_offers_nothing() {
        XCTAssertNil(PublishLanding.localNote(publish: withPageURLs([
            (name: "filesystem", ok: false, page: "file:///Users/me/published/m.summary.md"),
        ])))
    }

    func test_a_landed_sink_with_no_page_url_offers_nothing() {
        XCTAssertNil(PublishLanding.localNote(publish: withPageURLs([
            (name: "filesystem", ok: true, page: nil),
        ])))
    }

    func test_no_publish_sidecar_offers_nothing() {
        XCTAssertNil(PublishLanding.localNote(publish: nil))
    }

    /// A run doing both wrote the same content twice; the local copy is the one
    /// that opens with no mount in play. Pinned because "whichever came first"
    /// is exactly the accident the top-level `page_url` already is.
    func test_filesystem_wins_over_lan_when_both_landed() {
        let note = PublishLanding.localNote(publish: withPageURLs([
            (name: "lan", ok: true, page: "file:///Volumes/share/m.summary.md"),
            (name: "filesystem", ok: true, page: "file:///Users/me/published/m.summary.md"),
        ]))
        XCTAssertEqual(note?.sink, .filesystem)
    }

    /// Per-sink `page_url`, never the top-level one, which is whichever sink came
    /// first in `output.sinks` order: taking it here would put a Notion URL
    /// behind a button captioned "Open the local note".
    func test_takes_the_sinks_own_url_not_the_top_level_one() {
        let publish = PublishResult(
            state: "full",
            pageURL: URL(string: "https://notion.so/p"),
            sinks: [
                PublishResult.SinkOutcome(
                    name: "filesystem", ok: true,
                    pageURL: URL(string: "file:///Users/me/published/m.summary.md")
                ),
                PublishResult.SinkOutcome(
                    name: "notion", ok: true, pageURL: URL(string: "https://notion.so/p")
                ),
            ]
        )
        XCTAssertEqual(PublishLanding.localNote(publish: publish)?.url.scheme, "file")
    }
}
