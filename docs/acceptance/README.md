# Independent acceptance lab

## Bootstrap HTTP

From a coordinator checkout, start `python3 -m tachi --port 8743`. In a second terminal, run `python3 qa/probe_status.py` from the QA checkout. The probe uses the standard library and connects directly to loopback. Exit 0 requires `GET /v1/status`, HTTP 200, media type `application/json`, and exactly `{"service":"tachi","protocolVersion":1,"status":"ready"}`. Field order and whitespace are immaterial. A redirect, duplicate field, JSON boolean or float in place of the integer, invalid body, or transport failure exits 1. Stop the server you started after testing.

Run `python3 qa/test_probe_status.py` for the synthetic HTTP controls. Run `PYTHONPATH=. python3 qa/check_reference_turns.py` with adapter v1 present to exercise a solo fixture and a manually relayed sequence between two synthetic registrations. The driver supplies the requests and parent references. It checks request, identity, session and completion at each hop. Actual delegation, file access, client intervention and retrieval require the live scenario below. With the host module from [#6](https://github.com/Section9Labs/tachi/issues/6) on the Python path, run `PYTHONPATH=. python3 qa/check_host_grants.py` from an integrated checkout for the two-host database check. These commands are for engineers. Product scenarios below start and end in the Apple apps.

On 2026-11-19 at 02:07:43 UTC, the independent client (Python 3.14.7) exited 0 against the running loopback coordinator at [bootstrap revision 30d38d0](https://github.com/Section9Labs/tachi/commit/30d38d0dd9b580b540b539b8b5410947ea503927). This observation covers one real HTTP request on macOS.

## Apple clients and account pairing

At Apple revision `cd787e4`, the Apple owner observed **Connected / Protocol 1** and a connection failure on an unused port on macOS 27.0.1 and an iPad Pro simulator running iOS 27.2. The server was the loopback bootstrap at `30d38d0`. QA independently regenerated the Xcode project from that Apple revision, ran all five macOS client tests and built the iOS Simulator target. Hosted HTTPS and a signed physical device remain open. [Apple client handoff](https://github.com/Section9Labs/tachi/pull/31)

For [pairing acceptance](https://github.com/Section9Labs/tachi/issues/32), use a disposable coordinator database. Mint two short-lived invitations for separate clients of synthetic human A and a third for human B. Use the official operator flow, one invitation per client. Keep invitation and bearer values out of stdout, screenshots and run records.

| Observer | Operation | Required observation |
| --- | --- | --- |
| QA, HTTP | Redeem the invitations, then read each client's own account. | Each client receives its selected scopes. A's clients have distinct client IDs bound to A. B resolves to B. |
| QA, HTTP | Redeem A's consumed invitation a second time. | The server denies redemption and issues no credential. The already paired clients still resolve to their original accounts. |
| QA, HTTP | Revoke one A client using the operator flow. Repeat its previously successful account read and the reads by both controls. | The revoked bearer is denied. The sibling client and B remain authorized. |
| Apple owner | Pair in the app, relaunch, switch coordinator origin and local account, then return. Revoke the selected client. | The correct Keychain entry restores each binding only for its origin and local account. The UI surfaces the revoked binding and offers pairing again. Record simulator and physical HTTPS results separately. |

QA independently reran the 26 repository tests at [account store revision c70ba72](https://github.com/Section9Labs/tachi/commit/c70ba724a96e7e93fe2c6adaeb324f3ca985482d). That revision covers client credentials at the store layer. On Python 3.11 and 3.14, `python3 qa/check_client_pairing.py` passed the three HTTP rows above against [HTTP revision 10ee249](https://github.com/Section9Labs/tachi/commit/10ee2490090156d521392401199ce475695ac030). Run from the coordinator checkout. The script starts its own loopback listener on an ephemeral port and uses the operator CLI and a temporary database. Replay and post-revocation reads returned 401. Both control clients retained their selected identities and scopes. The Apple owner observed Keychain restoration after relaunch, origin and local-account isolation, and the re-pair prompt after selective revocation on a locally signed iPad Pro (M5) simulator running iOS 27.2. The same-human sibling and second human retained access. Signed macOS Keychain behavior, physical iOS and hosted HTTPS remain open. [Apple pairing revision f2e2407](https://github.com/Section9Labs/tachi/pull/42)

### Swift coordinator pairing and SQLite cutover

QA built Swift coordinator `5b7070e` from a clean archive on arm64 macOS 27.0.1 with Swift 6.4.2. The status stage passed the exact ready response and JSON 404 checks. All three pairing-stage tests passed over loopback HTTP using the Swift operator CLI. Revoking one of three paired clients denied its bearer while the same-human sibling and the second human retained their original scopes. [Swift pairing revision](https://github.com/Section9Labs/tachi/commit/5b7070e63aa6de518a30072026d593648de08678) · [Reproduction commands](../../qa/swift-parity.md)

The legacy coordinator at `10ee249` created the SQLite database and stopped. Swift reopened the same file. The active bearer resolved to its original human, client ID and scopes. The revoked bearer and spent invitation returned 401. Swift redeemed the outstanding invitation for the second human and revoked the first human’s surviving client. After a Swift restart, both revoked bearers and the spent invitation returned 401, and the second human’s new bearer still resolved correctly. [Legacy producer](https://github.com/Section9Labs/tachi/commit/10ee2490090156d521392401199ce475695ac030)

The earlier Ubuntu amd64 packaged-service run passed the bootstrap HTTP probe at `1e5979b`. [Packaged Linux bootstrap run](https://github.com/Section9Labs/tachi/actions/runs/44450436010)

### Swift queue and host policy packages

QA reran all ten `TachiRuntime` tests at `9e89add` on arm64 macOS with Swift 6.4.2 and warnings treated as errors. The Swift queue opened SQLite state restored from a Python-generated SQL fixture. A paused run retained its request IDs and completed, uncertain and queued deliveries. In a separate receipt-only test, reopening the queue preserved the active delivery, held its next turn and rejected a handoff after one synthetic submission. The runtime owner also reported ten passes on arm64 Ubuntu Jammy with Swift 6.0.3 at this revision. In the owner’s separate process-exit test, the worker wrote a synthetic effect marker and exited with status 73. The replacement worker matched the marker’s request ID to an uncertain delivery and made zero further submissions. [Runtime tests and fixture](https://github.com/Section9Labs/tachi/tree/9e89add60c1b7ee13a8639500151b3c39146d9cc/Packages/TachiRuntime/Tests/TachiRuntimeTests)

QA reran all eight `TachiAccounts` tests at `18df590` on the same Mac with the Python writer at `7c34a72`. Swift authorized the existing membership generation and host grant using the current session. Python observed the subsequent Swift revocation. The release `tachi-folder` executable created a synthetic file, returned its exact bytes and refused a second write to the same name, preserving the original contents. The accounts owner reported seven tests passed on arm64 Linux with Swift 6.0.3. [Account and host tests](https://github.com/Section9Labs/tachi/tree/18df590b98226bbc1769e9b83cabc4d7e15fad35/Packages/TachiAccounts/Tests/TachiAccountsTests)

QA ran `swift test -Xswiftc -warnings-as-errors` at coordinator revision `4bdfb7c` on arm64 macOS with Swift 6.4.2. The root integration test passed. It queued three deliveries on one SQLite database through the compiled account and host authorization bridge. After the origin client was revoked, its delivery was denied. The same human’s sibling client completed one delivery while the read grant was valid. Revoking that grant blocked the sibling’s remaining delivery. The reference adapter received exactly one call. Swift reference-team HTTP, native provider dispatch and cross-machine host transport remain open. [Shared-database integration test](https://github.com/Section9Labs/tachi/blob/4bdfb7c8fb9bcd4ecb0f4337584d96ba519a1d45/ServiceTests/TachiCoordinatorTests/QueueAuthorityTests.swift)

### Swift reference teams on a Python-created database

At `72a28f7`, QA reran all 15 runtime package tests on arm64 macOS with Swift 6.4.2. The runtime owner reported all 15 also passed on aarch64 Linux with Swift 6.0.3. Both runs treated warnings as errors. [Runtime tests at the qualified revision](https://github.com/Section9Labs/tachi/tree/72a28f781ad26e4b7de50a6a18c0a0ece87ad7c2/Packages/TachiRuntime/Tests/TachiRuntimeTests)

In a separate macOS run, the runtime owner used an external SwiftPM executable with the public `TachiAccounts` and `TachiRuntime` libraries. Swift authenticated two existing clients, reopened a paused reference team in a Python-created SQLite file and retried creation and posting with the original IDs. After one client was revoked, its sibling resumed the run. One delivery was denied and one completed with a synthetic count of two words. Python then reopened the Swift-written file and returned the same delivery rows and result. This qualifies the local library bridge. End-to-end cutover through Swift reference-team HTTP remains open. [Reference-team implementation](https://github.com/Section9Labs/tachi/pull/65)

## Solo attachment and retrieval

1. On iPhone, use the connector's authorized subscription/SSO flow. Select an existing lab assistant. Record the provider, account and assistant as run-local aliases. Select a synthetic prior conversation if listing is supported. If the provider supports creating conversations, open a fresh one and verify the assistant identity stays the same. Record provisioning a new assistant separately.
2. Give only that assistant the synthetic CSV below and ask it to use its granted native file or table tool to report the two totals. Save the returned result. Capture the provider-native action and matching completion as well as Tachi's send and delivery state. Require at least one genuine native action beyond a text reply.
3. Close and reopen the app, reconnect through the same binding, open the same conversation and retrieve the saved artifact. Check its contents against the CSV and compare the retrieved bytes or digest with the completed artifact. Record device class, build and any unsupported operation. A missing native action, identity mismatch or missing output leaves solo acceptance open.

## First two-provider team · brief and claim check

Use two independently verified connectors from different providers, initially targeting Dot and Grok Bot. In a new team, reuse each harness's existing assistant identity with a fresh team-scoped conversation. Sign the same authorized human into iPhone and Mac. Grant the reviewer read access to `attendance.csv` through a verified native tool. Both files below are synthetic and can be created exactly as printed.

`draft.md`

```text
Lantern Hall open day
The morning and afternoon workshops welcomed 120 attendees in total.
```

`attendance.csv`

```csv
workshop,registered,checked_in
morning,70,56
afternoon,50,39
```

| Step | Action and pass condition |
| --- | --- |
| 1 · Start on iPhone | Attach the draft. Ask the lead to verify the attendance claim with the reviewer, wait for a human editorial instruction, then deliver a revised Markdown file. Retain the task, lead conversation and draft references. |
| 2 · Delegate | The lead sends the named reviewer a bounded claim check and scoped CSV reference. Observe delivery to the reviewer's actual provider conversation, including the originating assignment and recipient. |
| 3 · Native check | The reviewer uses its granted tool to read the CSV and returns the two column totals with source rows. Verify a provider-side tool invocation/result and the reviewer's attributed reply. The oracle is 120 registrations and 95 check-ins (56 + 39). |
| 4 · Return to lead | Match the reviewer reply to the assignment and observe receipt in the original lead's provider conversation. Record both delivery and receipt before the edit. A room transcript alone cannot establish receipt. |
| 5 · Intervene on Mac | While the task awaits editorial input, open it on the second Apple client. Send “Use checked-in attendance as the headline. Show both workshop counts and keep registration as a separate sentence.” Verify delivery to the original lead session and visibility on iPhone. The user supplies no totals. |
| 6 · Retrieve on iPhone | After the intervention, open the lead's completed `.md` artifact on iPhone. Check for 95 checked in, the 56/39 breakdown, 120 separately labeled registrations, and attribution to `attendance.csv`. Record a stable artifact alias and digest. Reopen it after reconnect and compare the bytes. |

Retain the causal chain from draft to assignment, native lookup, reviewer reply, lead receipt, Mac intervention and final artifact. A result written before the intervention fails step 6. If a connector cannot open the CSV under its own authority, record the blocker. Keep solo results, deterministic fixtures, and the two-provider outcome as separate runs.

### Reproduce the queue portion

Run `PYTHONPATH=. python3 qa/check_team_queue.py` from the integrated checkout. The test pairs two synthetic clients to the same human, registers two deterministic adapters and creates a team run. The lead receives the brief, the reviewer receives the assignment, and a reply correlated to the reviewer event reaches the original lead session. The second client pauses the run and posts the correction. After reopening the queue the edit stays pending until resume, then reaches the lead once. QA also ran all 47 repository tests at [queue revision fb717b6](https://github.com/Section9Labs/tachi/commit/fb717b6d4cb664f48b4f5edd980c033b3bb6dc10) on Python 3.11 and 3.14.

The test driver supplies the finding and editorial instruction. The observed evidence is the persisted routing, event correlation, client authority and pause/resume behavior. The native two-provider procedure above still requires file access, intervention reaching the original provider session and retrieval of the revised artifact.

### Reproduce the reference-team HTTP check

Run `python3 qa/check_reference_http.py`. QA exercised the opt-in HTTP service on Python 3.11 and 3.14 at [reference-team revision 46585c6](https://github.com/Section9Labs/tachi/commit/46585c6e0cdef5e84513dd7b37e23fc475369a12). Two paired clients for the same human shared a team and paused work. A read-only sibling could read the team and received 403 when posting. A different human saw an empty list and received 404 when opening the team. After the originating client was revoked, its bearer returned 401. The authorized sibling resumed the run. The origin's queued delivery was denied with no result, and the sibling's delivery completed. This run exercised the local HTTP server, SQLite queue and synthetic reference worker.

### Apple intervention and offline delivery

The Apple owner created a reference team on an iPad Pro Simulator and opened it on an ad hoc signed native Mac using a second paired client for the same human. The Mac paused the run. With the disposable coordinator stopped, the iPad queued a send and retained it through app relaunch. After server restart and iPad retry, the Mac saw the queued message, resumed the run and opened its synthetic result. The coordinator recorded one completed delivery for that message. [Apple client handoff](https://github.com/Section9Labs/tachi/pull/50)

On the final Mac build, a direct reply kept its original audience. A previously rejected draft remained visible and produced zero deliveries. Command-Return sent a later allowed reply, which completed once. QA independently reran 11 macOS Swift tests at `ac35656` and five reference-team HTTP tests at `46585c6`. The Apple owner’s interactive run used that coordinator and reference assistants. Compact iPhone interaction, signed physical iPhone access over HTTPS, native provider handoff and artifact retrieval remain open. [Apple revision ac35656](https://github.com/Section9Labs/tachi/commit/ac35656b439107ef2ea98f7e64471233c1c7f3b9)

## Host and failure runs

Use isolated synthetic teams and run each injection separately. Record the last confirmed operation, observable state after the injection and the count of external effects. Each row is a procedure pending execution unless a scoped result is attached.

| Injection | Observable pass condition |
| --- | --- |
| Duplicate or reordered delivery | Replay the same callback after completion, then deliver an older progress event. One completed reply and one external effect remain. Conflicting payloads with the same event ID surface a conflict. |
| Ambiguous dispatch | Lose the response after a native action took effect. Surface `DispatchUncertain`, observe one submission, reconcile against the provider before any replay. Keep unresolved if confirmation is unavailable. |
| Restart in flight | Restart the coordinator after acceptance and before completion. Reconnect to the same task and provider session, recover the final reply once, and verify effect count at the execution endpoint. |
| Auth expiry or exhausted subscription | Expire the lab binding, or simulate a quota response. Surface the affected binding and recovery action, checkpoint outstanding work, and stop submission. Verify no metered fallback or substitution. Resume after authorized renewal or quota return. |
| Cross-team or revoked access | Attempt lookup and download by a separate synthetic human outside the team. Revoke an allowed member during queued work. Deny access and further effects, including by direct artifact reference. |
| Pair two hosts; lose one | Grant the same folder label separately on two hosts. Drop host A. Deny A's queued local read and any attempt using A's grant on B. B and unrelated cloud work continue. Reconnect A and recheck its current grant/session before resuming. Revoke its grant while work is pending and verify zero subsequent reads. |
| Host-boundary controls | Try an ungranted path/action, expired lease and revoked host. Recheck owner, selected host, grant, folder, action and relative path immediately before each effect, including retry. Verify denial at the executor. Store task references without bearer secrets. |
| Unsupported capability or cancellation | Request an unadvertised operation. Expect an explicit unsupported response with zero native calls. For supported cancellation, inspect the provider's terminal status. Where cancellation is unavailable, the UI must distinguish a local stop from a confirmed provider stop. |

For [cloud-only acceptance](https://github.com/Section9Labs/tachi/issues/12), start the team task from a **physical iPhone** against the Linux deployment while all Macs are offline. Suspend the app before native work starts. Record the offline/suspension interval independently, timestamped provider work and return delivery inside that interval, plus coordinator connectivity from the actual execution endpoint. Reopen the iPhone and retrieve the completed artifact without resubmitting. Attach the deployment revision, route class, timestamps and artifact digest. Exercise Linux restart/restore separately. For mixed-host acceptance, run the two-host loss/revocation scenario over real companion connections with a cloud participant and record actual effects on both hosts. Store-level checks cover only the authorization decisions.

## Evidence record

For each run, record UTC date/time, scenario and step, source revisions, app/adapter/provider versions, host OS and route class, Apple platform and physical/simulator status, and per-step `pass`, `fail`, `blocked` or `unrun`. Include observed value, sanitized evidence reference, exact gap and issue owner. Use separate evidence entries for source inspection, synthetic in-process or HTTP fixtures, real coordinator HTTP, authenticated native sessions, simulator interaction, physical-device interaction and deployed host operation. A single run may need several entries for one claim.

Use stable **run-local aliases** for account, identity, session, team, sender/recipient, request, event, parent/reply, action and artifact. Record the origin of each observation (provider, coordinator, client or host), event kind, UTC time/order, and matching aliases. Pair a provider receipt with its request, native action with its result, and artifact with its digest. Record accepted and completed separately. Keep raw sessions and account data private. Publish only sanitized synthetic inputs, minimal observations and redacted evidence. Omit session URLs, bearer material, private network addresses and personal history.

For example, a public entry might read `fixture | reviewer session B | request Q2 replies to Q1 | completed | attendance.csv rows 2–3 | 95 checked in`. This example supplies a format only. Track actual operation coverage and drift in the [capability inventory](capabilities.md).

QA independently ran `check_host_grants.py` on Python 3.14.7 at [host revision 708fa17](https://github.com/Section9Labs/tachi/commit/708fa17ef554e6fb5866c5e6b6df9e5cee177ed2). Two store instances shared one temporary database. A grant scoped to host A was denied on B. B retained its own access during A's disconnect. A regained access on reconnect and lost it after revocation. Revoking B denied its current session and a subsequent reconnect. This was synthetic store-level evidence, with transport, actual filesystem effects and cloud continuity still open.

At [Mac folder revision fa7ea80](https://github.com/Section9Labs/tachi/commit/fa7ea80b6055d2ea3e6a867db74b0c02f1dda3fb), QA independently ran the local-folder test suite on macOS with Python 3.14.7. Nine native cases passed and the unsupported-platform control skipped. Two separately paired logical hosts executed real local file operations on one Mac. While A was offline, B published its file and the reference cloud adapter finished. A reconnected, executed once and a revoked grant blocked its next file. Cross-machine transport, a cloud provider and physical mixed-host acceptance remain open.
