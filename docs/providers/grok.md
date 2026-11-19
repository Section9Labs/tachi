# Grok Bot

Reviewed 2026-11-19. Provider id `grok-bot`. This is the desktop and mobile Grok Bot app (cloud computer, bots, routines), not Grok chat on grok.com, not the Grok Build CLI, and not the token-billed xAI API. Those three cannot satisfy a Grok Bot session.

Runtime's adapter contract v1 is adopted as published. The provider field is `grok-bot`. This package does not change that contract. With no operator webhook configured, the adapter registers with an empty capability set, same as an unbound assistant. Configuring a webhook advertises `task` only.

## What was observed

| Item | Value |
| --- | --- |
| Docs reviewed | 2026-11-19, docs.x.ai Grok Bot guides |
| Desktop app on this machine | Grok Bot 0.78.1, bundle `com.anysphere.sand`, URL schemes `grokbot` and `sand` |
| Public stable feed (`darwin-arm64`) | 1.2.3, commit `a5927fa2ba82336a29f9343babd28b4c903abbb2` |
| Client drift | Installed build is behind the stable feed |
| Grok Build CLI on this machine | 1.0.89. A different product. `grok usage` did not return a plan figure |
| Live routine | Not sent |

Sanitized probe output: [grok-bot.json](evidence/grok-bot.json). Repeat it with `PYTHONPATH=. python -m tachi.providers.grok`. The command reads the local app plist and the public release feed. It does not start a Bot, read transcripts, or call `api.x.ai`.

## Authorization

Subscription or included seat only. This connector has no API-key mode.

Sanctioned sign-in, from the Grok Bot get-started guide:

1. **Cursor browser sign-in.** The desktop and mobile apps finish sign-in in the browser. Company SSO is the existing Cursor SAML setup. There is no separate Grok Bot IdP app.
2. **Sign in with Grok.** Used when the seat is on a self-serve Grok Business plan.
3. **Link Grok Account.** Used for SuperGrok, SuperGrok Plus, SuperGrok Heavy, or X Premium+ at cursor.com/bot/onboarding, and on the phone access screen.

Plans that include the product: X Subscription Premium, Super, and Ultra (Plus does not). Legacy paid individual Cursor plans and self-serve Cursor Teams. A linked SuperGrok or X Premium+ subscription. A Grok Business seat. Privacy Mode (Legacy) has to be switched to Privacy Mode before the app will run.

The connector does not copy app credentials, keychain items, or `~/.grok` session files. Webhook bearer values stay with the operator.

## Normal client behavior

