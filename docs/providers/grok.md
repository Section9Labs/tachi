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

A routine can start from a schedule, a connected-app event, or a webhook. The webhook is an HTTPS POST with `Authorization: Bearer <key>` and an optional JSON body. HTTP 200 means the run was accepted, not that the Bot finished. The key is shown in the desktop routine. Enterprise inference hooks are a separate, outbound, Enterprise control and are not a client API.

No public Grok Bot model id or session SDK is documented. The deployment guide's release feed is the sanctioned way to read the current desktop version.

## v1 capabilities through this connector

`F` is a synthetic fixture. `U` means this connector cannot perform it. App support is in the next table and is not a native Tachi proof.

| Capability | Fixture | Native |
| --- | --- | --- |
| message | U | Not sent |
| task | F. HTTP 200 becomes `accepted`, with `completed` false | U. No quota checkpoint and no operator webhook in this run |
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
| `require_quota_checkpoint` | Blocks spend until a fresh subscription checkpoint says the weekly pool is available. |
| `trigger_routine` | POST a routine webhook after the checkpoint. Mapped to v1 `task`. 200 is `accepted`, not `completed`. |

Refused: xAI API hosts, API-key billing, Grok Build prompts, Grok chat, copied app tokens, and transcript reads.

## Capability matrix

| Operation | In the app | This connector |
| --- | --- | --- |
| Sign in | Supported, three paths above | No token storage |
| Send a chat message | Supported | No |
| Voice | Supported | No |
| Attachments and pages | Supported. Pages need desktop 0.60.0+ or phone 1.14.0+, and are not on Enterprise yet | No |
| Tools and computer | Supported, including outbound MCP or API use by the Bot | No inbound invoke API |
| Routine webhook | Supported | Yes, after a quota checkpoint |
| Approvals and payments | Supported in the app | No |
| Cancel a turn | "Stop now", hang up, end call, pause a routine | No cancel token for a webhook run |
| Recovery | Quit and reopen. Voice retries once. Computer recreate drops sign-in | No |
| Client drift | Update check inside the app | Yes, plist versus release feed |
| Read history | In-app search | Refused |
| Model chat | Not this product | Refused |

## Access dependency

A native Bot run was not repeated. Two gates are still open:

1. **Quota checkpoint.** No headless Grok Bot usage command was found. `grok usage` belongs to Grok Build and returned no plan figure. Live work stays off until an operator writes a checkpoint from Grok Bot Settings → Usage & Billing with `source` `grok-bot-settings` or `operator-attestation`, `billing` `subscription`, and `weekly_pool` `available`. The checkpoint must be under 12 hours old. It must not contain an account id.
2. **Operator webhook.** The URL and bearer are minted in the signed-in app. They are not in this repository.

Until both exist, `trigger_routine` does not send.

## Gaps

- No sanctioned session or message API. The webhook cannot target an arbitrary turn, attach a file, approve an action, or cancel a run.
- Installed 0.78.1 is behind stable 1.2.3 on darwin-arm64. Desktop, Android, and the feed use different version lines.
- v1 `task` acceptance is not completion, and there is still no message, attachment, tool, cancel, or recover call.
- Enterprise inference hooks and audit logs were not exercised. They are admin features, not a user connector.
