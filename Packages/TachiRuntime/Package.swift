// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TachiRuntime",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "TachiRuntime", targets: ["TachiRuntime"])],
    targets: [
        .systemLibrary(name: "RuntimeSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "TachiRuntime", dependencies: ["RuntimeSQLite"]),
        .testTarget(name: "TachiRuntimeTests", dependencies: ["TachiRuntime", "RuntimeSQLite"], resources: [.copy("Fixtures")])
    ]
)
