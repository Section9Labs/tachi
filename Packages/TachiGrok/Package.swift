// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TachiGrok",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "TachiGrok", targets: ["TachiGrok"])],
    dependencies: [
        .package(path: "../TachiRuntime")
    ],
    targets: [
        .target(name: "TachiGrok", dependencies: ["TachiRuntime"]),
        .testTarget(name: "TachiGrokTests", dependencies: ["TachiGrok"])
    ]
)
