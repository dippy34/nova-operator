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

Prerequisites: Node.js 22.13+ (built-in `node:sqlite`; experimental in 22), Git, Tailscale, and full Xcode for iOS builds. Apple's Command Line Tools alone cannot build an iPhone app. No `npm install` is required for the backend.

```bash
cd nova-operator
export NOVA_WORKSPACE="$HOME/path/to/a/git/repo"  # optional, enables Repo status
npm test
npm run start
```

For persistent use on macOS, run `npm run service:install` **instead of** `npm run start`. This installs a per-user LaunchAgent named `dev.nova.operator.core`, starts Core now, and restarts it after crashes and at login. It uses this checkout as its working directory, stores its database and logs in `.nova-data/`, and defaults Repo status to this repository. Keep the checkout in place. Set `NOVA_DB`, `NOVA_WORKSPACE`, or `NOVA_PORT` before installation to override them; use the same `NOVA_DB` for pairing and resume commands.

Use `npm run service:status` to inspect the service and `npm run service:remove` to stop and remove it while preserving saved data. A login service does not keep a sleeping Mac reachable and does not run before the user logs in. Shutdown handles SIGINT and SIGTERM and waits for abort-aware work before closing SQLite. Core refuses non-loopback bind addresses.

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

The standalone Mac app also exposes its CLI at `/Applications/Tailscale.app/Contents/MacOS/Tailscale` if `tailscale` is not on PATH. Approve its network extension and sign in first. If Serve asks to enable HTTPS, complete that tailnet setting; never substitute an insecure certificate override or Funnel.

## Build and install the iPhone app

Open the checked-in `ios/Nova.xcodeproj` directly. XcodeGen is optional; `ios/project.yml` remains the source for regenerating the project after structural changes:

```bash
cd nova-operator/ios
xcodegen generate
open Nova.xcodeproj
```

Check [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements) before downloading. On the Mac inspected on 2026-10-16 (macOS 26.5.1), Xcode 26.6 is compatible; the current App Store Xcode 27.1 requires macOS 26.6. A compatible older version is available through [Apple Developer Downloads](https://developer.apple.com/download/all/?q=Xcode), with Apple sign-in.

In Xcode: select the **Nova** target, choose your Apple development team under Signing & Capabilities, connect your iPhone by cable (or use paired wireless debugging), select the iPhone as run destination, and press Run. A free Apple ID may be sufficient for a personal development install, subject to Apple's current provisioning limits.

Unlock the iPhone and accept its computer-trust prompt. Enable [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/) if Xcode requires it; that involves a device restart and confirmation on the phone. Select a unique bundle identifier if your signing team cannot provision `dev.nova.operator`. Do not commit personal signing/team changes.

An unsigned compile can be checked after full Xcode and the iOS platform are installed:

```bash
xcodebuild -project ios/Nova.xcodeproj -scheme Nova \
  -destination 'generic/platform=iOS' -derivedDataPath .DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Open the **native Nova app** (not Safari), enter the Tailscale **HTTPS URL** and the pairing code displayed on the Mac. Tap Pair. Try `Hello Nova`, `Mac status`, and `Repo status`; open each job to see its result and event history.

The iPhone app is **not compiled in the Node tests**. Swift source has been syntax-parsed on the Mac, and the Xcode project has been generated and plist-validated. Full iOS compilation requires Xcode and its iOS platform; device installation additionally requires signing. Do not call this tested end-to-end until the native app pairs and receives a Mac result on the phone. HTTP redirects are rejected, and authenticated requests use the saved paired server address to avoid forwarding credentials to a changed address.

## Verification on Matthew's Mac — 2026-10-16

- Verified `942057e2ad85165ef09bd1199bd50256cfb228ee` exists and was the clean `origin/main` head at checkout.
- Node 24.19.0; nine backend tests pass, including actual database reopen, expired/reused pairing, cross-device isolation, revocation, shutdown, failed duplicate listener, loopback binding, and repository hook suppression.
- Installed Core as a user login service and exercised real `hello`, `mac.status`, and `repo.status` HTTP jobs. Verified automatic restart after SIGTERM, persisted credentials/results/stop flag, local resume, and test-device revocation. No test credential was retained.
- Repository status disables fsmonitor hooks and optional index writes, and skips submodule traversal. See [Git's status documentation](https://git-scm.com/docs/git-status) for why the default command can refresh the index and invoke fsmonitor.
- Tailscale 1.104.1 installed from its official package server; checksum and notarized signature verified. Network extension activated. Account login and private HTTPS Serve configuration still pending at this checkpoint.
- Native iOS project generated with XcodeGen 2.46.0; shared scheme/workspace XML validated. `NovaModel.swift` passes `swiftc -typecheck` against the Mac SDK, which checks the networking/model code but is not an iOS build. Full Xcode, signing, connected-device installation, and phone-to-Mac pairing remain pending at this checkpoint. The face is a static placeholder; voice, animated companion, AI planning, and computer control are not implemented.

## Emergency stop and recover

The **Emergency stop** button records a persistent stop flag and aborts active operations that support abort signals. New jobs are rejected until a local Mac operator runs:

```bash
npm run resume
```

For this v0.1 read-only executor, any jobs in progress when Core restarts are marked `interrupted`; they are never silently retried. This is groundwork for later side-effect reconciliation.

To revoke a lost or unpaired phone on the Mac, run `node core/cli.mjs devices`, then `node core/cli.mjs revoke DEVICE_ID` using the listed ID. The iPhone's Unpair button removes its local Keychain credential; use local revocation to invalidate that credential on Core too. No plaintext tokens are printed by these commands.

## Next engineering milestones

1. Verify the Mac + iPhone build and remote pairing across cellular data, not just local Wi-Fi.
2. Add Secure Enclave device signing, expiry, replay protection and action-bound MissionGrants before privileged actions.
3. Split untrusted planning into `nova-brain` and develop an enforceable executor sandbox with negative tests.
4. Integrate Codex/Claude with bounded worktrees, budgets, objective tests and verified containment.
5. Add APNs alerts, approvals and native macOS controls only after their authorization contracts are tested.
