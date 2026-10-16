# 0004. Journaled dynamic task graph instead of a DAG engine

Status: Proposed
Date: 2026-10-16
Proposed by: Claude

## Context

Matthew's revision calls for workflow DAGs with persistent state, retries, checkpoints, idempotency, and crash recovery. "Continue independent work while approval is pending" needs explicit dependencies. But LLM-driven work can't be planned as a static DAG up front: the planner learns what's needed as it goes.

## Decision

- A **dynamic task graph**: the planner proposes nodes at runtime; Core validates, journals, and schedules them.
- State lives in an **event-sourced SQLite journal** (WAL mode). No external workflow engine.
- Node states include `blocked_approval`, `blocked_resource`, and `uncertain`. A blocked node freezes only its descendants.
- Side-effecting actions are journaled as `in-flight` before execution. After a crash they become `uncertain`, and the adapter's reconcile probe checks what actually happened. If it can't tell, the action escalates to Matthew instead of retrying.

## Alternatives considered

- **Temporal or a similar durable-execution engine.** Strong guarantees, but heavy to run on a laptop and built for static workflow code, not runtime-proposed nodes.
- **Static DAG planned up front.** Rejected: doesn't match how LLM planning works.

## Consequences

- At-most-once behavior for non-idempotent effects, which needs a reconcile probe per side-effecting operation.
- The scheduler is custom code and must be tested hard, starting with the Phase 1 `kill -9` test.

## Objections

None yet.
