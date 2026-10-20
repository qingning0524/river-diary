// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RiverDiaryMac",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.10.0"),
        .package(path: "../../Packages/RiverDiaryCore")
    ],
    targets: [
        .executableTarget(
            name: "RiverDiaryMac",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .product(name: "RiverDiaryCore", package: "RiverDiaryCore")
            ],
            path: "Sources/RiverDiaryMac",
            // Keep the developer's ignored personal snapshot out of every
            // package product. Runtime data is connected explicitly in Settings.
            exclude: ["Resources/data.json"],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/ThirdPartyNotices.md")
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
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .product(name: "RiverDiaryCore", package: "RiverDiaryCore")
            ],
            path: "Tests/RiverDiaryMacTests"
        )
    ]
)
