# 0009. Autonomous whole-Mac control with Claude computer use

Status: Accepted by Matthew
Date: 2026-10-16
Proposed by: Cursor, at Matthew's request
Supersedes: [0008](0008-reviewed-app-control.md)

## Context

After trying ADR 0008's reviewed sessions, Matthew found Nova "very stupid", limited to one app, without its own cursor or voice, and too slow because it asked before every input. Asked to choose, he selected: never ask before acting, any app with no exceptions, the iPhone's built-in voice, and Claude Sonnet with a $5 spending guard. The Bluey reference project works this way, with confirmation only before hard-to-undo steps.

Two causes made 0008 weak in practice. It used Claude Haiku with thinking disabled and a homemade one-action tool over a single downscaled window. And macOS charged Screen Recording to Core's `node` process rather than to Nova Operator, which is fixed separately by running Nova Operator as its own login item.

## Decision

- Run Anthropic's `computer_toolset_20260801` with `claude-sonnet-5-5` and adaptive thinking over the whole main display. Claude may batch actions; Core executes them in order and returns screenshots.
- Remove sessions, the app list, per-action approvals, Face ID checks, window hashes and secure-field checks. Inputs are system-wide events.
- Keep deterministic limits in Core: owner device only, emergency stop, one task at a time, 40 rounds per task, $1.50 per task, $5 lifetime allowance with per-round reservation settled from Anthropic's reported usage, and HMAC-signed single-use requests to Nova Operator.
- Add Control-Option-S and a menu item on the Mac that halt Nova Operator immediately and fail the running task.
- Computer tasks call Anthropic directly from Core. The Seatbelt-contained worker of 0008 still handles non-owner text chat. Containing the response parser no longer protects anything meaningful when the model's actions run unreviewed.

## Consequences

- AGENTS.md's constraint that "every concrete action is checked at execution time, by effect" is relaxed for computer control by Matthew's decision: actions are checked for authenticity, budget, owner and stop state, not for their effect. No model sits in that path.
- A misleading web page, email or document can steer Nova into harmful actions (prompt injection). Mitigations are the system prompt, Anthropic's screenshot classifiers, the stop controls and the spending caps. These reduce, not remove, the risk.
- Screenshots of the whole display go to Anthropic during tasks.

## Objections

- Codex's 0008 rejected "unrestricted mouse/keyboard tools immediately" because unknown effects and stale screens could bypass the user's boundaries. That objection stands on the merits. Matthew accepted the risk for usability. Reinstating confirmation only for hard-to-undo actions (Bluey's model) would be a reasonable middle ground if needed later.
