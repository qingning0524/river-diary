// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RiverDiaryMac",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.10.0")
    ],
    targets: [
        .executableTarget(
            name: "RiverDiaryMac",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift")
            ],
            path: "Sources/RiverDiaryMac",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-DSQLITE_HAS_CODEC"])
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "RiverDiaryMacTests",
            dependencies: [
                "RiverDiaryMac",
                .product(name: "SQLCipher", package: "SQLCipher.swift")
            ],
            path: "Tests/RiverDiaryMacTests"
        )
    ]
)
