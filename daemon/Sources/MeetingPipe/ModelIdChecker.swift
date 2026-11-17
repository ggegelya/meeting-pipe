import Foundation

/// PIPE28: what `mp check-model <id>` answered about a typed Anthropic model id.
enum ModelIdVerdict: String, Equatable {
    case found
    case notFound = "not_found"
    /// No key, regulated mode, a network error or a rate limit. Never shown as "not found".
    case inconclusive
}

/// The pure half of the Preferences model-id check (PIPE28), kept apart from the process so
/// it is testable without spawning anything.
enum ModelIdCheck {
    struct Result: Equatable {
        let model: String
        let verdict: ModelIdVerdict
    }

    /// The last JSON line `mp check-model` printed, which is its whole answer. Anything else
    /// on stdout (a warning the config loader printed first) is skipped, and an unreadable
    /// answer is nil rather than a guess.
    static func parse(_ stdout: String) -> Result? {
        for line in stdout.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = object["model"] as? String,
                  let raw = object["verdict"] as? String,
                  let verdict = ModelIdVerdict(rawValue: raw) else { continue }
            return Result(model: model, verdict: verdict)
        }
        return nil
    }

    /// The line under the field, and only for a definite "not found" about the id now in the
    /// field: a verdict for an id the owner has since typed over describes nothing.
    static func note(for result: Result?, currentID: String) -> String? {
        guard let result, result.verdict == .notFound, result.model == currentID else { return nil }
        return "Anthropic does not recognise \"\(currentID)\". Summaries on this model will fail; pick another."
    }
}

/// Runs `mp check-model` off the main thread when a new Anthropic model id is committed, so a
/// retired or mistyped id is flagged under the field instead of by the first failed summary.
/// The key stays in the pipeline's own environment (it reads the Keychain itself); this
/// object never holds it. Debounced, because the field commits on every keystroke.
@MainActor
final class ModelIdChecker: ObservableObject {
    @Published private(set) var result: ModelIdCheck.Result?

    private let invocation: () -> PipelineLauncher.MPInvocation?
    private let debounce: TimeInterval
    private var pending: DispatchWorkItem?
    private var token = 0

    init(
        debounce: TimeInterval = 0.8,
        invocation: @escaping () -> PipelineLauncher.MPInvocation? = { PipelineLauncher.findMP() }
    ) {
        self.debounce = debounce
        self.invocation = invocation
    }

    func schedule(_ modelID: String) {
        pending?.cancel()
        token &+= 1
        let mine = token
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.start(modelID, token: mine) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func start(_ modelID: String, token mine: Int) {
        guard mine == token, let mp = invocation() else { return }
        DispatchQueue.global(qos: .utility).async {
            let verdict = Self.run(mp, modelID)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, mine == self.token else { return }
                    self.result = verdict
                }
            }
        }
    }

    private nonisolated static func run(_ mp: PipelineLauncher.MPInvocation, _ modelID: String) -> ModelIdCheck.Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mp.shell)
        process.arguments = mp.args + ["check-model", modelID]
        process.environment = PipelineLauncher.freshEnvironment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ModelIdCheck.parse(String(data: data, encoding: .utf8) ?? "")
    }
}
