# Unattended supervision with an approval blocker

Nova fixes flaky tests with Claude Code, updates docs with Codex, opens a draft PR, and waits for approval only on the summary email, which the grant doesn't cover. The grant covers worktrees, tests, pushes to `nova/*` branches, and draft PRs.

```mermaid
sequenceDiagram
  participant O as Owner iPhone
  participant C as nova-core
  participant B as nova-brain
  participant CL as Claude Code
  participant CX as Codex

  O->>C: Signed MissionGrant + goal
  C->>B: Goal + capabilities allowed by grant
  B->>C: Graph T1 fix tests, T2 docs, T3 verify, T4 draft PR, T5 email summary
  Note over C: Static precheck flags T5 comm.send as outside grant
  par Independent work
    C->>CL: Start T1 in worktree A, sandbox + egress allowlist
  and
    C->>CX: Start T2 in worktree B, workspace-write sandbox
  end
  CL->>C: canUseTool run npm test
  C-->>CL: allow
  CX->>C: approval request fetch unknown domain
  C-->>CX: deny, effect closed
  CL-->>C: Claims done
  C->>C: T3 tests in clean checkout, 2 failures
  C->>CL: Resume with failure evidence, retry 1 of 3
  CL-->>C: Claims done
  C->>C: Tests pass, diff within path scope
  C->>C: T4 push nova/fix-flaky + draft PR, allowed
  Note over C: T5 args now concrete, recipients and body known
  C->>O: APNs approval needed for T5
  Note over C: T5 blocked, continue T6 changelog via Codex
  C->>CX: Start T6
  O->>C: Face ID signed approval bound to T5 hash
  C->>C: Verify signature, hash, expiry, PR still open
  C->>C: Send via Gmail API connector, verify in Sent
  CX-->>C: T6 done, verified
  C->>O: Mission report with evidence links
```
