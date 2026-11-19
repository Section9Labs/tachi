# Zapia

Preliminary matrix for issue #15. Reviewed 2026-11-19. No v1 adapter is registered, and no capabilities are advertised. Zapia is not Grok Bot, Instinct, or Claude Duet.

## Product

Zapia is the personal assistant from BrainLogic AI (Montevideo and San Francisco). The company site is [zapia.com](https://zapia.com). People use the Android, iOS, and web app at [app.zapia.com](https://app.zapia.com). The company's 19 January 2026 post says Zapia stopped operating inside WhatsApp after a Meta policy change, and that the app remained the place to use the assistant. Store listings checked later in 2026 still mention WhatsApp features, so the store text and the company post disagree. The company post is the source for the channel shutdown.

Public pages read for this pass do not include a developer portal, OpenAPI document, or session SDK. The terms of use prohibit reverse engineering and prohibit creating APIs or other automated connections without Zapia's consent.

## Authorization

No team-controlled Zapia account is available. The consumer path is an account in the Zapia app. Plans named on the company's own changelog (7 May 2026) are a free tier plus Pro and Ultra. That changelog is the pricing source used here. Third-party price tables are not.

A model API from another vendor, including any model Zapia happens to host, is not a Zapia session.

## Matrix

| Operation | Status | Evidence |
| --- | --- | --- |
| Identity | Personal assistant app, plus web at app.zapia.com | zapia.com and the 19 January 2026 post |
| Sign in | Account created in the app | Company post. Not exercised |
| Send a message | Chat and voice notes in the app | Store and site descriptions. Not exercised |
| Voice | Voice notes are part of the product description | App listing text |
| Attachments | The privacy notice describes audio, PDF, video, and image processing | Privacy notice. Retention details stay in that notice |
| Tools | The product connects mail, calendar, and other apps the user turns on | Changelog, 18 June 2026, for Google mail, Drive, and calendar |
| Tasks | Scheduled tasks and agents that carry out work | Changelog entries for Pro, Ultra, and Zapia Max |
| Approval | Zapia Max is described as asking before some actions and logging steps | Changelog, 13 April 2026 |
| Cancellation | Not specified as a session API | Unknown |
| Recovery | Not specified | Unknown |
| Drift | Store copy still mentions WhatsApp after the company said that channel stopped | Recorded as a source conflict, not resolved by using the product |
| Programmatic API | No public session API found. Terms restrict unauthorized automation | Access blocker |

## Access blocker

Issue #15 needs a team-controlled account and the exact product. The product is the Zapia app from BrainLogic AI. The account is missing. Building a private client would conflict with the published terms, so this pass does not ship a connector.

## Distinct from the others

Zapia is a BrainLogic consumer app with its own account. It is not a Cursor-account bot, not an iMessage or phone-call agent, and not a Claude research preview.
