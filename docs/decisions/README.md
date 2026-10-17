# Decision records

One file per significant architectural choice. Statuses: `Proposed`, `Accepted`, `Rejected`, `Superseded by NNNN`. Only Matthew moves a record to `Accepted` or `Rejected`.

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-trust-split.md) | Split trust between Core, Brain, and token-verifying executors | Proposed |
| [0002](0002-effect-policy-with-containment.md) | Effect-based execution-time policy, backed by OS containment | Proposed |
| [0003](0003-tailscale-transport.md) | Tailscale for v1 transport instead of a custom gateway | Proposed |
| [0004](0004-dynamic-task-graph.md) | Journaled dynamic task graph instead of a DAG engine | Proposed |
| [0005](0005-low-trust-desk-companion.md) | Desk companion is a low-trust device that can never approve | Proposed |
| [0006](0006-pinned-target-taint-policy.md) | Pinned-target taint policy: tainted contexts need approval only for unpinned targets | Proposed |
| [0007](0007-text-only-claude-prototype.md) | Bounded text-only Claude conversation before operator capabilities | Proposed |
| [0008](0008-reviewed-app-control.md) | Reviewed app-scoped computer sessions with a contained Brain | Superseded by 0009 |
| [0009](0009-autonomous-computer-control.md) | Autonomous whole-Mac control with Claude computer use | Accepted |
| [0010](0010-work-agents-and-takeover.md) | Background agents, schedules, unlimited spending and iPhone take-over | Proposed |
| [0011](0011-setup-and-range.md) | Onboarding, access range and Keychain provider keys | Proposed |

## Template

```markdown
# NNNN. Title

Status: Proposed
Date: YYYY-MM-DD
Proposed by: <author>

## Context
What problem this solves and what constrains it.

## Decision
What we'll do.

## Alternatives considered
What else was on the table and why it lost.

## Consequences
What gets easier, what gets harder, what we're committing to.

## Objections
Disagreements from other reviewers, with their reasoning. Never deleted.
```
