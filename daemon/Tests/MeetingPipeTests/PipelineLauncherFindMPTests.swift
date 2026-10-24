import XCTest
@testable import MeetingPipe

/// DIST1: the mp-resolution priority, tested through the injectable
/// `resolveDirectMP` so a drag-installed app's embedded runtime is proven to win
/// over a dev-machine venv without needing a real bundle on disk.
final class PipelineLauncherFindMPTests: XCTestCase {

    private let embeddedPython = "/App/Resources/pipeline-runtime/bin/python3"
    private let venv = "/home/.local/share/meeting-pipe/venv"
    private let venvMP = "/home/.local/share/meeting-pipe/venv/bin/mp"
    private let venvPython = "/home/.local/share/meeting-pipe/venv/bin/python3"

    private func resolve(embedded: String?, executable: Set<String>) -> PipelineLauncher.MPInvocation? {
        PipelineLauncher.resolveDirectMP(
            embeddedRuntimePython: embedded,
            prebuiltVenv: venv,
            isExecutable: { executable.contains($0) }
        )
    }

    func test_embedded_runtime_wins_over_venv_and_runs_as_python_module() {
        let r = resolve(embedded: embeddedPython, executable: [embeddedPython, venvMP, venvPython])
        XCTAssertEqual(r?.shell, embeddedPython)
        // Relocation-safe: `python3 -m mp`, not the shebang-baked bin/mp console script.
        XCTAssertEqual(r?.args, ["-m", "mp"])
    }

    func test_falls_back_to_venv_interpreter_as_python_module_when_no_embedded_runtime() {
        // DIST4: the venv's own interpreter runs `-m mp`, so whatever `bin/mp`'s shebang
        // names (the git clone's `.venv`, before DIST4) no longer decides what runs.
        let r = resolve(embedded: nil, executable: [venvMP, venvPython])
        XCTAssertEqual(r?.shell, venvPython)
        XCTAssertEqual(r?.args, ["-m", "mp"])
    }

    func test_skips_a_venv_whose_interpreter_is_gone() {
        // DIST4: `bin/mp` is still there but the interpreter it would run is not (a
        // dangling symlink to a removed uv Python). Fall through to the uv / PATH tiers
        // instead of handing back an invocation that dies at exec.
        XCTAssertNil(resolve(embedded: nil, executable: [venvMP]))
    }

    func test_skips_a_venv_with_no_mp_installed() {
        // An interpreter but no `bin/mp` marker: a sync that died part-way.
        XCTAssertNil(resolve(embedded: nil, executable: [venvPython]))
    }

    func test_skips_a_present_but_non_executable_embedded_runtime() {
        // The bundle path exists but the interpreter is not executable (a broken
        // bundle): fall back to the venv rather than trying to run it.
        let r = resolve(embedded: embeddedPython, executable: [venvMP, venvPython])
        XCTAssertEqual(r?.shell, venvPython)
    }

    func test_returns_nil_to_fall_through_to_uv_and_path() {
        // Neither direct tier resolves -> findMP continues to the uv-walk / PATH tiers.
        XCTAssertNil(resolve(embedded: embeddedPython, executable: []))
    }
}
