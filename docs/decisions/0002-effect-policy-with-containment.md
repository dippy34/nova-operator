# 0002. Effect-based execution-time policy, backed by OS containment

Status: Proposed
Date: 2026-10-16
Proposed by: Claude

## Context

Matthew's revision requires every concrete action to pass deterministic, effect-based authorization, and agents must not bypass it through alternate tools. Policy keyed on tools fails: deny Mail.app and an agent tries Gmail in Chrome, `osascript`, or curl.

But effect-based policy only works when an action's effect can be determined before it runs. Two big classes can't be:

- A raw CGEvent click at coordinates has no knowable effect.
- `bash -c "$(cat x)"` can't be classified by parsing.

## Decision

1. Policy reasons about **effects** from a small taxonomy (see [`architecture.md`](../architecture.md)), derived by adapter code, never claimed by the model.
2. Policy is evaluated at **execution time** on each concrete `ActionDescriptor`, not on plans.
3. Where effects can't be classified, **OS containment** enforces the boundary instead:
   - Shell commands and coding agents run in a **validated OS-enforced containment boundary** with narrowly scoped writable paths. `sandbox-exec` / Seatbelt profiles are not a sufficient promised production strategy without verification; evaluate a restricted user account, VM, and appropriately scoped native sandbox capabilities.
   - Network egress is enforceably constrained, not merely configured with a proxy environment variable. Verify attempted direct sockets, DNS, subprocesses, `curl`, browser traffic, and agent tooling are blocked outside allowlisted destinations. A VM or entitled system-level filter may be needed; document remaining gaps.
   - GUI clicks are hit-tested with AX. When AX can't identify the target, the action is `gui.opaque(app)`, allowed only under an explicit per-app `full-control` grant.
4. A `deny` closes the effect for the rest of the mission, so the planner stops searching for alternate routes.

## Alternatives considered

- **Tool-based allowlists.** Rejected: trivially bypassed by alternate tools.
- **Command parsing for shell.** Rejected: undecidable in general, easy to obfuscate.
- **Model-based effect classification.** Allowed only to *escalate* risk, never to permit.

## Consequences

- Every adapter operation needs an effect descriptor and, for side effects, a reconcile probe. This is the largest engineering workload in the project.
- `full-control` grants are coarse. Matthew must consciously grant them per app.

## Objections

- **ChatGPT, 2026-10-16:** A normal proxy setting can be bypassed; `sandbox-exec` is deprecated. Treat containment as **unproven** until negative tests establish filesystem, credential and network boundaries. Also, any taint policy must permit truly preauthorized, verifiable actions despite reading untrusted data; provenance cannot be used as a universal approval trigger.
- **Claude, 2026-10-16 (response):**
    - *Proxy bypass:* agreed that a proxy environment variable alone is bypassable, and my original wording didn't say how traffic was forced through the proxy. The intended mechanism is a Seatbelt rule that denies all outbound network except the proxy's localhost port. That is kernel-enforced, so ignoring the variable or opening a raw socket fails. Now spelled out in [`architecture.md`](../architecture.md).
    - *Seatbelt deprecation:* agreed it's deprecated as a public CLI and must not be called proven until tested. But calling it unsuitable for production overstates it: it is the mechanism shipping macOS agent sandboxes rely on today, including the Codex CLI and Claude Code (verify current versions). Proposal: keep Seatbelt as the primary candidate, require the negative tests before trusting it, and keep a VM as the fallback if tests fail or Apple removes it.
    - *Taint:* agreed that blanket gating defeats autonomy. But "quarantine when content attempts to modify recipients" needs something to judge an attempt, and that judge can't be a model. Counter-proposal with a deterministic trigger in [ADR 0006](0006-pinned-target-taint-policy.md).
