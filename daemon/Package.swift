// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingPipe",
    // macOS 14 required for ScreenCaptureKit's `excludesCurrentProcessAudio`
    // (added in 13.3 but easier to bump than gate per-call).
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingPipe", targets: ["MeetingPipe"]),
        .library(name: "MeetingPipeCore", targets: ["MeetingPipeCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        // FluidAudio: Swift-native Parakeet ASR + pyannote diarization on ANE.
        // Pinned exactly (LOCAL5): a floating `from:` silently drifted 0.12.4 ->
        // 0.14.8 across builds, and diarization/embedding output is load-bearing
        // for FEAT3-VOICEPRINT/ROSTER, so the transcription contract must not
        // move without a deliberate bump. 0.14.8 already carries the streaming +
        // enrollment/embedding API FEAT3 needs, so the 0.15.x bump is deferred.
        // Track before bumping: upstream #738 (macOS 27 ANE access) and #726.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.8")
    ],
    targets: [
        // Shared lifecycle + gate infrastructure (TECH-C13, TECH-G-MIC).
        // Kept independent of the executable so the verdict-fusion code
        // can be unit-tested without dragging in AppKit / FluidAudio.
        // TOMLKit is the only third-party dep, used to parse the
        // MicGate MuteLabels catalogue.
        .target(
            name: "MeetingPipeCore",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")],
            path: "Sources/MeetingPipeCore",
            resources: [.process("MicGate/Resources")],
            // TECH-CONC2: targeted strict-concurrency checking for the core
            // module: it verifies Sendable across the real concurrency
            // boundaries (the verdict AsyncStreams, Task captures) without
            // flagging every benign immutable `static let` DI seam, which a
            // `complete`-mode sweep would (that is the wholesale migration the
            // task scopes out). Kept off the AppKit executable, so it stays an
            // island around where the cross-thread risk actually lives.
            swiftSettings: [.unsafeFlags(["-strict-concurrency=targeted"])]
        ),
        .executableTarget(
            name: "MeetingPipe",
            dependencies: [
                "MeetingPipeCore",
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/MeetingPipe",
            resources: [
                .process("Resources")
            ],
            // CONC4: the same targeted strict-concurrency checking the Core island
            // has always used, now extended to the executable so a cross-thread
            // Sendable finding in the app spine is a compiler warning rather than a
            // comment. `complete` mode stays out of scope (a separate decision).
            swiftSettings: [.unsafeFlags(["-strict-concurrency=targeted"])]
        ),
        .testTarget(
            name: "MeetingPipeTests",
            dependencies: [
                "MeetingPipe"
            ],
            path: "Tests/MeetingPipeTests",
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "MeetingPipeCoreTests",
            dependencies: ["MeetingPipeCore"],
            path: "Tests/MeetingPipeCoreTests",
            resources: [.process("Fixtures")]
        )
    ]
)
