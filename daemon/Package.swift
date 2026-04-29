// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingPipe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MeetingPipe", targets: ["MeetingPipe"])
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0")
    ],
    targets: [
        .executableTarget(
            name: "MeetingPipe",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit")
            ],
            path: "Sources/MeetingPipe",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MeetingPipeTests",
            dependencies: ["MeetingPipe"],
            path: "Tests/MeetingPipeTests"
        )
    ]
)
