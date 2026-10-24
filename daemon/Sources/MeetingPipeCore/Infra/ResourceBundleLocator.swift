import Foundation

/// DIST4: where a SwiftPM resource bundle is loaded from, so no source file calls `Bundle.module`.
///
/// SwiftPM's generated `Bundle.module` looks in exactly two places, `Bundle.main.bundleURL` (for an app, the `.app` root) and an absolute path into the build tree it was compiled in, and calls `fatalError` when neither has the bundle. The installed app keeps its bundles in `Contents/Resources`, which is neither, so before DIST4 it only ran while `<repo>/daemon/.build` existed, and moving the repo crash-looped it under launchd.
public enum ResourceBundleLocator {
    /// The bundle to read `<name>`'s resources from:
    /// - `<main's Contents/Resources>/<name>.bundle` when it exists (the installed app);
    /// - inside an `.app` that lacks it, `main` itself, so every lookup misses and each caller's not-found path runs (an empty catalogue, a blank glyph) instead of a crash loop; `MeetingPipe doctor`'s `app.resources` probe names it;
    /// - outside an `.app` (`swift run`, `swift test`), nil, and the caller falls back to its `Bundle.module`, whose build-tree path exists there.
    public static func bundle(named name: String, main: Bundle = .main) -> Bundle? {
        if let resources = main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("\(name).bundle")) {
            return bundle
        }
        return main.bundleURL.pathExtension == "app" ? main : nil
    }
}

extension Bundle {
    /// SwiftPM's name for this target's resource bundle (`<Package>_<Target>`). Pinned by a test against the `Bundle.module` SwiftPM generated.
    static let coreResourceBundleName = "MeetingPipe_MeetingPipeCore"

    /// MeetingPipeCore's resources (`MuteLabels.toml`). Use this, never `Bundle.module`; see `ResourceBundleLocator`.
    static let coreResources: Bundle = ResourceBundleLocator.bundle(named: coreResourceBundleName) ?? .module
}
