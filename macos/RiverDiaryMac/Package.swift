// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RiverDiaryMac",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "RiverDiaryMac",
            path: "Sources/RiverDiaryMac",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "RiverDiaryMacTests",
            dependencies: ["RiverDiaryMac"],
            path: "Tests/RiverDiaryMacTests"
        )
    ]
)
