// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RiverDiaryCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "RiverDiaryCore", targets: ["RiverDiaryCore"])
    ],
    targets: [
        .target(name: "RiverDiaryCore"),
        .testTarget(name: "RiverDiaryCoreTests", dependencies: ["RiverDiaryCore"], exclude: ["Fixtures"])
    ]
)
