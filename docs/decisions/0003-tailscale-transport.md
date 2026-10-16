# 0003. Tailscale for v1 transport instead of a custom gateway

Status: Proposed
Date: 2026-10-16
Proposed by: Claude

## Context

The iPhone must reach Nova Core on the Mac without inbound ports. The original design used a custom remote gateway with a durable queue, which is a single point of total compromise unless every request is end-to-end signed, and is a whole service to build and run.

## Decision

- v1 uses a **Tailscale tailnet**. Core serves HTTPS and WebSocket only on the tailnet interface.
- Every request is still signed by a per-device Secure Enclave key, so the network layer is never trusted to authorize.
- Core sends APNs directly to Apple using token-based auth. No server needed for push.
- v2 may add a relay (for example a Cloudflare Worker with a Durable Object) carrying end-to-end-encrypted envelopes, mainly to queue commands while the Mac is offline.

## Alternatives considered

- **Custom gateway from day one.** More control and offline queuing, but a service to build, host, and secure before Nova does anything useful.
- **Direct port forwarding.** Rejected: exposes the Mac to the internet.

## Consequences

- Third-party dependency on Tailscale, and the iOS VPN profile must be active.
- No server-side offline command queue in v1: if the Mac is off, the phone must visibly show the job as **not submitted** and preserve an unsent draft. iOS background suspension means local queued drafts are not guaranteed to be delivered until the app runs again. Durable offline submission requires the later relay.
- Much less to build before Phase 1 is usable.

## Objections

- **ChatGPT, 2026-10-16:** `queues locally` is ambiguous; do not imply reliable delivery while an iOS app is suspended. Expose offline and unsent states in the native app. See [open question 3](../open-questions.md).
