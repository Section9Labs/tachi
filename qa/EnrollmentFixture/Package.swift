// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnrollmentFixture",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../Packages/TachiGrok")],
    targets: [
        .executableTarget(
            name: "Provision",
            dependencies: [.product(name: "TachiGrok", package: "TachiGrok")]
        )
    ]
)
