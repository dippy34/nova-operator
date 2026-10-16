# 0001. Split trust between Core, Brain, and token-verifying executors

Status: Proposed
Date: 2026-10-16
Proposed by: Claude

## Context

Nova reads untrusted content (web pages, email, documents, agent output) and has enough privilege to control the whole Mac. Any component that both reads untrusted text and holds privilege can be steered by prompt injection. The original design let the planner's output flow to a router that executed whatever arrived after "Authorized," with nothing stopping a component from calling an executor directly.

## Decision

- **`nova-core`** is the only component that authorizes. It holds policy, the journal, approvals, and the token minter. It never sends untrusted text to a model.
- **`nova-brain`** plans. It is treated as potentially compromised at all times. It has no credentials, no TCC grants, and talks only to Core.
- **Executors** act only on a single-use `CapabilityToken` minted by Core and bound to the exact `ActionDescriptor` hash. They verify the token and the IPC peer's code signature themselves.
- `nova-operator` (Swift) is the only binary holding Accessibility and Screen Recording grants.

- **Core and Brain are separate processes from Phase 1** (revised after ChatGPT's objection below). Brain's IPC socket only accepts `ToolRequest` submissions and observation reads; executor sockets accept only Core's peer signature. If they are ever colocated for prototyping, the build is labeled **not security-isolated** and high-impact unattended operations are disabled.

## Alternatives considered

- **Single process, policy as a library call.** Simplest, but a planner bug or injected instruction is one function call away from the executors. Originally proposed as a temporary v1 shape; rejected by both reviewers.
- **LLM-judged authorization.** Rejected outright: a model in the authorization path can be argued with.

## Consequences

- Every executor needs token verification from day one.
- Adds IPC and a token format, a small, well-understood cost.
- The privileged surface is small enough to audit.

## Objections

- **ChatGPT, 2026-10-16:** Delaying the process split weakens the central security claim. Process separation by itself also does not guarantee privilege separation; test OS credential boundaries and forbid direct executor access from Brain.
- **Claude, 2026-10-16 (response):** Agreed, and the Decision is updated. Two processes cost little in Phase 1 and the deferred split was the weakest part of my proposal. One limit worth stating: Brain and Core run as the same macOS user, so a compromised Brain process could read user-readable files. The real boundary is that Brain holds no credentials, no TCC grants, and no executor access, and that Brain itself runs under a restrictive Seatbelt profile. Running Brain as a separate macOS user is stronger but complicates deployment; left as [open question 9](../open-questions.md).
