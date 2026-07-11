import Foundation

/// One place to resolve an external tool's absolute path (HYG1). `findFFmpeg` and
/// `findMP`'s uv lookup each hardcoded their own list before; they now compose the
/// same three lookup styles here: an optional env-var override, an optional `$PATH`
/// walk, and an ordered fallback list of absolute paths.
enum ExecutableResolver {
    /// Return the first executable found, or nil, checking in order: an env-var
    /// override (when `envOverride` is set and points at an executable), each
    /// `$PATH` entry (when `searchPath`), then `fallbacks` in order. `environment`
    /// and `isExecutable` are injectable so the resolution is unit-testable.
    static func resolve(
        name: String,
        envOverride: String? = nil,
        searchPath: Bool = false,
        fallbacks: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let key = envOverride, let override = environment[key], isExecutable(override) {
            return override
        }
        if searchPath, let path = environment["PATH"] {
            for entry in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent(name).path
                if isExecutable(candidate) { return candidate }
            }
        }
        return fallbacks.first(where: isExecutable)
    }
}
