import Foundation

/// Spawns `mp run-all <wav>` out of process so transcription doesn't block the daemon.
final class PipelineLauncher {
    enum LaunchError: Error, LocalizedError {
        case mpNotFound
        case nonZeroExit(Int32, String)

        var errorDescription: String? {
            switch self {
            case .mpNotFound:
                return "`mp` (pipeline) not found. Did you run scripts/install.sh?"
            case .nonZeroExit(let code, let tail):
                return "pipeline exited \(code): \(tail)"
            }
        }
    }

    /// `completion` receives the Notion page URL (nil in regulated_mode) or an error.
    func runAll(wav: URL, completion: @escaping (Result<URL?, Error>) -> Void) {
        guard let mpPath = Self.findMP() else {
            completion(.failure(LaunchError.mpNotFound))
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: mpPath.shell)
        p.arguments = mpPath.args + ["run-all", wav.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        // Pipeline log lives next to detector / daemon logs so the user can tail one place.
        let logURL = Log.logsDir.appendingPathComponent("pipeline.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = (try? FileHandle(forWritingTo: logURL))
        try? logHandle?.seekToEnd()

        var stderrTail = Data()
        let stderrLimit = 4096

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? logHandle?.write(contentsOf: d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData; if d.isEmpty { return }
            try? logHandle?.write(contentsOf: d)
            stderrTail.append(d)
            if stderrTail.count > stderrLimit {
                stderrTail.removeFirst(stderrTail.count - stderrLimit)
            }
        }

        p.terminationHandler = { proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle?.close()

            if proc.terminationStatus != 0 {
                let tail = String(data: stderrTail, encoding: .utf8) ?? ""
                completion(.failure(LaunchError.nonZeroExit(proc.terminationStatus, tail)))
                return
            }

            // Side-channel: orchestrator writes <wav-stem>.notion.json with page_url.
            let stem = wav.deletingPathExtension().lastPathComponent
            let sidecar = wav.deletingLastPathComponent().appendingPathComponent("\(stem).notion.json")
            if let data = try? Data(contentsOf: sidecar),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let urlStr = obj["page_url"] as? String,
               let url = URL(string: urlStr) {
                completion(.success(url))
            } else {
                completion(.success(nil))
            }
        }

        do {
            try p.run()
        } catch {
            completion(.failure(error))
        }
    }

    /// Resolution order: prebuilt venv (`~/.local/share/meeting-pipe/venv/bin/mp`)
    /// → `uv run mp` invoked from the repo's pipeline dir → bare `mp` on PATH.
    private struct MPInvocation {
        let shell: String
        let args: [String]
    }

    private static func findMP() -> MPInvocation? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let venvBin = home.appendingPathComponent(".local/share/meeting-pipe/venv/bin/mp")
        if FileManager.default.isExecutableFile(atPath: venvBin.path) {
            return MPInvocation(shell: venvBin.path, args: [])
        }

        // Discover repo root by walking up from the executable path looking for `pipeline/pyproject.toml`.
        if let bin = Bundle.main.executableURL {
            var dir = bin.deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("pipeline/pyproject.toml")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    let uvCandidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
                    if let uv = uvCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                        return MPInvocation(shell: uv, args: ["run", "--project", dir.appendingPathComponent("pipeline").path, "mp"])
                    }
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
        }

        // Fallback: bare mp on PATH (the install script symlinks one).
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for entry in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent("mp")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return MPInvocation(shell: candidate.path, args: [])
            }
        }
        return nil
    }
}
