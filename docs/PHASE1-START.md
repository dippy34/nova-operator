# Nova Phase 1 - first working vertical slice

This is an **implementation**, not an architectural mockup. It has a native iOS SwiftUI client, a Mac-hosted Node 22 service, one-use pairing, Keychain-backed device credentials, a SQLite WAL job/event journal, a read-only task executor and a remote emergency-stop endpoint. The iOS client polls for job results while the app is in the foreground.

## Implemented / not implemented

| Today (v0.1) | Future phases |
| --- | --- |
| iPhone app pairs over HTTPS via Tailscale Serve; creates `hello`, `mac.status` and configured `repo.status` jobs | GPT/Claude planning, arbitrary tool calls, GUI operation, wake word |
| Per-device tokens, one-time pairing, SQLite journal, reboot interruption detection | Secure Enclave signed device requests, granular MissionGrants, deterministic effect-based authorization |
| Emergency stop, local-only resume | Enforced agent process/network isolation, Codex/Claude SDKs, dynamic task graph |
| Job history and details in app | APNs, push approvals, background event delivery, remote wake |

**Security limitation:** v0.1 uses a Keychain-stored bearer token via TLS/Tailscale. This is **not** the long-term per-action signed-grant security protocol. For that reason only a hardcoded **read-only task allowlist** is enabled, with no shell command input, no user-selected file paths, no desktop control, and no arbitrary agent execution. Do not expose the Node server with Tailscale Funnel or public port forwarding.

## On your Mac

Prerequisites: Node.js 22.13+ (built-in `node:sqlite`; experimental in 22), Git, Tailscale, and Xcode. No `npm install` is required for the backend.

```bash
cd nova-operator
export NOVA_WORKSPACE="$HOME/path/to/a/git/repo"  # optional, enables Repo status
npm test
npm run start
```

In another Terminal window, same repo directory:

```bash
npm run pair       # 10-minute, one-use pairing code
```

Expose the otherwise **loopback-only** server privately over HTTPS using Tailscale on Mac:

```bash
tailscale serve --bg 8787
tailscale serve status  # copy the HTTPS *.ts.net URL
```

Ensure the iPhone is signed into the **same Tailscale tailnet** (via the Tailscale iPhone app, with VPN connected). Tailscale Serve is different from Funnel; **do not enable Funnel**. Verify the command syntax against your installed Tailscale version. See [Tailscale Serve CLI documentation](https://tailscale.com/docs/reference/tailscale-cli/serve).

## Build and install the iPhone app

On the Mac, install Xcode from Apple, and optionally XcodeGen with `brew install xcodegen`. Then:

```bash
cd nova-operator/ios
xcodegen generate
open Nova.xcodeproj
```

In Xcode: select the **Nova** target, choose your Apple development team under Signing & Capabilities, connect your iPhone by cable (or use paired wireless debugging), select the iPhone as run destination, and press Run. A free Apple ID may be sufficient for a personal development install, subject to Apple's current provisioning limits.

Open the **native Nova app** (not Safari), enter the Tailscale **HTTPS URL** and the pairing code displayed on the Mac. Tap Pair. Try `Hello Nova`, `Mac status`, and `Repo status`; open each job to see its result and event history.

The iPhone app is **not compiled in this repository's automated tests** because Xcode and Apple signing are required. Swift source has only been syntax-parsed in a non-Apple environment; validate iOS compilation and signing on your Mac before considering this tested end-to-end.

## Emergency stop and recover

The **Emergency stop** button records a persistent stop flag and aborts active operations that support abort signals. New jobs are rejected until a local Mac operator runs:

```bash
npm run resume
```

For this v0.1 read-only executor, any jobs in progress when Core restarts are marked `interrupted`; they are never silently retried. This is groundwork for later side-effect reconciliation.

## Next engineering milestones

1. Verify the Mac + iPhone build and remote pairing across cellular data, not just local Wi-Fi.
2. Add Secure Enclave device signing, expiry, replay protection and action-bound MissionGrants before privileged actions.
3. Split untrusted planning into `nova-brain` and develop an enforceable executor sandbox with negative tests.
4. Integrate Codex/Claude with bounded worktrees, budgets, objective tests and verified containment.
5. Add APNs alerts, approvals and native macOS controls only after their authorization contracts are tested.
