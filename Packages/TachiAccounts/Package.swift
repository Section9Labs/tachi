// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TachiAccounts",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TachiAccounts", targets: ["TachiAccounts"]),
        .executable(name: "tachi-accounts", targets: ["AccountsCLI"]),
        .executable(name: "tachi-folder", targets: ["FolderCLI"])
    ],
    targets: [
        .target(name: "CTachiAccounts", linkerSettings: [
            .linkedLibrary("sqlite3"), .linkedLibrary("crypto", .when(platforms: [.linux]))
        ]),
        .target(name: "TachiAccounts", dependencies: ["CTachiAccounts"]),
        .executableTarget(name: "AccountsCLI", dependencies: ["TachiAccounts"]),
        .executableTarget(name: "FolderCLI", dependencies: ["TachiAccounts"]),
        .testTarget(name: "TachiAccountsTests", dependencies: ["TachiAccounts"])
    ]
)
