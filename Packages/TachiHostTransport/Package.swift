// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TachiHostTransport",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tachi-host-sidecar", targets: ["HostSidecar"]),
        .executable(name: "tachi-host-agent", targets: ["HostAgent"])
    ],
    dependencies: [
        .package(path: "../TachiAccounts"), .package(path: "../TachiRuntime"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0")
    ],
    targets: [
        .target(name: "TachiHostTransport", dependencies: ["TachiAccounts", "TachiRuntime"]),
        .executableTarget(name: "HostSidecar", dependencies: [
            "TachiHostTransport", "TachiAccounts", "TachiRuntime",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio")
        ]),
        .executableTarget(name: "HostAgent", dependencies: ["TachiHostTransport", "TachiAccounts", "TachiRuntime"]),
        .testTarget(name: "HostTransportTests", dependencies: ["TachiHostTransport", "TachiRuntime", "TachiAccounts"])
    ]
)
