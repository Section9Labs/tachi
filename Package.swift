// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "TachiService",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "tachi-coordinator", targets: ["TachiCoordinator"])],
    dependencies: [
        .package(path: "Packages/TachiAccounts"),
        .package(path: "Packages/TachiRuntime"),
        .package(path: "Packages/TachiGrok"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
    ],
    targets: [
        .systemLibrary(name: "CSoloDigest", path: "Sources/TachiCoordinator/CSoloDigest"),
        .executableTarget(name: "TachiCoordinator", dependencies: [
            "CSoloDigest",
            .product(name: "TachiAccounts", package: "TachiAccounts"),
            .product(name: "TachiRuntime", package: "TachiRuntime"),
            .product(name: "TachiGrok", package: "TachiGrok"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ], exclude: ["CSoloDigest"], linkerSettings: [.linkedLibrary("crypto", .when(platforms: [.linux]))]),
        .testTarget(name: "TachiCoordinatorTests", dependencies: ["TachiCoordinator"], path: "ServiceTests/TachiCoordinatorTests"),
    ]
)
