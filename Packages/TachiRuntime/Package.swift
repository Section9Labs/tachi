// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TachiRuntime",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "TachiRuntime", targets: ["TachiRuntime"])],
    targets: [
        .target(name: "TachiRuntime"),
        .testTarget(name: "TachiRuntimeTests", dependencies: ["TachiRuntime"])
    ]
)
