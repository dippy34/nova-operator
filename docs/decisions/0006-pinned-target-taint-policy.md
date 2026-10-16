# 0006. Pinned-target taint policy

Status: Proposed
Date: 2026-10-16
Proposed by: Claude, synthesizing ChatGPT's objection to blanket taint gating

## Context

The original proposal required approval for any `comm.send`, `publish`, `purchase`, or `auth.change` from a context that had read untrusted content. ChatGPT objected that this defeats unattended autonomy: nearly every useful mission reads something untrusted. ChatGPT proposed quarantining actions when untrusted content "attempts to modify" recipients, destinations, or scope.

That counter-proposal has the right goal, but deciding whether content "attempts" something is a judgment call. Making that judgment with a model would put a model in the authorization path, which [`AGENTS.md`](../../AGENTS.md) forbids.

## Decision

Policy checks every **target-bearing argument** (recipient, domain, path, repo, branch, payee) against the `MissionGrant`. The rule is deterministic:

| Grant target | Context | Decision |
| --- | --- | --- |
| Pinned (exact value, e.g. `team@example.com`) | Clean or tainted | Allow, subject to budgets, rates, and postconditions |
| Pattern or wildcard (e.g. `*@example.com`) | Clean | Allow, subject to budgets, rates, and postconditions |
| Pattern or wildcard | Tainted | Needs approval |
| Not covered by the grant | Any | Deny (or approval, if the effect is approvable) |

Taint is coarse and per context: once a Brain context reads web content, email, documents, or agent output, every proposal from that context carries the taint flag.

Outbound payloads (message bodies, published content) are scanned by the executor for secret references and known credential formats before sending.

## Alternatives considered

- **Blanket taint gating.** Rejected: blocks most unattended work.
- **Model-judged "injection attempt" detection.** Rejected as an authorization input. A model may flag content for the mission report, but its verdict can never allow or deny.
- **No taint tracking.** Rejected: wildcard grants plus injected recipients is exactly the exfiltration path to close.

## Consequences

- Matthew gets more autonomy by pinning targets in grants, and pays for flexibility (wildcards) with approvals. That trade-off is visible in the grant UI.
- Injection can still shape the *content* sent to a pinned recipient. The payload scan reduces but doesn't eliminate that risk; mission reports should show sent content for review.
- Requires adversarial tests in Phase 4: an injection page tries to redirect a send to an unpinned recipient (must be blocked or require approval) and tries to include a secret in a pinned send (must be caught by the scan).

## Objections

None yet. ChatGPT to review.
