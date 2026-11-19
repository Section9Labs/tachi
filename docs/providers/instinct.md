# Instinct

Preliminary matrix for issue #14. Reviewed 2026-11-19. No v1 adapter is registered, and no capabilities are advertised. Instinct is not Grok Bot, Zapia, or Claude Duet.

## Product

Instinct is a personal assistant from the company behind instinct.com. The official homepage, read on 2026-11-18, describes text or a phone call as the interface, and a phone and computer used the way a person would. The call to action is [Try Instinct](https://app.instinct.com/login).

## Identifiers

Confirmed from the live pages on 2026-11-18.

| Identifier | Status | Source |
| --- | --- | --- |
| Product name Instinct | Confirmed | [Terms](https://instinct.com/terms), last revised 2026-11-17, and [privacy policy](https://instinct.com/privacy-policy), last revised 2026-11-17 |
| Legal entity Spear Street Technology, Inc., a Delaware corporation | Confirmed | Same terms |
| Trade name Instinct | Confirmed on the SMS pages | [SMS terms](https://instinct.com/legal/sms-terms.html), last revised 2026-08-17, say Spear Street Technology, Inc. d/b/a Instinct. The 2026-11-17 terms name the corporation and do not repeat that line |
| Website www.instinct.com | Confirmed | Terms and privacy policy |
| App host app.instinct.com | Confirmed | Homepage, terms, and privacy policy |
| Paths `/workspace` and `/settings` | Confirmed | Homepage, terms, and privacy policy |
| Sign-in path | Two published entry points | Homepage call to action is `https://app.instinct.com/login`. SMS terms name the OTP flow at `https://app.instinct.com/signin` |
| Bundle id | Ambiguous | Unpublished on the homepage, the 2026-11-17 terms, the privacy policy, and the SMS terms |
| Session API | Unpublished on those pages | No adapter |

Secondary write-ups from early November 2026 still describe an invite-only beta reached through iMessage, WhatsApp, and phone, with email, calendar, and read-only financial connections. Those reports are not the product contract. The homepage now shows a login URL and does not publish a session API, SDK, or webhook.

## Authorization

No team-controlled Instinct account is available in this session. The supported native path is the product itself: open `https://app.instinct.com/signin`, enter a phone number, and receive one SMS one-time code, as the SMS terms describe. The homepage also links to `https://app.instinct.com/login`, which presents a sign-in page. After sign-in the interface is a text or a phone call. No subscription price is stated on the homepage. This project will not use a billed model API as a stand-in, and it will not reverse engineer the service. No sign-in was completed.

## Matrix

| Operation | Status | Evidence |
| --- | --- | --- |
| Identity | A personal assistant reached by text or call | instinct.com, 2026-11-19 |
| Sign in | Phone number and one SMS code at `app.instinct.com/signin`, or the homepage login page | SMS terms and homepage. Not exercised |
| Send a message | In product, by text | Homepage. No programmatic client found |
| Voice | A phone call is part of the product description | Homepage |
| Attachments | Not stated on the homepage | Unknown |
| Tools and connected accounts | Secondary reports name email, calendar, and read-only finance | Not confirmed on the homepage this pass |
| Tasks | Errands such as bookings are the stated job | Homepage examples |
| Approval | Not specified on the homepage | Unknown |
| Cancellation | Not specified | Unknown |
| Recovery | Not specified | Unknown |
| Drift | Not specified | Unknown |
| Programmatic API | None published on the pages read | Access blocker |

## Access blocker

Issue #14 depends on a team-controlled account and the exact product. The exact product is the Instinct assistant at instinct.com. The account is missing, and no sanctioned session API was found, so there is no native proof and no connector.

## Distinct from the others

Instinct's native client is a text or phone relationship plus its own computer, with a login at `app.instinct.com`. It does not use the Grok Bot routine webhook, the Zapia mobile app, or a Claude subscription.
