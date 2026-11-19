# Zapia

Preliminary matrix for issue #15. Reviewed 2026-11-19. No v1 adapter is registered, and no capabilities are advertised. Zapia is not Grok Bot, Instinct, or Claude Duet.

## Product

Zapia is the personal assistant from Brainlogic AI SAS. The company site is [zapia.com](https://zapia.com). People use the Android, iOS, and web app at [app.zapia.com](https://app.zapia.com).

## Identifiers

Confirmed from the company site on 2026-11-18.

| Identifier | Status | Source |
| --- | --- | --- |
| Product name Zapia | Confirmed | [Terms](https://zapia.com/terminos?lang=en) and the [privacy notice](https://zapia.com/privacy?lang=en), last updated 2026-04-01 |
| Legal entity Brainlogic AI SAS | Confirmed | Terms and privacy notice. The notice intro also says BrainLogic AI. That is the same company name with a different capital letter, not a second entity |
| Location Montevideo, Uruguay | Confirmed | Privacy notice contact block |
| Web app https://app.zapia.com/ | Confirmed | Company homepage link |
| Apple listing id 6470821480 | Store listing | Company homepage links to `apps.apple.com/uy/app/zapia-ai-personal-assistant/id6470821480` |
| Android package `com.brainlogic.zapia` | Store listing | Company homepage links to the Play Store id `com.brainlogic.zapia` |
| URL scheme `zapia` | Confirmed in a homepage deep link | The homepage emits `zapia://chat`. This is not a bundle id |
| Bundle id | Ambiguous | Unpublished on the terms, the privacy notice, and the homepage |
| WhatsApp as a channel | Ambiguous | The [19 January 2026 post](https://zapia.com/blog/zapia-whatsapp-stopped-working-what-happened?lang=en) says Zapia stopped replying inside WhatsApp in Mexico, Argentina, and Colombia, and that it continued in Brazil while a CADE review was open. The homepage still offers Connect my WhatsApp |
| Session API | Unpublished on the terms | Terms restrict unauthorized automated connections. No adapter |

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
| Drift | WhatsApp status differs by country and by later homepage copy | 19 January 2026 post versus the homepage Connect my WhatsApp action. Not resolved by using the product |
| Programmatic API | No public session API found. Terms restrict unauthorized automation | Access blocker |

## Access blocker

Issue #15 needs a team-controlled account and the exact product. The product is the Zapia app from BrainLogic AI. The account is missing. Building a private client would conflict with the published terms, so this pass does not ship a connector.

## Distinct from the others

Zapia is a BrainLogic consumer app with its own account. It is not a Cursor-account bot, not an iMessage or phone-call agent, and not a Claude research preview.
