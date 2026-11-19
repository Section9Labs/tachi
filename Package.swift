// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "TachiService",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "tachi-coordinator", targets: ["TachiCoordinator"])],
    dependencies: [.package(path: "Packages/TachiAccounts"), .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0")],
    targets: [
        .executableTarget(name: "TachiCoordinator", dependencies: [
            .product(name: "TachiAccounts", package: "TachiAccounts"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ])
    ]
)
