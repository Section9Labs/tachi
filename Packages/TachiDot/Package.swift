// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TachiDot",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "tachi-dot-plugin", targets: ["DotPlugin"])],
    dependencies: [.package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0")],
    targets: [.executableTarget(name: "DotPlugin", dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
    ])]
)
