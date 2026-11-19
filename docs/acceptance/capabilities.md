# Capability inventory · 2026-11-19 UTC

This is the public QA baseline for [#23](https://github.com/Section9Labs/tachi/issues/23). Each cell describes **evidence through Tachi**. `F` means exercised with a synthetic fixture, `L` means demonstrated through an authorized native session, `U` means unavailable through the cited implementation, and `?` means unresolved. `F/U` records fixture support alongside unavailable native execution. Source inspection and an owner's reference-client observations are listed separately below. An empty native track establishes no vendor limitation.

| Assistant or harness | Message | Task | Attachment | Tools | Cancel | Recover | Native evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| OpenAI Dot | U | U | U | U | U | U | Existing-Dot binding unavailable in Tachi |
| Grok Bot | ? | ? | ? | ? | ? | ? | Native bot binding and tool run pending |
| Instinct | ? | ? | ? | ? | ? | ? | Exact product and account path pending |
| Zapia | ? | ? | ? | ? | ? | ? | Exact product and account path pending |
| Claude Duet | ? | ? | ? | ? | ? | ? | Exact product and account path pending |
| Deterministic reference | F/U | F/U | U | U | U | U | In-process fixture with synthetic identities |
| Tachi-managed hosted harness | ? | ? | ? | ? | ? | ? | Separate registration and genuine session pending |

## Sources and promotion criteria

- **OpenAI Dot.** The owner inspected public issuer metadata, the Codex schema and reference-client behavior. Public sign-in discovery and offline schema fixtures have evidence. An authorized independent binding to an existing Dot, a fresh conversation, native action and retrieval after reconnect remain unavailable. The adapter advertises zero operations. [Dated Dot investigation](https://github.com/Section9Labs/tachi/blob/00a292930ba6a86795da8109276ea6f85da75d88/docs/providers/dot.md) · [Issue #3](https://github.com/Section9Labs/tachi/issues/3)
- **Grok Bot.** Before the first native mark, identify the Bot product, subscription account path and existing assistant binding. Require a correlated native action and result from that same session. [Grok Bot investigation #4](https://github.com/Section9Labs/tachi/issues/4)
- **Instinct.** Identify the product and supported account/assistant selector. Record any vendor-specific actions individually with source version and observation. [Instinct investigation #14](https://github.com/Section9Labs/tachi/issues/14)
- **Zapia.** Confirm the harness, authorized integration surface and native permissions before testing account-bound work and recovery. [Zapia investigation #15](https://github.com/Section9Labs/tachi/issues/15)
- **Claude Duet.** Identify the exact assistant and supported session surface. Verify access to the selected identity and native action under that identity. [Claude Duet investigation #16](https://github.com/Section9Labs/tachi/issues/16)
- **Reference harness.** QA reran all six conformance tests at `73afd4d`. The adapter declares `message` and `task` and returns deterministic completion events. Duplicate-event and uncertain-submission controls are fixture evidence. The source exposes no attachment, native tool, cancellation or recovery operation. [Reference implementation](https://github.com/Section9Labs/tachi/blob/73afd4d2c8f21f0f22482d8b9a0f1c8470433099/tachi/runtime/reference.py) · [Conformance tests](https://github.com/Section9Labs/tachi/blob/73afd4d2c8f21f0f22482d8b9a0f1c8470433099/tests/test_runtime_contract.py)
- **Tachi-managed hosted harness.** Record registration through the common contract, host and explicit permission grants, one genuine session and its independently retrieved artifact when delivered. [External connector and hosted-harness issue #17](https://github.com/Section9Labs/tachi/issues/17)

For each connector or provider change, record the old and new source/adapter version and date. Rerun advertised operations and denial controls with synthetic data. Track discover/attach/provision identity, list/create/resume conversation, approval, progress, artifact retrieval and each named provider action separately alongside the six v1 capability flags. Record `operation | fixture result | authenticated result | unavailable reason | dated source or run`. Keep the native receipt and output linked to the same account/assistant/session aliases. Downgrade a stale or failing operation and link its follow-up issue. Product identity, account, scopes and authority stay with the existing harness.
