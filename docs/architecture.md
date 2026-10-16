# Nova architecture (proposed, v2)

Status: **Proposed.** Not yet accepted by Matthew. See [`decisions/`](decisions/) for the individual choices and their status.

The brain can propose anything, only Core can authorize, and only token holders can act. Effect-based policy decides what's allowed; verified OS-level containment must prevent bypass. Until tested, do not claim sandbox or network-policy enforcement is complete.

## 1. Trust tiers

This follows the privileged-planner, quarantined-reader pattern from prompt-injection research such as DeepMind's CaMeL.

| Tier | Component | Trusted for |
| --- | --- | --- |
| Owner | Primary iPhone, Secure Enclave key gated by Face ID | Grants, approvals, kill switch |
| Low-trust client | Desk companion iPhone | Status display and voice requests. Never approvals, since anyone in the room can talk to it. |
| Trusted core | `nova-core` | Policy, scheduling, journal, approvals, capability tokens, secret references |
| Untrusted reasoning | `nova-brain` | Planning only. Assume prompt injection can steer it at any time. |
| Trusted executors | `nova-operator`, browser worker, agent runner, shell runner, connectors | Executing only token-bearing actions and reporting evidence |
| Contained | Claude Code, Codex, web content, email, documents | Nothing. Sandboxed; output treated as data. |

## 2. Processes on the Mac

User-session GUI helpers run as LaunchAgents. Background services may use other launchd arrangements as appropriate, but a LaunchDaemon cannot directly operate the user's GUI. Privilege and OS containment boundaries matter more than the implementation language.

1. **`nova-core`** (TypeScript/Node). Remote API on the tailnet, signature verification, approval manager, policy engine (Cedar via WASM, or a hand-rolled deterministic evaluator), scheduler, SQLite journal in WAL mode, token minter, APNs sender, budgets, kill switch. Small and boring on purpose.
2. **`nova-brain`** (TypeScript, separate process). Planner loop, model router, context and memory. No executor credentials, no TCC grants; talks only to Core.
3. **`nova-operator`** (Swift). The only binary holding Accessibility and Screen Recording grants. Does AX, ScreenCaptureKit, CGEvent, AppleScript/JXA, and `shortcuts run`. Verifies tokens and checks each IPC peer's code signature.
4. **Browser worker** (Node + Playwright). Dedicated Nova Chrome profile with its own `--user-data-dir`. Real-profile control via an extension using `chrome.debugger` is a later opt-in, with more power and a larger blast radius.
5. **Agent runner** (Node). Claude Code via the Claude Agent SDK; Codex via app-server (JSON-RPC over stdio) or the Codex SDK. One git worktree per agent.
6. **Shell runner.** Runs in a target-macOS-tested isolation boundary with restricted credentials and filesystem writes. `sandbox-exec` is deprecated and is **not accepted as a proven production boundary** by itself. Evaluate OS-supported sandboxing, restricted accounts, or a VM; block unsafe execution until containment is proven.
    - **Primary candidate: a kernel-enforced Seatbelt profile.** Despite the deprecation notice on the `sandbox-exec` CLI, Seatbelt is the macOS mechanism that shipping agent sandboxes rely on today, including the Codex CLI and Claude Code sandboxes (verify current versions). The profile is default-deny for file writes outside the task's worktree and scratch directory, and for reads of credential locations (`~/.ssh`, Keychain files, browser profiles).
    - **Fallback: a macOS VM** (Virtualization.framework) if negative tests fail or Apple removes the mechanism. Heavier, but a hard boundary.
7. **Enforced network boundary.** A per-mission egress allowlist must constrain *all* agent traffic, not merely set a proxy environment variable. Verify that direct socket connections, DNS, `curl`, child processes, browsers and agent tools cannot route around it. Use a tested VM/network boundary or appropriately entitled OS-level enforcement if necessary; otherwise, disable unverified network permissions.
    - **Mechanism:** the same Seatbelt profile denies all outbound network except one localhost port, where the egress proxy listens. The kernel enforces that rule, so a process that ignores `HTTPS_PROXY` or opens a raw socket simply fails to connect. The proxy resolves DNS itself, so sandboxed processes need no direct DNS access.
    - **Proof required:** the Phase 2 negative tests (raw sockets, direct IP, DNS, subprocesses, ignored proxy variables) must pass on Matthew's macOS version before any network permission is granted unattended.

**IPC:** JSON-RPC 2.0 over Unix domain sockets. Each server checks the peer's PID, then its code signature. Avoid XPC unless needed, since it's awkward from Node.

