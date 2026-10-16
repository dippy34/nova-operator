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

In v1, Core and Brain may share a process with a strict module boundary. They split into separate processes before Phase 5.

## Alternatives considered

- **Single process, policy as a library call.** Simplest, but a planner bug or injected instruction is one function call away from the executors. Acceptable only as a temporary v1 shape.
- **LLM-judged authorization.** Rejected outright: a model in the authorization path can be argued with.

## Consequences

- Every executor needs token verification from day one.
- Adds IPC and a token format, a small, well-understood cost.
- The privileged surface is small enough to audit.

## Objections

None yet.
