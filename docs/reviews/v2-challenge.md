# v2 challenge to the revised plan

Written by Claude on 2026-10-16 against Matthew's revised architecture (after he discussed v1 with ChatGPT). The resulting proposal is in [`../architecture.md`](../architecture.md).

The revision fixes the right things, but effect-based policy only works when an action's effect is knowable before it runs. Raw GUI clicks and arbitrary shell commands don't meet that bar, so OS-level containment must sit under the policy engine.

## The nine proposed changes, checked

| # | Change | Verdict | Problem or qualification |
| --- | --- | --- | --- |
| 1 | Execution-time, effect-based policy | Correct, incomplete | A CGEvent click at coordinates has no knowable effect, and `bash -c "$(cat x)"` can't be classified by parsing. Back policy with sandboxes, an egress proxy, and scoped GUI grants. |
| 2 | E2E auth, signed approvals, powerless gateway | Correct | Also encrypt payloads end to end; approval requests carry screenshots, drafts, and diffs. |
| 3 | Workflow DAGs | Overstated | LLM work can't be planned as a static DAG. Use a dynamic task graph in a journaled SQLite state machine. No Temporal. |
| 4 | Capability-based routing | Correct | Prefer the most verifiable method, not just the most reliable. |
| 5 | Agent-native integrations | Correct | Agent permission hooks aren't a security boundary alone. Run agents in OS sandboxes with egress control. |
| 6 | Swift + TypeScript split | Correct, wrong boundary | The key boundary is who holds privileges, not language. |
| 7 | Hybrid intelligence | Fine, defer | Little value in v1. No model ever sits in the authorization path. |
| 8 | Outcome verification | Correct | Needs a reconcile step for side effects with unknown outcome after a crash. |
| 9 | Remote operation, battery, remote wake | Partly unachievable | Remote wake on battery over the internet has no supported mechanism. Reframe as graceful degradation. |

## Problems in the revised diagram

- Nothing stops a component from calling an executor directly after "Authorized." Executors must verify an authorization token themselves.
- Signed approvals reach Core but never re-enter the policy check. An approval should re-run policy with the approval attached, after re-checking world state.
- The planner never receives observations from execution or app state.
- Missing: desk companion, kill switch, egress proxy, secrets handling, and resource leases.

## Earlier claims, qualified

- **"Must be unlocked"** applies only to GUI work on the host. Background work continues while locked. Run locked by default; a macOS VM guest can do GUI work while the host stays locked.
- **"Route all phone traffic through a gateway"**: the Mac can send APNs itself, and a Tailscale tailnet removes the need for a custom gateway in v1.
- **"Can't use your real Chrome profile"** is true for CDP over a debugging port. An extension controller using `chrome.debugger` works in the real profile, with more power and a larger blast radius.
- **"Screen Recording re-prompts"** has varied across macOS 15.x and 26. Verify on the target OS.
- **"Agent SDK needs an API key"**: check current terms at build time.

## Unnecessary complexity to cut

- Custom gateway in v1: use Tailscale.
- General DAG engine: use a journaled dynamic graph.
- Local models in v1: add once there's cost data.
- Vision control: build last; it's the least reliable and hardest to authorize.

## Verdict

Recommended with changes: 8/10 feasibility through Phase 5, 5/10 for "operates nearly any app reliably for hours."

Before writing the first line of code:

1. Write the effect taxonomy and grant schema.
2. Draw the trust split (Core, Brain, executors, capability tokens).
3. Put OS-level containment (Seatbelt plus the egress proxy) under the policy engine.
4. Replace "DAG engine" with a journaled dynamic task graph with `uncertain` states and reconcile probes.
5. Use Tailscale instead of building a gateway.
6. Model GUI actions semantically with AX hit-testing; make `full-control` an explicit per-app grant.
7. Make the desk companion low-trust by design.
8. Build the eval harness alongside Phase 1.
