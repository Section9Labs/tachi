// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Set TACHI_PACKAGES to the absolute Packages directory when copying this consumer outside the checkout.
let packages = ProcessInfo.processInfo.environment["TACHI_PACKAGES"] ?? "../../Packages"
let package = Package(
    name: "AdapterOnboarding",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "\(packages)/TachiRuntime"),
        .package(path: "\(packages)/TachiGrok")
    ],
    targets: [
        .testTarget(name: "OnboardingTests", dependencies: [
            .product(name: "TachiAdapterConformance", package: "TachiRuntime"),
            .product(name: "TachiRuntime", package: "TachiRuntime"),
            .product(name: "TachiGrok", package: "TachiGrok")
        ])
    ]
)
