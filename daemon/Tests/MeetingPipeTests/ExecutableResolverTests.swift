import XCTest
@testable import MeetingPipe

final class ExecutableResolverTests: XCTestCase {

    func test_env_override_wins_when_executable() {
        let path = ExecutableResolver.resolve(
            name: "ffmpeg",
            envOverride: "MEETINGPIPE_FFMPEG",
            searchPath: true,
            fallbacks: ["/opt/homebrew/bin/ffmpeg"],
            environment: ["MEETINGPIPE_FFMPEG": "/custom/ffmpeg", "PATH": "/usr/bin"],
            isExecutable: { $0 == "/custom/ffmpeg" }
        )
        XCTAssertEqual(path, "/custom/ffmpeg")
    }

    func test_env_override_ignored_when_not_executable_then_path_walked() {
        let path = ExecutableResolver.resolve(
            name: "ffmpeg",
            envOverride: "MEETINGPIPE_FFMPEG",
            searchPath: true,
            fallbacks: [],
            environment: ["MEETINGPIPE_FFMPEG": "/missing", "PATH": "/a:/b"],
            isExecutable: { $0 == "/b/ffmpeg" }
        )
        XCTAssertEqual(path, "/b/ffmpeg")
    }

    func test_fallbacks_checked_in_order() {
        let path = ExecutableResolver.resolve(
            name: "uv",
            fallbacks: ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "/Users/x/.local/bin/uv"],
            environment: [:],
            isExecutable: { $0 == "/Users/x/.local/bin/uv" }
        )
        XCTAssertEqual(path, "/Users/x/.local/bin/uv")
    }

    func test_path_not_walked_when_searchPath_false() {
        // findMP's uv lookup uses fallbacks only, no PATH walk: the fallback wins
        // even though a matching `uv` would be found on PATH.
        let path = ExecutableResolver.resolve(
            name: "uv",
            searchPath: false,
            fallbacks: ["/opt/homebrew/bin/uv"],
            environment: ["PATH": "/somewhere"],
            isExecutable: { $0 == "/somewhere/uv" || $0 == "/opt/homebrew/bin/uv" }
        )
        XCTAssertEqual(path, "/opt/homebrew/bin/uv")
    }

    func test_returns_nil_when_nothing_resolves() {
        XCTAssertNil(ExecutableResolver.resolve(
            name: "nope",
            envOverride: "X",
            searchPath: true,
            fallbacks: ["/a", "/b"],
            environment: ["PATH": "/usr/bin"],
            isExecutable: { _ in false }
        ))
    }
}
