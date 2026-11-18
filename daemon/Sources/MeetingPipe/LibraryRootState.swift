import AppKit
import Foundation
import os

/// What a scan found at the library root (UX89). One type for every root question, so the Library,
/// the background sweeps and doctor read the same answer rather than each treating a failed listing
/// as an empty library.
enum LibraryRootState: Equatable {
    /// The root listed. It may hold no meetings; that is the first-run empty list.
    case readable
    /// Nothing exists at the configured path: a typo, an unmounted volume, or a library moved or
    /// deleted outside the app. The Library names the path and offers to choose a folder.
    case missing
    /// Something is at the path and it cannot be listed (STOR11): a TCC denial of the folder that
    /// holds it, wrong permissions after a restore, or a stalled volume. Not an empty library, and
    /// not a missing one: nothing should be created over it and nothing should read it as "no meetings".
    case unreadable(errno: Int32, reason: String)

    /// One read of the root: list it and classify the failure, if any.
    static func probe(_ directory: URL) -> LibraryRootState {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return .readable
        } catch {
            return classify(error)
        }
    }

    /// The state a failed listing means, from the POSIX code under the Cocoa error. Decided on the
    /// code alone, never on `fileExists`: under a TCC denial of the parent, `stat` fails too, so a
    /// denied folder would read as missing and invite a "Choose folder" over a library that is there.
    static func classify(_ error: Error) -> LibraryRootState {
        let code = posixCode(of: error)
        if code == ENOENT { return .missing }
        return .unreadable(errno: code, reason: String(cString: strerror(code)))
    }

    static func posixCode(of error: Error) -> Int32 {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return ENOENT
            case NSFileReadNoPermissionError: return EACCES
            default: break
            }
        }
        return EIO
    }

    /// Whether the fix is a privacy grant (System Settings) rather than the folder itself.
    var isPermissionDenial: Bool {
        if case .unreadable(let code, _) = self { return code == EPERM || code == EACCES }
        return false
    }

    /// Whether the Library may create a missing root when it starts watching. Only the first-run
    /// default, and never a root the app has re-rooted away from: creating that one would put an
    /// empty folder back where a move just took the library from (F058), and creating any other
    /// would turn a typo or an unmounted volume into an empty library that hides the real one.
    static func mayCreate(root: URL, creatableRoot: URL?, departed: Set<URL>, exists: Bool) -> Bool {
        guard !exists, let creatableRoot else { return false }
        let root = root.standardizedFileURL
        guard root == creatableRoot.standardizedFileURL else { return false }
        return !departed.contains(root)
    }
}

/// Which placeholder the Library list shows, if any (UX89). Pure, so the choice between the
/// first-run empty state and the missing-root state is tested without rendering a view.
enum LibraryListPlaceholder: Equatable {
    case loading
    case firstRun
    case missingRoot(path: String)
    /// STOR11: the root is there and cannot be listed. `permission` picks the action offered.
    case unreadableRoot(path: String, reason: String, permission: Bool)
    /// There are meetings; no placeholder.
    case none

    static func decide(
        hasLoadedOnce: Bool, isEmpty: Bool, rootState: LibraryRootState, root: URL
    ) -> LibraryListPlaceholder {
        guard hasLoadedOnce else { return .loading }
        guard isEmpty else { return .none }
        let path = (root.path as NSString).abbreviatingWithTildeInPath
        switch rootState {
        case .readable: return .firstRun
        case .missing: return .missingRoot(path: path)
        case .unreadable(_, let reason):
            return .unreadableRoot(path: path, reason: reason, permission: rootState.isPermissionDenial)
        }
    }
}

/// `coordinator` / `library_unreadable` for the background readers of the root (STOR11): the
/// stranded-job sweep, orphan recovery and the menu's failed count each return early on a listing
/// that failed, which used to be silent. One row per site per state change, never one per call:
/// the failed count runs on every menu open. A readable or missing root re-arms the site.
final class LibraryUnreadableReporter: Sendable {
    static let shared = LibraryUnreadableReporter()

    typealias Emit = @Sendable (_ attributes: [String: Any]) -> Void
    private let emit: Emit
    /// Site -> the errno last reported for it.
    private let reported = OSAllocatedUnfairLock<[String: Int32]>(initialState: [:])

    init(emit: @escaping Emit = { attributes in
        // OBS1: a failure, so events.jsonl, daemon.log and os.Logger all carry it.
        Log.failure(
            category: "coordinator", action: "library_unreadable",
            reason: attributes["reason"] as? String ?? "unreadable", attributes: attributes
        )
    }) {
        self.emit = emit
    }

    func note(_ state: LibraryRootState, site: String) {
        guard case .unreadable(let code, let reason) = state else {
            reported.withLock { _ = $0.removeValue(forKey: site) }
            return
        }
        let isNew = reported.withLock { map -> Bool in
            if map[site] == code { return false }
            map[site] = code
            return true
        }
        if isNew {
            emit(["site": site, "reason": reason, "errno": Int(code)])
        }
    }
}

/// What the unreadable-root state offers when the cause is a privacy denial (STOR11).
enum LibraryRootRemedy {
    static let privacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"

    static func openPrivacySettings() {
        if let url = URL(string: privacySettingsURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
