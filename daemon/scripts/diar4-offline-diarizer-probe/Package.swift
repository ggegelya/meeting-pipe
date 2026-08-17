// swift-tools-version:5.9
import PackageDescription

// DIAR4 probe. Its own package, deliberately, so `swift build` in `daemon/` neither
// builds it nor is affected by it: a spike must carry zero regression risk, and an
// extra executable target on the app's manifest is not zero. FluidAudio is pinned to
// the exact version the daemon pins (LOCAL5), because the whole point is to measure
// what THIS daemon would get, not what a newer release might do.
let package = Package(
    name: "diar4-offline-diarizer-probe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.8")
    ],
    targets: [
        .executableTarget(
            name: "diar4-offline-diarizer-probe",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/diar4-offline-diarizer-probe"
        )
    ]
)
