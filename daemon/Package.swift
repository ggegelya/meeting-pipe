// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingPipe",
    // macOS 14 required for ScreenCaptureKit's `excludesCurrentProcessAudio`
    // (added in 13.3 but easier to bump than gate per-call).
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingPipe", targets: ["MeetingPipe"])
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        // FluidAudio: Swift-native Parakeet ASR + pyannote diarization on ANE.
        // Group P (TECH-P1 onward) migrates transcription off the Python
        // sidecar. The runner is wired through TranscriptionService and is
        // not the default path yet (the Python pipeline still wins) until a
        // follow-up session validates ANE residency and sidecar parity.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .executableTarget(
            name: "MeetingPipe",
            dependencies: [
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
            dependencies: ["MeetingPipe"],
            path: "Tests/MeetingPipeTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
