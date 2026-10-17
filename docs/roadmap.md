# Roadmap

For current implementation priorities and tested beta gates, use [BETA-PLAN.md](BETA-PLAN.md) and [HANDOFF.md](HANDOFF.md). The phases below describe the long-term design; they are not a list of implemented or verified capabilities.

Ten phases, easiest to hardest. Phases 1 to 3 already give a genuinely useful Nova: an operator that supervises Claude and Codex unattended, runs sandboxed CLI work, and asks for approval from the phone.

| Phase | Deliverables | Depends on | Acceptance tests |
| --- | --- | --- | --- |
| 0. Specification | Threat model, containment options and negative-test plan, effect taxonomy, `MissionGrant` schema, `ToolRequest`/`ActionDescriptor`/`Evidence` schemas, journal event schema, device roles | None | Every Phase 1 to 3 capability maps to taxonomy effects. A written walk-through shows where an injected email, a compromised relay, and an agent using curl are each stopped. |
| 1. Secure core and phone control | Separate trusted `nova-core` and untrusted `nova-brain` processes, iPhone app with device keys, Tailscale transport, contained shell runner, enforced network restrictions or a documented blocked capability, journal, kill switch, APNs, eval harness skeleton | 0 | Tampered or replayed requests rejected. Expired approvals rejected. Approvals for altered arguments rejected. Out-of-grant actions denied. Kill switch halts executors within 2 s. `kill -9` mid side effect causes no duplicate after restart (tested against a counting endpoint). |
| 2. Agent supervision | Agent runner for Claude Code and Codex, worktrees, sandbox settings, hook-to-policy wiring, acceptance checks, stuck detection, budgets | 1 | At least 8 of 10 benchmark repo tasks pass tests unattended. Non-allowlisted agent network calls blocked by tested enforcement, including direct sockets, subprocesses, DNS, and attempts to ignore proxy variables. Push to `main` denied. A deliberately looping task is stopped within budget. |
| 3. Approval-blocked continuation | Dynamic task graph, blocked states, early approval requests, re-validation on resume | 2 | In a 6-node mission where node 3 needs approval: independent nodes finish, dependents wait, everything completes after approval. Changed preconditions trigger a re-ask instead of execution. |
| 4. Browser tier | Browser worker, DOM postconditions, domain-scoped grants | 1 | At least 90% success on 20 scripted web tasks. A prompt-injection test page can't cause `comm.send`. |
| 5. Native tier | `nova-operator` holding TCC grants, AppleScript/Shortcuts adapters, AX adapters for the top 5 apps, GUI lease, user-activity pause, preflight, verify existing Core/Brain process separation | 3, 4 | Per-app suites pass at 90% or better. Typing on the Mac pauses Nova within 500 ms. A missing TCC grant fails preflight before the mission starts. |
| 6. Desk companion | Character display, voice requests, observer role | 1 | Core rejects every approval from the desk device (not just hidden in the UI). Voice-to-acknowledgment latency under 1.5 s. |
| 7. Vision tier and GUI VM | Screenshot grounding, AX hit-testing of vision clicks, `gui.opaque` policy, macOS guest VM with its own operator | 5 | Measured success rates on custom-UI tasks. Opaque actions denied without a `full-control` grant. A GUI mission completes in the VM while the host stays locked. |
| 8. Hybrid models and cost | Local model routing for classification and summarization | Eval harness | At least 30% cost reduction with no regression on the eval suite. |
| 9. Power resilience | Battery policy (checkpoint and pause before sleep), scheduled wakes, offline command queue on a relay | 1 | Pulling AC power mid-mission produces a clean checkpoint and an owner notification; the mission resumes cleanly after wake. |

## Feasibility

- **8/10** through Phase 5.
- **5/10** for "operates nearly any app reliably for hours." That remains a model reliability problem no architecture fully fixes.
