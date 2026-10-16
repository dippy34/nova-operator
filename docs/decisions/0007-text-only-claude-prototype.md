# 0007. Bounded Claude conversation before operator capabilities

Status: Proposed
Date: 2026-10-16
Proposed by: Codex

## Context

Matthew requested AI after confirming wireless Phase 1 tasks. He selected Claude API billing and reported $8.46 in credits. This does not authorize unrestricted autonomous execution or spending the entire account balance.

## Decision

Implement `ai.chat` as text-only conversation using `claude-haiku-5-5`. Core dispatches a short-lived child process with an empty inherited environment. The worker reads only the selected key from a private, ignored `.env.local`. It receives a bounded message list, not pairing credentials or repository contents. There are no model tools, command parsers, shell execution paths, automatic retries, or background model requests. Text returned by Claude is displayed, never executed. The existing Mac and repository status checks remain explicitly selected, deterministic jobs.

Use at most 2 prior successful exchanges from the requesting device, bounded per message. Limit new messages to 2,000 characters and generation to 512 tokens. Reject concurrent AI requests. A persistent SQLite ledger reserves $0.01 before dispatch against a $1 lifetime Nova allowance, then replaces it with a rounded-up estimate from returned token usage. Failures, cancellation and crashes retain the reservation because remote billing may have happened. There is no remote budget-change endpoint. Increasing the allowance requires editing `AI_BUDGET_MICROS` locally and restarting Core; it is intentionally not automatic.

Prices verified against [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing) on 2026-10-16: $0.10 per million input tokens and $0.50 per million output tokens below 100k input. Short inputs, no tools/caching, and the output limit leave margin under the reservation. This is a local estimate-based guard, not an Anthropic account billing limit. Other clients, price changes, tax and provider adjustments are outside this ledger. No automatic model fallback is permitted.

API: [Messages](https://platform.claude.com/docs/en/api/messages/create), [Haiku 5.5](https://platform.claude.com/docs/en/models/haiku-5-5/overview). Default adaptive thinking is explicitly disabled for predictable short replies. API/model availability must be proven with the user's account.

## Alternatives considered

- Subscription authentication: deferred at Matthew's request.
- Full agent SDK and tools now: deferred until execution-time authorization and OS containment are tested.
- In-process HTTP client: a child process keeps API code/lifecycle separate, though it is not isolation.

## Consequences

This is not the contained Brain described in ADR 0001. Both processes still run as the same macOS user and can access that user's files. There is no kernel-enforced filesystem/network sandbox. No privileged model tools can be introduced under this arrangement. The system prompt describes capabilities but is not an authorization boundary; the absence of execution interfaces enforces the restriction.

Recent chat history is intentionally short; it is not long-term memory. Chat text/results remain in the existing private SQLite job journal. The key stays on the Mac and is sent only as an HTTPS authentication header to the fixed Anthropic API endpoint; redirects are rejected. Chat text goes to Anthropic, as disclosed in the native app. This prototype accepts AI requests from already-paired devices, so they share the $1 allowance; companion-specific scopes remain future work.

## Objections

None recorded. Broader trust split and containment proposals remain Proposed; this implementation does not claim they are proven.
