# Claude Duet

Preliminary matrix for issue #16. Reviewed 2026-11-19. No v1 adapter is registered, and no capabilities are advertised.

Claude Duet is not Claude Code. Claude Code is Anthropic's coding agent for a repository and a terminal. Claude Duet is a separate research-preview app: a proactive agent with a cloud computer, a morning brief, and tasks that continue after the app closes. The Duet safety article says the product builds on safeguards that also exist in Claude Code and Claude Managed Agents. Shared safeguards do not make the products the same client. Claude Cowork is a third product, with its own help article, and is outside this matrix.

## Product

Anthropic introduced Claude Duet on 21 October 2026. The help center article updated 12 November 2026 is the behavior source: [Get started with Claude Duet](https://support.claude.com/en/articles/17631495-get-started-with-claude-duet). Product page: [claude.com/product/claude-duet](https://claude.com/product/claude-duet).

It is a research preview for Claude Pro, Max, and Ultra subscribers in the US, through a waitlist or an invitation from someone who already has it. Team and Enterprise plans are not included yet. It uses the Claude account and that plan's usage limits, including background work. It is included in the plan during the preview, not billed as a separate API meter. The model is Claude Opus 5.5. The user cannot pick a model.

## Identifiers

Confirmed from primary pages on 2026-11-18. The product name in this matrix is Claude Duet. The word Claude alone is ambiguous.

| Identifier | Status | Source |
| --- | --- | --- |
| Product name Claude Duet | Confirmed | [Get started with Claude Duet](https://support.claude.com/en/articles/17631495-get-started-with-claude-duet) and [claude.com/product/claude-duet](https://claude.com/product/claude-duet) |
| Model name Claude Opus 5.5 | Confirmed in the help article | A model name inside the product, not the product id |
| Clients | Confirmed as iPhone and Android apps plus the Claude account | Help article. No bundle id is stated there |
| Seller Anthropic PBC | Store listing | [App Store listing](https://apps.apple.com/us/app/claude-duet-by-anthropic/id6803276000). The help article does not spell the legal entity |
| Apple listing id 6803276000 | Store listing | Same App Store URL. Not stated in the help article |
| Bundle id | Ambiguous | Unpublished in the help article and not shown in the App Store information block read for this pass |
| Session API | Unpublished in the help article | No adapter |

Native clients named in the article are the iOS and Android apps, reached from an invitation email, plus the Claude account those apps sign into. The article also describes the product on claude.ai in the October launch post.

## Authorization

No team-controlled Duet seat is available. Access needs a US Claude account on Pro, Max, or Ultra, and an invitation. Sign-in is the Claude account. Disconnecting a connector stops later access. Memory of earlier conversations remains until those chats are deleted.

This project will not point the Claude Platform API, Claude Code, or Claude Managed Agents at a Duet task and call that a Duet session.

## Matrix

| Operation | Status | Evidence |
| --- | --- | --- |
| Identity | One main thread, extra channels, shared memory, Tasks tab, Make tab | Help center, 12 November 2026 |
| Sign in | Claude account after a waitlist invitation | Help center. Not exercised |
| Send a message | Type or voice in the thread | Help center |
| Voice | Voice messages. Phone calls and SMS to other people are not available | Limitations section |
| Attachments and results | Larger jobs return files in Make. It cannot see the computer's files or every Claude project, and it can read Claude work but not change it | Limitations section |
| Tools | Claude connectors the user already added, plus plugins. Browser for sites without a connector. Link and Shop Pay are Duet-only purchases | Help center |
| Tasks | Tasks tab. Only the user can mark a task complete. Morning brief and check-ins count against plan limits | Help center |
| Approval | Designed to ask before sending, paying, signing, or deleting. Purchases use a one-time card | Help center |
| Cancellation | Not given as a programmatic cancel. The user steers from the thread and the Tasks tab | No cancel API in the article |
| Recovery | Work continues on the cloud computer after the app closes. Urgent events can fall between account checks | Help center |
| Drift | Features can change during the research preview. No model pin other than Opus 5.5 | Help center |
| Programmatic API | None in the article. The user cannot watch or take over the browser | Access blocker |

## Access blocker

Issue #16 needs a team-controlled account and the exact product. The product is Claude Duet, the research preview above. The account and invitation are missing, and the help center does not document a session API. No native Duet operation was run.

## Distinct from the others

Claude Duet uses a Claude subscription and Claude connectors. It does not use a Cursor account, a Grok Bot webhook, an Instinct phone line, or a Zapia account. It is not Claude Code.
