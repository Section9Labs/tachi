# Internal TestFlight

The Release Manager owns integration candidates, version and build numbers, signing, archives, uploads, and tester verification for Tachi. This process covers internal TestFlight for iOS and native macOS. Contributor builds and CI run without distribution credentials.

Both platforms use the product name Tachi and the same bundle ID for one multiplatform App Store Connect record. Archive the `Tachi-iOS` and `Tachi-macOS` shared schemes separately.

## Qualify the candidate

1. Wait for the integration lead to hand off an exact commit with passing integration evidence. Record that commit, the test commands and outcomes, the toolchain, and the platforms actually exercised. Use synthetic tasks to test the integrated user flow on each platform being offered.
2. Check the private ledger and App Store Connect before allocating a build number. Verify both platform records, processed builds, and recent upload records. Check for in-flight uploads and reconcile any unresolved attempt before allocating or retrying. Confirm signing readiness and access to the intended internal audience.
3. Record the reservation against the candidate commit and platform in the private ledger. Keep credentials, team and account identifiers, tester details, and distribution links outside Git history. Resolve the ledger location with `git rev-parse --path-format=absolute --git-common-dir` and use its `tachi/release/` directory.

## Archive and distribute

1. Create a signed Release archive for each platform from the recorded commit. Verify the archive's platform, bundle ID, marketing version, build number, signing identity, profile, and entitlements. Record the archive and export paths and the distribution artifact checksum.
2. Use Xcode's **TestFlight Internal Only** distribution option for each archive. For scripted Xcode export, enable `testFlightInternalTestingOnly` and disable `manageAppVersionAndBuildNumber` to preserve the recorded number. Record the upload receipt and reconcile its state against Apple's build upload and build records before any retry.
3. Verify that each exact build is valid and available for internal testing. Resolve any export-compliance hold, then verify the build appears in the intended internal group's builds and that the intended testers are members with access. Track TestFlight availability and actual device installation separately.
4. Record the result for each platform in the private ledger and report the candidate SHA, test evidence, availability, and any remaining gaps to the integration lead. The Release Manager reports an upload as available only after checking the build and audience together.

See Apple's [build upload guide](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds) and [internal tester guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers).