**Code signing:** TCC grants are tied to the code signature. Sign every build with a stable Developer ID from day one, or rebuilds silently reset grants. Distribute as a notarized Developer ID app; App Store sandboxing forbids controlling other apps.

**Trust boundary:** `nova-brain` runs outside the authorization process from Phase 1. Both reviewers agree; the cost is small and it removes the riskiest temporary shape. A module boundary in one Node process is **not** a security boundary: model-driven tool orchestration could still call privileged APIs if compromised. Separate processes help but require OS-level credentials and IPC permissions isolation, not just separation by name. Executor token verification exists from day one. See the trust-boundary ADR.

## 3. Contracts between planner, policy, scheduler, and adapters

Six objects carry every action from proposal to evidence. Effects are always derived by code, never claimed by the LLM.

| Object | Produced by | Contents |
| --- | --- | --- |
| `MissionGrant` | iPhone, signed | Scopes (apps, domains, paths, repos, recipients), allowed effects, limits (counts, spend, time), expiry, GUI mode per app (`semantic` or `full-control`) |
| `ToolRequest` | Brain | Intent, capability name, arguments, task node. No raw secrets, no tokens. |
| `ActionDescriptor` | Adapter `describe()`, run in Core | Resolved targets, code-derived effects, preconditions, postconditions, idempotency class, taint sources |
| `Decision` | Policy engine | `allow`, `deny`, `needs_approval`, or `needs_resource`, plus the matched rule |
| `CapabilityToken` | Core | Single use, seconds of lifetime, bound to the `ActionDescriptor` hash and one executor |
| `Evidence` | Executor | Result plus read-back state (AX values, DOM, file hashes, exit code) and screenshot or diff references |

### The loop

1. The Brain proposes a `ToolRequest`.
2. Core picks an adapter using the capability ladder: API, then CLI, then AppleScript/Shortcuts, then AX, then browser DOM, then vision. Prefer the most *verifiable* rung, not just the most reliable. The adapter describes the action.
3. Policy decides. The scheduler checks leases and budgets.
4. Core journals the intent and mints a token. The executor verifies the token and acts.
5. Core checks postconditions, journals the outcome, and returns the observation to the Brain.

### Effect taxonomy

Kept deliberately small:

`read.local`, `write.local(path)`, `delete.local(path)`, `exec.sandboxed`, `net.read(domain)`, `comm.send(recipient)`, `publish`, `purchase`, `auth.change`, `system.config`, `agent.spawn`, `gui.semantic(app, element)`, `gui.opaque(app)`.

A `deny` closes that effect for the rest of the mission, whichever tool tries to cause it.

### GUI actions

- The operator hit-tests every click, including vision-chosen ones, with `AXUIElementCopyElementAtPosition`. Policy sees "click AXButton 'Send' in Mail," not coordinates.
- If AX returns nothing (a custom canvas), the action becomes `gui.opaque(app)`, allowed only with a `full-control` grant for that app.
- A model may help *escalate* an opaque action ("this looks like a send button") but may never *permit* one.

### Taint tracking

- External pages, messages, repository files and agent output are **untrusted observations**, never instructions that can expand a mission grant.
- Do not automatically cancel every preapproved consequential action merely because a workflow read untrusted data: that would defeat unattended autonomy. Instead, bind permissions to exact targets, effect classes, destinations, rates and budgets; require independent postcondition and provenance checks before permitted actions.
- When untrusted content attempts to modify instructions, recipients, destinations, command scope or authorization, quarantine the proposal and request a fresh, narrowly scoped approval. Unknown-effect actions fail closed.
- **Deterministic trigger** (so no model has to judge whether content "attempts" anything): every target-bearing argument (recipient, domain, path, repo, branch, payee) is checked against the grant.
    - **Pinned target:** the grant names this exact target (`comm.send` to `team@example.com`). Allowed even from a tainted context, subject to budgets and postconditions. Injection can change the message body, but not where it goes.
    - **Unpinned target:** the grant uses a pattern or wildcard (`comm.send` to `*@example.com`), and the context is tainted. Needs approval.
    - **Residual risk:** a tainted context can still put sensitive data in the body of a message to a pinned recipient. Executors scan outbound payloads for secret references and known credential formats before sending.
- See [ADR 0006](decisions/0006-pinned-target-taint-policy.md).
- This is a proposed policy, **not a solved prompt-injection defense**. Include adversarial tests before allowing `comm.send`, `publish` or destructive actions unattended. The effect policy is pinned at mission start.

## 4. Scheduler

A journaled **dynamic task graph**, not a static DAG and not a general workflow engine. The planner proposes nodes at runtime; Core validates and journals them.

