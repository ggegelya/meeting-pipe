import Foundation
import MeetingPipeCore

extension Bundle {
    /// SwiftPM's name for this target's resource bundle (`<Package>_<Target>`). Pinned by a test against the `Bundle.module` SwiftPM generated.
    static let appResourceBundleName = "MeetingPipe_MeetingPipe"

    /// The executable target's resources (`meeting_apps.toml`, the app glyph SVGs). Use this, never `Bundle.module`, whose accessor `fatalError`s in an installed app once `<repo>/daemon/.build` is gone (DIST4); see `ResourceBundleLocator`.
    static let appResources: Bundle = ResourceBundleLocator.bundle(named: appResourceBundleName) ?? .module
}
