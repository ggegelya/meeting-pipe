import Foundation
import Security

/// Tags post-rebuild launches so dogfood analysis can exclude TCC re-grant churn.
/// decide() is pure (cdhash in, outcome out) so XCTest can drive it without
/// SecCodeCopySelf or UserDefaults; the host applies side effects.
enum RebuildTagger {

    enum Outcome: Equatable {
        /// cdhash unchanged; nothing to do.
        case noChange
        /// First launch on this machine; store the hash but don't emit (no prior to compare).
        case firstLaunch(current: String)
        /// cdhash changed; emit app_rebuild and update stored hash.
        case rebuild(prev: String, current: String)
        /// Current hash unreadable. Don't touch the stored value; a transient failure
        /// must not promote the next healthy launch into a spurious app_rebuild.
        case unreadable
    }

    static func decide(current: String?, previous: String?) -> Outcome {
        guard let current else { return .unreadable }
        guard let previous else { return .firstLaunch(current: current) }
        if previous == current { return .noChange }
        return .rebuild(prev: previous, current: current)
    }

    /// UserDefaults key holding the most recently observed cdhash.
    static let defaultsKey = "mp.log.lastCDHash"

    /// Apply the decision and update UserDefaults. Wired into applicationDidFinishLaunching
    /// before other startup so app_rebuild is always the first event of a relaunch.
    static func runOnce(
        defaults: UserDefaults = .standard,
        readCDHash: () -> String? = currentCDHash,
        emit: (String, [String: Any]) -> Void = { action, attrs in
            Log.event(category: "main", action: action, attributes: attrs)
        }
    ) {
        let current = readCDHash()
        let previous = defaults.string(forKey: defaultsKey)
        switch decide(current: current, previous: previous) {
        case .noChange, .unreadable:
            return
        case .firstLaunch(let h):
            defaults.set(h, forKey: defaultsKey)
        case .rebuild(let prev, let curr):
            emit("app_rebuild", ["prev_cdhash": prev, "new_cdhash": curr])
            defaults.set(curr, forKey: defaultsKey)
        }
    }

    /// SHA-256 cdhash via SecCodeCopySigningInformation / kSecCodeInfoUnique
    /// (same value codesign -d --verbose prints). For adhoc-signed builds (normal
    /// during dogfood) this is a content hash, so every rebuild flips it.
    static func currentCDHash() -> String? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
              let dyn = dynamicCode else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dyn, [], &staticCode) == errSecSuccess,
              let sc = staticCode else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(sc, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return nil
        }
        if let data = dict[kSecCodeInfoUnique as String] as? Data {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        if let hashes = dict[kSecCodeInfoCdHashes as String] as? [Data],
           let first = hashes.first {
            return first.map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }
}
