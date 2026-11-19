# Tachi for iOS and macOS

Install Xcode and XcodeGen, then generate the project and build both native apps from the repository root.

```sh
xcodegen generate --spec apple/project.yml
xcodebuild -project apple/Tachi.xcodeproj -scheme Tachi-macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project apple/Tachi.xcodeproj -scheme Tachi-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

To try the connection locally, run `python3 -m tachi` from the repository root. Open the macOS app or run the iOS app on a simulator using the generated project. In Debug, both default to `http://127.0.0.1:8743`. Select **Connect** to request `GET /v1/status`. A ready response displays **Connected** and the protocol version.

For a physical device or a Release build, enter the HTTPS origin of your coordinator, with an optional port. The app remembers the address locally and checks it when you select **Connect**. For release ownership and signing, see [Internal TestFlight](../docs/release.md).
