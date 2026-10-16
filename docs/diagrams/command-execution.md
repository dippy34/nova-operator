# Command execution flow

Every action passes schema, adapter description, policy, lease, token, execution, and postcondition checks, with explicit paths for retries, drift, crashes, and approvals.

```mermaid
flowchart TD
  A["Planner proposes ToolRequest"] --> B{"Schema valid and<br/>capability in grant?"}
  B -- No --> A
  B -- Yes --> C["Router picks adapter<br/>API > CLI > AppleScript > AX > DOM > vision"]
  C --> D["Adapter describe<br/>resolve targets, derive effects"]
  D --> E{"Effect classifiable?"}
  E -- No --> E2["Mark gui.opaque in app X"]
  E -- Yes --> F
  E2 --> F["Policy: grant + effects<br/>+ taint + budgets"]
  F -- Deny --> G["Journal denial<br/>effect closed for mission"] --> A
  F -- Needs approval --> H["Freeze node + descendants<br/>queue approval, send APNs"]
  H --> H2["Scheduler runs other ready nodes"]
  H --> W["Signed approval arrives"]
  W --> W2{"Signature, hash, expiry,<br/>preconditions still valid?"}
  W2 -- No --> X["Re-plan or re-ask owner"]
  W2 -- Yes --> I
  F -- Allow --> I{"Lease available?<br/>GUI, app, repo, profile"}
  I -- No --> I2["Reschedule"] --> I
  I -- Yes --> J["Mint single-use token<br/>bound to action hash"]
  J --> K["Journal intent: in-flight<br/>+ idempotency key"]
  K --> L["Executor verifies token<br/>checks preconditions"]
  L --> M["Execute"]
  M --> N["Collect evidence<br/>read-back, DOM, file, exit code"]
  N --> O{"Postconditions met?"}
  O -- Yes --> P["Journal success, release lease"] --> Q["Next ready node"]
  O -- No --> S{"Failure class"}
  S -- Transient --> T{"Retries left?"}
  T -- Yes --> T2["Backoff"] --> L
  T -- No --> X
  S -- State drift --> U["Re-observe and re-plan"] --> A
  S -- OS or auth wall --> X
  S -- Outcome unknown --> V["Reconcile probe"]
  Z["Crash restart: replay journal<br/>in-flight becomes uncertain"] --> V
  V -- Happened --> P
  V -- Did not happen --> T
  V -- Cannot tell --> X
```
