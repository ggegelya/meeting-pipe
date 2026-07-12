import XCTest
@testable import MeetingPipe
import MeetingPipeCore

/// DET4 coverage fence: the bundled `meeting_apps.toml` and the adapter/recognizer layer must
/// stay in lockstep. Before DET4 they had drifted silently: `com.cisco.spark` had an adapter but
/// no TOML row (never discovered); Brave/Vivaldi/Opera/Kagi/Canary had TOML rows but no lifecycle
/// adapter (discovered, then a `no_adapter_for_context` no-op, so they never prompted); and
/// `com.skype.skype` / `com.google.meet` were dead rows with neither. These tests go red on any
/// such drift, so the next vendor rename or additive edit is caught here, not in the field.
final class MeetingAppRegistryFenceTests: XCTestCase {

    /// Bundled defaults only, so the shipped data is asserted regardless of any user overlay on
    /// the machine running the tests.
    private let registry = MeetingAppRegistry.bundled

    // MARK: - Native: every whitelist bundle has an adapter + recognizer

    func test_every_native_bundle_has_a_lifecycle_adapter() {
        let adapterCoverage = Set(NativeLifecycleConfig.all.flatMap { $0.bundleIDs })
        for bundle in registry.nativeBundles {
            XCTAssertTrue(
                adapterCoverage.contains(bundle),
                "meeting_apps.toml [native] lists '\(bundle)' but no NativeLifecycleConfig serves it. "
                    + "Add a config to NativeLifecycleConfig.all or remove the dead row."
            )
        }
    }

    func test_every_native_bundle_has_mute_and_leave_predicates() {
        // `appNameByBundle` is the mute-catalogue key; its presence also gates the per-bundle
        // leave/mute AX predicates in MeetingAXHandleBuilder. A native without it can be discovered
        // but never has its mute button read.
        for bundle in registry.nativeBundles {
            XCTAssertNotNil(
                MeetingAXHandleBuilder.appNameByBundle[bundle],
                "meeting_apps.toml [native] lists '\(bundle)' but MeetingAXHandleBuilder.appNameByBundle "
                    + "has no entry, so its mute/leave AX predicates never fire."
            )
        }
    }

    func test_every_native_bundle_has_a_title_recognizer_branch() {
        // A representative live-meeting title per shipped native. A native added to the TOML
        // without a representative here fails the test, forcing the author to wire an
        // `isActiveMeetingWindow` branch (otherwise the bundle falls through to `default → false`
        // and its titleMatch signal is dead, the pre-DET4 com.cisco.spark gap).
        let representativeTitle: [String: String] = [
            "us.zoom.xos": "Zoom Meeting",
            "com.microsoft.teams2": "Standup | Microsoft Teams",
            "com.microsoft.teams": "Standup | Microsoft Teams",
            "com.tinyspeck.slackmacgap": "Huddle - #engineering",
            "com.cisco.webexmeetingsapp": "Webex Meeting",
            "com.cisco.spark": "Webex Meeting",
        ]
        for bundle in registry.nativeBundles {
            guard let title = representativeTitle[bundle] else {
                XCTFail("No representative meeting title for native '\(bundle)'. Add one and confirm "
                    + "MeetingSourceScanner.isActiveMeetingWindow has a branch for it.")
                continue
            }
            XCTAssertTrue(
                MeetingSourceScanner.isActiveMeetingWindow(bundleID: bundle, kind: .native, title: title),
                "MeetingSourceScanner.isActiveMeetingWindow does not recognise '\(title)' for '\(bundle)'."
            )
        }
    }

    // MARK: - Browser: the TOML set is exactly the adapter's handled set

    func test_browser_toml_set_equals_the_lifecycle_adapter_set() {
        XCTAssertEqual(
            registry.browserBundles,
            BrowserMeetingLifecycleAdapter.defaultBrowserBundleIDs,
            "meeting_apps.toml [browser.bundles] must equal "
                + "BrowserMeetingLifecycleAdapter.defaultBrowserBundleIDs, so a browser discovery "
                + "enumerates always has a lifecycle adapter."
        )
    }

    // MARK: - mic_plausible: adapterless-by-design, disjoint from the whitelist

    func test_mic_plausible_tier_is_present_and_disjoint() {
        XCTAssertFalse(registry.micPlausibleBundles.isEmpty,
                       "[mic_plausible] should list the adapterless meeting apps DET1 names.")
        XCTAssertTrue(registry.micPlausibleBundles.isDisjoint(with: registry.nativeBundles),
                      "A bundle can't be both an adapter-backed native and adapterless mic-plausible.")
        XCTAssertTrue(registry.micPlausibleBundles.isDisjoint(with: registry.browserBundles),
                      "A bundle can't be both a browser and mic-plausible.")
    }

    // MARK: - Regression: the specific drift DET4 fixed

    func test_spark_is_discoverable_and_dead_rows_are_gone() {
        XCTAssertTrue(registry.nativeBundles.contains("com.cisco.spark"),
                      "The unified Webex App must be discoverable.")
        XCTAssertFalse(registry.nativeBundles.contains("com.skype.skype"), "Dead Skype row.")
        XCTAssertFalse(registry.nativeBundles.contains("com.google.meet"),
                       "Dead google.meet row (Meet is browser-only).")
    }

    // MARK: - Overlay: a user can add a bundle without a rebuild

    func test_user_overlay_unions_over_the_bundled_defaults() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("det4-overlay-\(UUID().uuidString).toml")
        let overlay = """
        [native]
        bundle_ids = ["com.example.customcall"]

        [browser.bundles]
        ids = ["com.example.CustomBrowser"]

        [mic_plausible]
        bundle_ids = ["com.example.voice"]
        """
        try overlay.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let merged = MeetingAppRegistry.load(overlayURL: tmp)

        // Overlay entries are present...
        XCTAssertTrue(merged.nativeBundles.contains("com.example.customcall"))
        XCTAssertTrue(merged.browserBundles.contains("com.example.CustomBrowser"))
        XCTAssertTrue(merged.micPlausibleBundles.contains("com.example.voice"))
        // ...unioned with, not replacing, the bundled defaults.
        XCTAssertTrue(merged.nativeBundles.contains("us.zoom.xos"))
        XCTAssertTrue(merged.browserBundles.contains("com.apple.Safari"))
        XCTAssertTrue(merged.micPlausibleBundles.contains("com.apple.FaceTime"))
    }

    func test_missing_overlay_is_ignored() {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("det4-absent-\(UUID().uuidString).toml")
        let merged = MeetingAppRegistry.load(overlayURL: absent)
        XCTAssertEqual(merged.nativeBundles, registry.nativeBundles)
        XCTAssertEqual(merged.browserBundles, registry.browserBundles)
    }
}
