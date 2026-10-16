# 0008. Human-reviewed app control with a contained Brain

Status: Proposed
Date: 2026-10-16
Proposed by: Codex

## Context

Matthew explicitly requested enabling general mouse, keyboard and screen control. Arbitrary shell execution and unattended unknown-effect GUI operations cannot be enabled merely by exposing a model tool. The original API worker shared the user's filesystem and network permissions.

## Decision

Implement the bounded, reviewed session protocol in [Computer control](../COMPUTER-CONTROL.md). A locally designated paired owner starts a 20-minute session in one supported app and consents to sharing that window with Anthropic. Every proposed input requires an exact, expiring, single-use phone approval. No unattended-input bypass exists. Core derives a `gui.opaque(selected app)` action and binds its target/arguments to an authenticated native request; the model never authorizes an effect. High-impact or uncertain GUI semantics remain subject to human review; a system prompt is not treated as an enforcement mechanism.

Move API credentials and provider billing calculation into Core's fixed endpoint broker. Run the model-request worker in Seatbelt with denied network, Mach lookups, file writes, subprocesses and user/credential file reads. Retain the inherited IPC provider route. Require negative probes on this Mac before enabling the owner. No fallback to an uncontained worker. The privileged native executor is separate, signed, accepts a narrow authenticated protocol, checks frontmost app/window/screen again, hit-tests pointer input, and directs key events to the selected PID.

## Alternatives considered

- Unrestricted mouse/keyboard tools immediately: rejected as implementation scope; unknown effects and stale screens could bypass the user's boundaries.
- Only app opening: insufficient for Matthew's explicit selection of general mouse/keyboard/screen control.
- Full unattended per-app grants: deferred. This iteration requires review of each input, rather than asserting that its effect can be reliably inferred.
- VM containment: remains a fallback if Seatbelt probes fail on a future OS. No claim that the deprecated CLI is a permanent supported production API.

## Consequences

The first version is slower and can reject changing screens because it hashes the reviewed pixels. Native screen/input behavior still needs a live smoke test, separately from protocol tests. It does not implement per-request Secure Enclave signatures, a cryptographically distinct approval channel, executor peer-code-signature validation, complete secret redaction, or resistance to a malicious same-account local process. LocalAuthentication protects the normal native approval UI; Core still authenticates its API with the prototype paired bearer credential over private TLS/Tailscale.

The constrained Brain boundary is tested; privileged Core and the native executor remain trusted. Exact GUI checks have a residual check-to-event race and cannot constrain every possible effect caused by an approved input within an app. Therefore this is reviewed general control, not an autonomous effect-classification system. Unrestricted shell/coding agents and unattended consequential operations remain disabled.

## Objections

None recorded. Proposed long-term architecture statuses are unchanged.