Authoritative guides: [overview](https://docs.x.ai/grok-bot/overview), [get started](https://docs.x.ai/grok-bot/get-started), [chat](https://docs.x.ai/grok-bot/chat-and-collaboration), [files](https://docs.x.ai/grok-bot/files-and-results), [routines](https://docs.x.ai/grok-bot/skills-routines-and-automations), [deployment](https://docs.x.ai/grok-bot/deployment).

People message a named Bot from the desktop app, the iOS and Android apps, Slack, or X Chat. The same bots share one cloud computer. A direct message can redirect work in progress. "Stop now" ends the turn and does not undo finished actions. Approval cards, email and Slack drafts, payments, and outbound phone calls wait in the app. Voice chat reconnects once on a short drop, then ends. Recreating the cloud computer drops sign-ins that lived on that computer.

A routine can start from a schedule, a connected-app event, or a webhook. The webhook is an HTTPS POST to the URL shown in the desktop routine, with the key in `Authorization: Bearer` and an optional JSON body. HTTP 200 means Grok Bot accepted the call and started a run. The routines guide says to check the Bot's chat for the result. Any other response means a run did not start. This connector binds the secret to that exact origin and path, does not follow a redirect, and discards the response body. Enterprise inference hooks are a separate outbound control.

No public Grok Bot model id or session SDK is documented. The deployment guide's release feed is the sanctioned way to read the current desktop version.

## v1 capabilities through this connector

`F` is a synthetic fixture. `U` means this connector cannot perform it. App support is in the next table and is not a native Tachi proof.

| Capability | Fixture | Native |
| --- | --- | --- |
| message | U | Not sent |
| task | F. HTTP 200 becomes `ACCEPTED`, with `native_reply` false | U. This run did not send the operator webhook |
| attachment | U | Not sent |
| tools | U | Not sent |
| cancel | U | Not sent. A dropped POST raises `DispatchUncertain` and is not retried |
| recover | U | Not sent |

## Connector operations

| Operation | Status |
| --- | --- |
| `probe_client` | Reads the installed desktop plist. No account data. |
| `fetch_release` | GET the documented `api2.cursor.sh` stable feed only. |
| `describe` | Returns this capability inventory. |
| `trigger_routine` | POST a bound webhook grant. No URL argument. 200 is `ACCEPTED` with `native_reply` false. An observed non-200, including 5xx, is a rejection. A timeout is uncertain after one POST. |

Refused: xAI API hosts, API-key billing, Grok Build prompts, Grok chat, copied app tokens, and transcript reads.

## Capability matrix

| Operation | In the app | This connector |
| --- | --- | --- |
| Sign in | Supported, three paths above | No token storage |
| Send a chat message | Supported | No |
| Voice | Supported | No |
| Attachments and pages | Supported. Pages need desktop 0.60.0+ or phone 1.14.0+, and are not on Enterprise yet | No |
| Tools and computer | Supported, including outbound MCP or API use by the Bot | No inbound invoke API |
| Routine webhook | Supported | Yes. The secret is bound to the issued origin and path |
| Approvals and payments | Supported in the app | No |
| Cancel a turn | "Stop now", hang up, end call, pause a routine | No cancel token for a webhook run |
| Recovery | Quit and reopen. Voice retries once. Computer recreate drops sign-in | No |
| Client drift | Update check inside the app | Yes, plist versus release feed |
| Read history | In-app search | Refused |
| Model chat | Not this product | Refused |

## Access dependency

This engineering record did not start a routine. For a user who already has an authorized webhook, that webhook is the product step. `trigger_routine` and `GrokBotAdapter.dispatch` post it without a quota checkpoint.

`quota.py` remains an engineering gate for shared-account spend probes. `grok usage` belongs to Grok Build and returned no plan figure, so it is not a checkpoint source. When an engineer writes a checkpoint, it comes from Grok Bot Settings → Usage & Billing with `source` `grok-bot-settings` or `operator-attestation`, `billing` `subscription`, and `weekly_pool` `available`. It must be under 12 hours old and must not contain an account id.

The webhook URL and secret are minted in the signed-in app. They are not in this repository. `bind_webhook` freezes the secret to that scheme, host, port, and path. `trigger_routine` accepts the grant and has no URL argument. A query, fragment, userinfo, a raw IP, billed API host, or the release-feed host is refused before a POST. A redirect is a non-200 response and is not followed. The response body is closed unread.

Swift enrollment is `provisionRoutineGrant` and `loadRoutineGrant` in `Packages/TachiGrok`. The operator copies the issued URL and key from the desktop routine, then provision writes a directory mode `0700`. `enrollment.json` holds version 1, provider `grok-bot`, the human id, and the canonical destination. The `secret` file holds the destination plus the bearer. Both files are mode `0600` and owned by the effective user. A different human, a loose mode, a symlink, another user's file, a non-regular file, or a destination that does not match the secret file is `notSent`, and neither call POSTs. Description text omits the path and the secret. Replacing a grant means removing that directory and provisioning again.

`--solo-routines-file` remains the private JSON credential and does not read an enrollment directory. A separate invocation loads one directory with `--solo-enrollment-directory`, `--solo-enrollment-human`, and `--solo-enrollment-routine`. That path calls `loadRoutineGrant` and does not copy the secret into the JSON file. The two sources cannot be combined. `--solo-loopback-fixture` is still required for an `http://127.0.0.1` destination. Until this composition is merged, the shipping coordinator on main has only the JSON file.

The issued grant is created in the signed-in Grok Bot app, not by this repository. On desktop, open the Bot's name, the Details tab, and the routine. Ask the Bot to add a webhook trigger if the routine does not have one. The Webhook section shows **POST to**, **key**, and **header**. The key is the bearer. No issued grant was supplied to this checkout, and there is no fresh Grok Bot Settings → Usage & Billing attestation, so this record still has not started a routine.

## Result path

Read on 2026-11-18 from the [routines guide](https://docs.x.ai/grok-bot/skills-routines-and-automations) and the [inference hooks guide](https://docs.x.ai/grok-bot/inference-hooks).

The routines guide names two places a person can see how a run ended. The Bot's chat receives the result after a webhook `200`. On the phone, Run history lists the 20 most recent runs for that routine as Running, Succeeded, or Failed. That list is in the app.

The same guide does not document a signed callback to the webhook caller, and it does not document a programmatic read of Run history. A rate-limited run is not retried by Grok Bot. The guide says the caller may send the webhook again. This connector sends it once.

Inference hooks are an Enterprise control in the other direction. Cursor POSTs a signed Standard Webhooks request to the team's security server, using a `whsec_` secret and the `webhook-id`, `webhook-timestamp`, and `webhook-signature` headers, so that server can allow or deny a model call. A policy block can show later as a failed routine in the app, and the Cursor dashboard can show a block note. That signature does not deliver the routine result to the webhook that started the run.

No further owner step. This connector does not ask the user to paste a chat reply, and it does not read the chat or the phone history. Acceptance stays one `ACCEPTED` event with `native_reply` false. A response body is not proof of completion. This connector has no completion call.

## Contract friction

The connector imports the pinned v1 types from `tachi.runtime` and registers through `AdapterRegistry`. These are the points where Grok Bot does not fit that contract. The contract itself is unchanged.

- **`task` is a routine trigger.** The only sanctioned programmatic start is a webhook for a routine the operator already saved. The JSON payload is forwarded as the webhook body. Grok Bot does not treat that payload as a new free-form assignment, and it does not return a Bot reply on the HTTP call.
- **An accepted routine is not a native reply.** HTTP 200 becomes one `ACCEPTED` event with `routine_accepted` true, `native_reply` false, and `native_session_observed` false. The connector never emits `COMPLETED` or `PROGRESS` for that response. The response body is discarded, so a body that claims completion cannot change that event.
- **`session_id` is not a Bot conversation id.** Events copy `identity`, `session_id`, and `request_id` from the request and do not replace them. The webhook response has no native conversation id. A native id cannot be written into `session_id` without breaking the registry's same-session rule.
- **The secret is bound to the issued origin and path.** `trigger_routine` takes a `WebhookGrant` from `bind_webhook`. A raw URL, a different path, a query, a fragment, userinfo, a raw IP, `api.x.ai`, `mtls.api.x.ai`, or `api2.cursor.sh` is refused with no POST. Redirects stay off. A 3xx response becomes `RoutineRejected` and then a `FAILED` event. The connector does not open the `Location`.
- **An observed non-200 is a rejection. A missing response is uncertain.** The routines guide says any response other than 200 means a run did not start, so an observed 5xx becomes `RoutineRejected` and then a `FAILED` event. A timeout is not a response. It raises `DispatchUncertain` after one POST. This process does not replay either outcome. A later retry would start a second routine. The durable queue is a separate layer and is not implemented here.
- **Authority is the operator webhook.** An engineering quota checkpoint is not a product step and is not consulted on dispatch. The connector does not hold the Cursor or Grok session. `account_id` and `assistant_id` are caller-supplied opaque strings. The product does not offer an API that lists those ids.
- **Unsupported work stays unadvertised.** `message`, `attachment`, `tools`, `cancel`, and `recover` are absent from `capabilities`. The registry raises `UnsupportedCapability` before `dispatch`. In-app stop, approval, and reopen exist, and there is no v1 operation for them.

## Gaps

- No sanctioned session or message API. The webhook cannot target an arbitrary turn, attach a file, approve an action, or cancel a run.
- Installed 0.78.1 is behind stable 1.2.3 on darwin-arm64. Desktop, Android, and the feed use different version lines.
- v1 `task` acceptance is not a native reply and not completion. Message, attachment, tool, cancel, and recover calls remain unpublished for this connector.
- Enterprise inference hooks and audit logs were not exercised. They are admin features, not a user connector.
