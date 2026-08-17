import Foundation
import SwiftUI

/// What `mp mcp-serve --status --json` reports: what the MCP server exposes and
/// what it withholds (AUTO3, leg 3).
///
/// Decoded rather than recomputed in Swift on purpose. `mp.visibility` is the
/// single owner of "which meetings may leave this machine", and a Swift copy of
/// that rule would be a second owner of the exact thing leg 0 exists to have
/// only one of: the number the owner reads here and the number the server
/// enforces have to be the same number, not two implementations that agree
/// today.
struct MCPStatus: Decodable, Equatable {
    let enabled: Bool
    let transport: String
    let tools: [String]
    let sdkAvailable: Bool
    let visible: Int
    let withheld: Int
    let withheldByReason: [String: Int]

    enum CodingKeys: String, CodingKey {
        case enabled, transport, tools, visible, withheld
        case sdkAvailable = "sdk_available"
        case withheldByReason = "withheld_by_reason"
    }

    /// "3 under an NDA workflow, 39 with no recorded privacy stance". The reason
    /// is the half that makes the count trustworthy: a bare "42 withheld" is a
    /// number a user quietly stops believing.
    var withheldExplanation: String {
        let parts = withheldByReason.sorted { $0.key < $1.key }.map { key, count -> String in
            switch key {
            case "nda": return "\(count) under an NDA workflow"
            case "regulated": return "\(count) recorded in regulated mode"
            case "no_sidecar": return "\(count) with no recorded privacy stance"
            default: return "\(count) \(key)"
            }
        }
        return parts.isEmpty ? "" : parts.joined(separator: ", ")
    }
}

/// Drives the Preferences ▸ Integrations ▸ Model Context Protocol group.
///
/// Shaped like `StorageStatsStore` and `DoctorRunner`, for the reason UX67
/// records: a `Process` round-trip left on the main thread wedges every control
/// in the pane, not just its own. So the read runs on a detached task, it is
/// watchdogged (a wedged `mp` must not become a wedged Preferences window), and
/// it is re-taken on the pane's `.onAppear` rather than per render.
@MainActor
final class MCPStatusStore: ObservableObject {
    @Published private(set) var status: MCPStatus?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    /// Ceiling for the `mp mcp-serve --status` child. The command stats one
    /// sidecar per meeting and loads no model, so it is sub-second on a library
    /// of hundreds; this is the "something is wrong" bound, not a budget.
    static let ceilingSeconds: TimeInterval = 20

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let result = await Task.detached(priority: .userInitiated) {
            MCPStatusStore.read(timeout: MCPStatusStore.ceilingSeconds)
        }.value
        switch result {
        case .success(let status):
            self.status = status
            self.error = nil
        case .failure(let message):
            self.error = message
        }
    }

    enum ReadResult {
        case success(MCPStatus)
        case failure(String)
    }

    /// Run `mp mcp-serve --status --json` and decode it. Off-main by contract:
    /// every caller is a detached task.
    nonisolated static func read(timeout: TimeInterval) -> ReadResult {
        guard let mp = PipelineLauncher.findMP() else {
            return .failure("mp launcher not found. Did you run scripts/install.sh?")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mp.shell)
        process.arguments = mp.args + ["mcp-serve", "--status", "--json"]
        process.environment = PipelineLauncher.freshEnvironment()

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .failure("Could not run `mp mcp-serve --status`: \(error.localizedDescription)")
        }

        // The watchdog is the UX67 half. `readDataToEndOfFile` returns when the
        // child's pipe closes, so a child that never exits blocks this thread
        // forever; killing it at the ceiling turns that into an error message.
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else {
            return .failure("`mp mcp-serve --status` exited \(process.terminationStatus).")
        }
        return decode(data)
    }

    /// Split out so the decode is testable without spawning anything.
    nonisolated static func decode(_ data: Data) -> ReadResult {
        do {
            return .success(try JSONDecoder().decode(MCPStatus.self, from: data))
        } catch {
            return .failure("Could not read the MCP status: \(error.localizedDescription)")
        }
    }
}
