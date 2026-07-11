import XCTest
@testable import MeetingPipe

/// DIST1: the mp-resolution priority, tested through the injectable
/// `resolveDirectMP` so a drag-installed app's embedded runtime is proven to win
/// over a dev-machine venv without needing a real bundle on disk.
final class PipelineLauncherFindMPTests: XCTestCase {

    private let embeddedPython = "/App/Resources/pipeline-runtime/bin/python3"
    private let venvMP = "/home/.local/share/meeting-pipe/venv/bin/mp"

    private func resolve(embedded: String?, venv: String, executable: Set<String>) -> PipelineLauncher.MPInvocation? {
        PipelineLauncher.resolveDirectMP(
            embeddedRuntimePython: embedded,
            prebuiltVenvMP: venv,
            isExecutable: { executable.contains($0) }
        )
    }

    func test_embedded_runtime_wins_over_venv_and_runs_as_python_module() {
        let r = resolve(embedded: embeddedPython, venv: venvMP, executable: [embeddedPython, venvMP])
        XCTAssertEqual(r?.shell, embeddedPython)
        // Relocation-safe: `python3 -m mp`, not the shebang-baked bin/mp console script.
        XCTAssertEqual(r?.args, ["-m", "mp"])
    }

    func test_falls_back_to_venv_console_script_when_no_embedded_runtime() {
        let r = resolve(embedded: nil, venv: venvMP, executable: [venvMP])
        XCTAssertEqual(r?.shell, venvMP)
        XCTAssertEqual(r?.args, [])
    }

    func test_skips_a_present_but_non_executable_embedded_runtime() {
        // The bundle path exists but the interpreter is not executable (a broken
        // bundle): fall back to the venv rather than trying to run it.
        let r = resolve(embedded: embeddedPython, venv: venvMP, executable: [venvMP])
        XCTAssertEqual(r?.shell, venvMP)
    }

    func test_returns_nil_to_fall_through_to_uv_and_path() {
        // Neither direct tier resolves -> findMP continues to the uv-walk / PATH tiers.
        XCTAssertNil(resolve(embedded: embeddedPython, venv: venvMP, executable: []))
    }
}
