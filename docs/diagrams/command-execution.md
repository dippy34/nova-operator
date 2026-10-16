# Command execution flow

Every concrete action is described, authorized **at execution time**, journaled, executed with a fresh single-use capability token, and verified. An owner approval is not a bypass: Core verifies it, re-describes the action if needed, and **re-runs policy with the approval attached**.

Retries of side-effecting actions are never sent straight back to an executor. Known-safe retries re-enter descriptor resolution, policy, resource checks, and token minting. Unknown outcomes go through reconciliation first.

```mermaid
flowchart TD
  A["Brain proposes ToolRequest"] --> B{"Schema valid?<br/>Capability in grant?"}
  B -- No --> BX["Reject and journal reason"]
  B -- Yes --> C["Select verifiable adapter<br/>API / SDK / CLI / script / DOM / AX / vision"]
  C --> D["Adapter describes concrete action<br/>target, effects, conditions, provenance"]
  D --> E{"Can effect and boundary<br/>be enforced?"}
  E -- No --> EH["Deny or request narrower<br/>scoped execution method"]
  E -- Yes --> F["Deterministic policy evaluation<br/>grant + effect + provenance + budgets"]
  F -- Deny --> G["Journal denial; close effect<br/>within current mission"]
  F -- Needs approval --> H["Journal blocked action and<br/>exact descriptor hash"]
  H --> HA["Run independent ready nodes;<br/>keep descendants blocked"]
  H --> I["Notify owner via APNs"]
  I --> J["Owner returns signed,<br/>time-limited action approval"]
  J --> K{"Signature, owner role,<br/>hash, nonce, expiry valid?"}
  K -- No --> KB["Reject approval;<br/>remain blocked / re-request"]
  K -- Yes --> KC["Re-observe target and<br/>re-describe if state changed"]
  KC --> KD{"Action hash and<br/>preconditions unchanged?"}
  KD -- No --> KB
  KD -- Yes --> F2["Re-run policy with<br/>verified approval attached"]
  F2 -- Deny or re-approve --> KB
  F2 -- Allow --> L
  F -- Allow --> L{"Resource leases and<br/>budgets available?"}
  L -- No --> LA["Wait / requeue node"]
  LA --> L
  L -- Yes --> M["Journal attempt as in-flight<br/>with idempotency/reconcile metadata"]
  M --> N["Mint fresh single-use token<br/>bound to descriptor + executor + attempt"]
  N --> O["Executor verifies token and<br/>preconditions; then executes"]
  O --> P["Collect evidence and<br/>read back target state"]
  P --> Q{"Postcondition confirmed?"}
  Q -- Yes --> R["Journal succeeded;<br/>release leases; next ready node"]
  Q -- No --> S{"Outcome known?"}
  S -- No --> U["Mark uncertain;<br/>run reconcile probe"]
  S -- Yes, no effect --> V{"Transient and<br/>within retry budget?"}
  S -- Yes, effect occurred --> W["Record partial effect;<br/>reobserve/replan"]
  V -- Yes --> X["Release lease; backoff;<br/>reobserve and create NEW attempt"]
  X --> C
  V -- No --> W
  W --> A
  Z["Restart after crash:<br/>in-flight becomes uncertain"] --> U
  U --> AA{"Probe result"}
  AA -- Effect verified --> R
  AA -- Definitely not applied --> X
  AA -- Unknown --> AB["Stop this node; escalate to owner;<br/>never blindly repeat side effect"]
```

## Invariants for implementers

1. Approval validates a **specific canonical ActionDescriptor**, not just a high-level intent. If the recipient, payload, target, or preconditions change, the owner must approve the new action.
2. The approval re-enters the policy engine. Owner approval can satisfy an approvable rule; it cannot override a hard deny or an OS authentication barrier.
3. Capability tokens are **single-use and attempt-bound**. A retry must be freshly described, authorized, journaled, and tokenized.
4. The executor checks the token itself; the tool router is not the enforcement boundary. Restrict direct executor entry points.
5. A postcondition failure is not automatically proof an action failed. Especially for sends, pushes, purchases, and deletes, an uncertain outcome requires a read-back/reconcile probe or human resolution.
6. A policy deny closes an **effect**, not every alternative implementation of a permitted goal. An out-of-scope effect cannot be retried via another tool.
7. The graph shows the logical protocol, not proof of macOS process or network containment; enforcement must pass the tests in the roadmap.
