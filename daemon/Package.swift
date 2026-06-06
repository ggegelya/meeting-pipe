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
        // Group P (TECH-P1 onward) migrates transcription off the Python
        // sidecar. The runner is wired through TranscriptionService and is
        // not the default path yet (the Python pipeline still wins) until a
        // follow-up session validates ANE residency and sidecar parity.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        // TECH-T2: Appearance-gated snapshot tests for a few SwiftUI views.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0")
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
            ]
        ),
        .testTarget(
            name: "MeetingPipeTests",
            dependencies: [
                "MeetingPipe",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/MeetingPipeTests",
            // swift-snapshot-testing reads reference PNGs from disk relative to
            // each test's #filePath, not from the SwiftPM resource bundle, so the
            // committed __Snapshots__ tree must be excluded from the target rather
            // than declared as a resource (otherwise SwiftPM flags it as unhandled).
            exclude: ["__Snapshots__"],
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
