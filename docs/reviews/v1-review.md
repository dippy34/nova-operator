# v1 review of the original design

Historical record. Written by Claude on 2026-10-16 against Matthew's original architecture diagram. The current design is in [`../architecture.md`](../architecture.md); some claims here were later qualified in [`v2-challenge.md`](v2-challenge.md).

## Summary

The bones are good, but where permissions get enforced is the weak point. The outbound WSS gateway, the SQLite job store, and driving Claude and Codex through the Agent SDK and Codex app-server are all smart choices.

As drawn, a clever plan, a compromised gateway, or a malicious webpage could route around the Policy Engine. A few macOS realities will also quietly break "leave it running while I'm gone."

## 1. Would it work in practice?

Partly: the transport and agent-supervision layers are proven, while broad unattended app control is an assumption.

| Claim | Status | Notes |
| --- | --- | --- |
| iPhone to gateway to Mac over an outbound WSS connection | Proven | No inbound ports needed. |
| Driving Claude and Codex through the Agent SDK and Codex app-server | Proven | These are the right interfaces. |
| Browser automation with Playwright/CDP | Proven | Needs a dedicated Chrome profile. |
| Native app control with AX and CGEvent | Proven for well-behaved apps | Unreliable for custom-drawn UIs. |
| Operate most Mac apps autonomously for hours | Assumption | Current tech doesn't reliably deliver this. |
| Continue independent work while approval is pending | Assumption | Needs a dependency model the diagram lacks. |
| Local model as the planner | Mostly assumption | Local models are weak at long-horizon computer use. |

## 2. Compatibility issues

- **Session:** AX, CGEvent, and ScreenCaptureKit only work in a logged-in, unlocked GUI session. Nova Core must be a LaunchAgent, not a LaunchDaemon.
- **TCC:** grants are tied to the code signature, so sign every build with a stable Developer ID. Screen Recording and Apple Events prompts can stall unattended runs; add a preflight check.
- **Browser:** recent Chrome blocks remote debugging on the default profile; use a dedicated Nova profile.
- **Languages:** the Agent SDK and Playwright are TypeScript/Python; AX and friends are best from Swift. Plan two processes.
- **Agent auth:** the Agent SDK needs an API key (check terms); budget for token costs.

## 3. Fundamental mistakes

1. Permission checked at plan time, not execution time.
2. Policies about tools instead of effects.
3. No approval return path.
4. The gateway is a single point of total compromise.
5. Prompt injection is the real threat model, and nothing addresses it.
6. One mouse and one keyboard: GUI actions can't run in parallel.
7. "Continue independent work" needs a task graph.

## 4. Mac apps and agent supervision

Supervising Claude and Codex: yes, with worktrees, policy wired into their permission hooks, objective "done" checks, and budgets. Operating "most Mac apps": no, but many, with a capability ladder. AX fails on custom-drawn UIs, and system authentication dialogs are blocked by design.

## 5. Missing components

Capability ladder, postcondition verification, durable workflow engine, kill switch, secrets handling, rollback, watchdog, observability, context management, eval harness.

## 6. Rating

| Scope | Feasibility |
| --- | --- |
| Architecture as designed | 6/10 |
| Core: supervise Claude and Codex, browser, scripted apps | 8/10 |
| Operates most Mac apps unattended for hours | 3/10 |

Recommendation: keep the topology, rework the trust model, add the capability ladder and a durable workflow engine, and narrow v1 to agent supervision and CLI tasks.
