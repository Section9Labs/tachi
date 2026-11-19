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
        .systemLibrary(
            name: "CCurl",
            pkgConfig: "libcurl",
            providers: [.apt(["libcurl4-openssl-dev"])]
        ),
        .target(name: "CWebhook", dependencies: ["CCurl"]),
        .target(name: "TachiGrok", dependencies: ["TachiRuntime", "CWebhook"]),
        .testTarget(
            name: "TachiGrokTests",
            dependencies: ["TachiGrok"],
            resources: [.copy("Fixtures")]
        )
    ]
)
