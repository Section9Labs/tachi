# Tachi for iOS and macOS

Install Xcode and XcodeGen, then generate the project and build both native apps from the repository root.

```sh
xcodegen generate --spec apple/project.yml
xcodebuild -project apple/Tachi.xcodeproj -scheme Tachi-macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project apple/Tachi.xcodeproj -scheme Tachi-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

To try the connection locally, run `python3 -m tachi` from the repository root. Open the macOS app or run the iOS app on a simulator using the generated project. In Debug, both default to `http://127.0.0.1:8743`. Select **Connect** to request `GET /v1/status`. A ready response displays **Connected** and the protocol version.

For a physical device or a Release build, enter the HTTPS origin of your coordinator, with an optional port. The app remembers the address locally and checks it when you select **Connect**. For release ownership and signing, see [Internal TestFlight](../docs/release.md).

## Pair a coordinator account

Start the coordinator with its account database configured. Ask the coordinator operator for a new client invitation. After setting the coordinator URL in Tachi, enter the invitation under **Coordinator account** and select **Pair Device**. Tachi stores the credential in Keychain for that origin and local account label. It checks the saved credential on launch and when you select **Check Account**.

Use a new local label and a separate invitation for a second account or another client of the same person. To return to a saved account, enter its label and select **Check Account**. Tachi will ask for another invitation if the coordinator revokes that client. The public status check works independently of pairing.

For a simulator pairing test, build with Xcode’s default local simulator signing. Keychain access requires the simulator application identifier entitlement. The unsigned CI command above checks compilation.

## Run a connected Grok Bot routine

From a paired coordinator account, choose **Solo Assistants** and open a connected routine. Listing routines and checking task status require `sessions:read`. Sending a task requires `messages:send`. The coordinator operator connects the routine to the account.

Enter the task input and choose **Send Task**. Tachi sends the input as the saved routine’s `text` payload field and remembers the task ID on this device. Open **Check Status** to read the receipt again. For an accepted routine, check Grok Bot for the result. If submission is unconfirmed, check Grok Bot before starting another task. An explicit rejection offers **Start Another Task**.

## Try a reference team

Enable the coordinator’s `--reference-teams` option with its account database and pair a client with `sessions:read`. Select **Reference Teams**. Creating a team or changing its run requires `teams:manage`, and posting requires `messages:send`. Authorized sibling clients for the same human can reopen the team from their own team list.

Select a direct audience or mention Lead or Peer from the room composer. Direct replies keep the original audience. Use **Pause Run** and **Resume Run** to intervene. Choose **Refresh Team** to fetch delivery state, then open a completed result. The reference assistants return synthetic word counts.

If a send fails, its text, audience, reply and stable message ID stay in the local outbox. Use **Retry Pending Messages** after the coordinator is reachable. Rejected sends remain visible for manual removal, and later pending messages can still send. Pending sends belong to the paired client that queued them.

## Use a human workspace

From a paired coordinator account, choose **Workspaces**. A client with **Create Workspace** can create a workspace, copy its ID, and create a one-use invitation for an exact human ID under **Membership**. Share the ID and invitation with that person. They can enter both under **Join Workspace** from their own paired account.

Messages go to the room by default. Turn on **Direct message** and enter a human ID to address one member. Workspace owners can revoke a person’s access or withdraw their pending invitations under **Membership**.

Open **Artifacts** inside a workspace to list shared files. Choose a file up to 1 MiB and use **Upload Artifact** to share it in the room or with a specific member. Only mark **Synthetic fixture** for test data. Open a listed artifact and choose **Verify and Export** to download it, check its size and SHA-256, and choose a save location.
