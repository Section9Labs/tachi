# Independent acceptance lab

## Bootstrap HTTP

From a coordinator checkout, start `python3 -m tachi --port 8743`. In a second terminal, run `python3 qa/probe_status.py` from the QA checkout. The probe uses the standard library and connects directly to loopback. Exit 0 requires `GET /v1/status`, HTTP 200, media type `application/json`, and exactly `{"service":"tachi","protocolVersion":1,"status":"ready"}`. Field order and whitespace are immaterial. A redirect, duplicate field, JSON boolean or float in place of the integer, invalid body, or transport failure exits 1. Stop the server you started after testing.

Run `python3 qa/test_probe_status.py` for the synthetic HTTP controls. Run `PYTHONPATH=. python3 qa/check_reference_turns.py` with adapter v1 present to exercise a solo fixture and a manually relayed sequence between two synthetic registrations. The driver supplies the requests and parent references. It checks request, identity, session and completion at each hop. Actual delegation, file access, client intervention and retrieval require the live scenario below. With the host module from [#6](https://github.com/Section9Labs/tachi/issues/6) on the Python path, run `PYTHONPATH=. python3 qa/check_host_grants.py` from an integrated checkout for the two-host database check. These commands are for engineers. Product scenarios below start and end in the Apple apps.

On 2026-11-19 at 02:07:43 UTC, the independent client (Python 3.14.7) exited 0 against the running loopback coordinator at [bootstrap revision 30d38d0](https://github.com/Section9Labs/tachi/commit/30d38d0dd9b580b540b539b8b5410947ea503927). Scope of observation was one real HTTP request on macOS. Provider, Apple client and remote deployment acceptance are pending.

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
