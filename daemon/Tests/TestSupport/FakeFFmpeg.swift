import Foundation

/// T15: the one stand-in ffmpeg for every test. Four private copies had drifted across the post-processor,
/// the orphan-recovery and the process-runner suites; each wrote a shell script and made it executable.
///
/// A script is a real executable, so it drives the production code through its real spawn path, whether
/// the test hands the path over directly (`ffmpegPath:`) or through `MEETINGPIPE_FFMPEG`.
public enum FakeFFmpeg {
    /// A script whose body is `body` (the shebang is added), in `dir`, executable.
    public static func script(_ body: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("fake-ffmpeg-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Ignores its arguments, copies `source` over its last argument (the output path), exits with `status`.
    public static func copying(_ source: URL, in dir: URL, exitStatus: Int32 = 0) throws -> URL {
        try script("for last; do :; done\n/bin/cp '\(source.path)' \"$last\"\nexit \(exitStatus)", in: dir)
    }

    /// Writes nothing and exits with `status`: a failed run when non-zero, a "wrote no output" run at 0.
    public static func writingNothing(in dir: URL, exitStatus: Int32 = 0) throws -> URL {
        try script("exit \(exitStatus)", in: dir)
    }
}