- **Node states:** `pending`, `ready`, `running`, `blocked_approval`, `blocked_resource`, `uncertain`, `succeeded`, `failed`, `cancelled`.
- **Leases:** one global GUI lease, plus per-app, per-repo, and per-browser-profile leases. GUI work runs single-file; everything else parallelizes. If Matthew touches the keyboard or mouse (HID idle time resets), the GUI lease is revoked and the operator pauses.
- **Blocking:** a blocked node freezes only its descendants.
- **Approvals:** requested as soon as an action's arguments are concrete, so they may arrive before the work needs them. An arriving approval re-runs policy with the approval attached, after re-checking preconditions.
- **Budgets:** token, time, retry, and spend budgets per mission and per node. Stuck-loop detection: the same failure N times means stop and ask.
- **Kill switch:** one tap on the phone or a local hotkey halts all executors. Externally visible actions are rate-limited.

### Crash semantics

- On restart, Core replays the journal.
- Side-effecting actions left `in-flight` become `uncertain`. The adapter's reconcile probe checks what actually happened (Sent folder, remote branch, file hash).
- If the probe can't tell, the action escalates to Matthew rather than retrying. That gives at-most-once behavior for non-idempotent effects.

## 5. Agent supervision

- Each agent works in its own git worktree.
- Nova's policy is wired into the agents' own permission hooks: `canUseTool` and hooks in the Agent SDK; approval and sandbox policy in Codex. Running either with "bypass permissions" deletes the policy engine in practice.
- Agent hooks are not a security boundary by themselves. Agents must also run inside a verified containment boundary with genuinely enforced filesystem and network restrictions. A proxy configured by convention does not provide this guarantee.
- "Done" is judged by objective checks (tests pass in a clean checkout, build succeeds, diff stays in scope), never by the agent saying it's done.

## 6. Remote, device, and model layer

- **Transport.** v1: a Tailscale tailnet, with Core serving HTTPS and WebSocket only on the tailnet interface. The native iPhone app needs its tailnet connection active; when Core is offline, it should show disconnected and preserve unsent drafts, not promise background delivery from a suspended iOS process. v2: an optional relay (for example a Cloudflare Worker with a Durable Object) carrying end-to-end-encrypted envelopes, to queue commands while the Mac is offline. The relay can relay but never forge.
- **Authentication.** Every request is signed with a per-device P-256 key in the Secure Enclave. Approval and grant keys require Face ID (`.biometryCurrentSet`). Requests carry a nonce, a timestamp, and the target action hash. Core keeps allowlisted public keys and per-device roles. App Attest on the iPhone app.
- **Push.** Core sends APNs itself, with minimal payloads ("approval needed"). The app fetches details over the tailnet. Live Activities show long-running mission status.
- **Desk companion.** Foreground app with Guided Access and auto-lock off. On-device speech (`SpeechAnalyzer` on iOS 26, or `SFSpeechRecognizer`). Its own wake-word detector, since iOS has no API for custom always-on wake words. Observer role key: Core rejects every approval from it.
- **Models.** A frontier cloud model plans. A computer-use-capable model does vision grounding. A local model (Apple Foundation Models framework or MLX) handles classification, summarization, and screenshot change detection. None of them sit in the authorization path.

## 7. Power and lock state

- Run with the screen **locked by default**. CLI, agents, APIs, and headless browser work continue while locked, as long as the Mac is awake and the user is logged in.
- Host GUI work needs an unlocked session. Missions that need the GUI either require Matthew to leave it unlocked, or run in a macOS VM guest whose session is independent of the host lock.
- Core holds a power assertion to prevent idle sleep. On battery, Nova checkpoints and pauses before sleep instead of trying to stay awake. Remote wake on battery is not a design goal (see [`limitations.md`](limitations.md)).

## 8. Supporting components

| Component | What it does |
| --- | --- |
| Postcondition verification | Each action declares its expected state; the verifier checks it |
| Secrets handling | Credentials live in the Keychain and are injected at the executor; the model never sees raw secrets |
| Rollback | Git for code; an APFS local snapshot (`tmutil localsnapshot`) before risky file operations |
| Watchdog and health | LaunchAgent `KeepAlive`, heartbeat to the phone, alerts for low disk, thermal throttling, or a stalled GUI |
| Preflight | Before each mission, verify every TCC grant and dependency; fail loudly if anything is missing |
| Observability | A screenshot and AX snapshot per GUI action, so any run can be replayed |
| Context and memory | Summarization, a scratchpad, and task notes in the database instead of an ever-growing prompt |
| Eval harness | Repeatable missions rerun after every change, built alongside Phase 1 |
