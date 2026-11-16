import AppKit
import Foundation
import SwiftUI

/// Which URLs this app will hand to the system, in one place (SEC30).
///
/// Two callers, two rules, because the two sources are not equally trusted:
///
/// - **Model-written text** (a summary bullet, an action item, an Ask answer, rich text copied out of
///   the app) can carry any `[label](target)` a prompt-injected transcript talked the model into. The
///   label hides the target, and a click on `meetingpipe://stop` came back through
///   `App.application(_:open:)` as an unconfirmed automation verb. Only `http`, `https` and `mailto`
///   are ever followed, and an `http(s)` link shows its full address first, since an allowlist alone
///   does not stop a query-string leak through the browser.
/// - **A publish sidecar's `page_url`** is written by this app's own pipeline, so it can only steer
///   anywhere through a tampered backup. It opens only what a sink really produces: an `https` page
///   for Notion, the `obsidian://open` link this app assembles, and a `.md` file under a root the
///   owner configured.
///
/// `GuideDocument.canFollow` was the one allowlist in the daemon, for the bundled guide; it now reads
/// the same scheme set from here.
enum ExternalURLPolicy {
    /// The schemes a link in prose may open.
    static let followableSchemes: Set<String> = ["http", "https", "mailto"]

    /// Whether a markdown link target (`[a](target)`) names something the system can open.
    static func canFollow(_ target: String) -> Bool {
        guard let colon = target.firstIndex(of: ":") else { return false }
        return followableSchemes.contains(target[..<colon].lowercased())
    }

    // MARK: - Model-written text

    enum ModelTextDecision: Equatable {
        /// Inert: never opens, and `SummaryMarkdown` renders it as plain text.
        case refuse
        /// A `mailto:` opens a compose window the owner still has to send.
        case open
        /// `http` / `https`: show the full address, then open on a yes.
        case confirm
    }

    static func modelTextDecision(_ url: URL) -> ModelTextDecision {
        switch url.scheme?.lowercased() {
        case "http", "https": return .confirm
        case "mailto": return .open
        default: return .refuse
        }
    }

    /// `http`, `https` and `mailto` only; `meetingpipe:` is never allowed, and falls out of the same
    /// rule as every other scheme the list does not name.
    static func canOpenFromModelText(_ url: URL) -> Bool {
        modelTextDecision(url) != .refuse
    }

    /// The `OpenURLAction` every surface that renders model text sits under. `.discarded` for a refused
    /// link, so a link that slipped past `SummaryMarkdown` still does nothing.
    static func modelTextAction(
        confirm: @escaping (URL) -> Bool = ExternalURLPolicy.confirmWithDialog,
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) -> OpenURLAction {
        OpenURLAction { url in
            switch modelTextDecision(url) {
            case .refuse:
                Log.event(category: "daemon", action: "link_refused",
                          attributes: ["source": "model_text", "scheme": url.scheme?.lowercased() ?? ""])
                return .discarded
            case .open:
                return .systemAction
            case .confirm:
                if confirm(url) { open(url) }
                return .handled
            }
        }
    }

    /// The full address in front of the owner, because the label is what the model chose to show.
    static func confirmWithDialog(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Open this link?"
        alert.informativeText = "The text you clicked is written by the summarizing model and may not match where it goes.\n\n\(url.absoluteString)"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Publish sidecar targets

    /// What a publish sidecar's `page_url` may open. `sink` narrows the rule to that sink's own shape;
    /// nil (the done notification, which knows only the URL) accepts any shape a sink produces.
    static func canOpenPublishTarget(_ url: URL, sink: PublishSink?, roots: [URL]) -> Bool {
        let scheme = url.scheme?.lowercased()
        let allowsPage = sink == nil || sink == .notion
        let allowsDeepLink = sink == nil || sink == .obsidian
        let allowsFile = sink != .notion
        switch scheme {
        case "https":
            return allowsPage
        case "obsidian":
            return allowsDeepLink && url.host?.lowercased() == "open"
        case "file":
            return allowsFile && isNoteFile(url, under: roots)
        default:
            return false
        }
    }

    /// A `.md` file strictly under one of `roots`, after resolving `..` and symlinks, so neither a
    /// traversal nor a link inside a root reaches an application or a script outside it.
    static func isNoteFile(_ url: URL, under roots: [URL]) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "md" else { return false }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return roots.contains { root in
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            guard !base.isEmpty, base != "/" else { return false }
            return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// The directories a publish may have written a note under: the library, and each sink's own root
    /// from `config.toml`. Read at click time so a changed setting applies without a restart.
    static func configuredRoots(store: ConfigStore = ConfigStore()) -> [URL] {
        [store.outputDirPath, store.filesystemOutputDir, store.obsidianVaultPath, store.lanMountPath]
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Open a publish target if the policy allows it; otherwise log one diagnostics line and open nothing.
    /// Returns whether it opened.
    @discardableResult
    static func openPublishTarget(
        _ url: URL,
        sink: PublishSink? = nil,
        roots: @autoclosure () -> [URL] = ExternalURLPolicy.configuredRoots(),
        open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        guard canOpenPublishTarget(url, sink: sink, roots: roots()) else {
            Log.event(category: "daemon", action: "link_refused",
                      attributes: ["source": "publish_target", "scheme": url.scheme?.lowercased() ?? "",
                                   "sink": sink?.rawValue ?? ""])
            return false
        }
        open(url)
        return true
    }
}
