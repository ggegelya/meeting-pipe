import Foundation
import Security

/// Tag launches that follow a rebuild so dogfood-analysis can exclude
/// the re-grant churn that surrounds a `--reset-tcc` cycle.
///
/// The pure decision (`RebuildTagger.decide`) consumes the current and
/// previously stored cdhash and returns one of three outcomes; the host
/// applies the side effects (event emit, UserDefaults write). Splitting
/// it this way lets XCTest drive the logic without `SecCodeCopySelf` or
/// `UserDefaults`.
enum RebuildTagger {

    enum Outcome: Equatable {
        /// cdhash matches; nothing to do.
        case noChange
        /// First run on this machine (no stored prior hash). Store the
        /// hash but do not emit; there is no prior to compare against.
        case firstLaunch(current: String)
        /// cdhash differs from the stored prior. Emit `app_rebuild` and
        /// update the stored hash.
        case rebuild(prev: String, current: String)
        /// Could not read the current hash. Do not touch the stored
        /// value so a transient read failure cannot promote the next
        /// healthy launch into a spurious `app_rebuild`.
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

    /// Apply the decision: emit `app_rebuild` when warranted and update
    /// the stored hash. Wired into `App.applicationDidFinishLaunching`
    /// before the rest of startup so the first event of every relaunch
    /// is the rebuild marker.
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

    /// SHA-256 cdhash of the running executable. Reads via
    /// `SecCodeCopySigningInformation`'s `kSecCodeInfoUnique`, which is
    /// the principal cdhash that `codesign -d --verbose` prints. For
    /// adhoc-signed builds (the daemon's normal state during dogfood)
    /// the cdhash is a content hash, so every rebuild flips it.
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
