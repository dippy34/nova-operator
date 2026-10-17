# Nova Phase 1 - first working vertical slice

For the current install path (QR pairing, range, Keychain keys), start at [Set up Nova](SETUP.md). This page is the original Phase 1 checkpoint.

This is an **implementation**, not an architectural mockup. It has a native iOS SwiftUI client, a Mac-hosted Node 22 service, one-use pairing, Keychain-backed device credentials, a SQLite WAL job/event journal, a read-only task executor and a remote emergency-stop endpoint. The iOS client polls for job results while the app is in the foreground.

## Implemented / not implemented

**Reviewed computer control addition:** [App-scoped Mac sessions](COMPUTER-CONTROL.md) now implement screen capture and reviewed mouse/keyboard input. The Brain runs in a negatively tested OS sandbox and uses Core's API broker. This expands the earlier read-only/text-only checkpoints below; unrestricted unattended control and coding-agent supervision remain disabled. The current verification checkpoint is maintained in the computer-control guide.

**Claude chat addition:** The native client and Core now include bounded text-only Claude conversation. See [Claude setup and cost controls](CLAUDE-SETUP.md). The signed update built and installed on Matthew's iPhone, and all 15 backend tests passed. A real authenticated job through running Core returned a Haiku 5.5 reply using 156 input / 18 output tokens (estimated $0.000025). Its temporary setup credential was revoked. Matthew then confirmed native phone chat works; Core independently recorded the paired iPhone's successful Claude request (134 input / 25 output tokens, estimated $0.000026). This verifies the native phone-to-Claude round trip. It does not enable AI planning or computer control.

| Today (v0.1) | Future phases |
| --- | --- |
| iPhone app pairs over HTTPS via Tailscale Serve; creates `hello`, `mac.status` and configured `repo.status` jobs | GPT/Claude planning, arbitrary tool calls, GUI operation, wake word |
| Per-device tokens, one-time pairing, SQLite journal, reboot interruption detection | Secure Enclave signed device requests, granular MissionGrants, deterministic effect-based authorization |
| Emergency stop, local-only resume | Enforced agent process/network isolation, Codex/Claude SDKs, dynamic task graph |
| Job history and details in app | APNs, push approvals, background event delivery, remote wake |

**Security limitation:** v0.1 uses a Keychain-stored bearer token via TLS/Tailscale. This is **not** the long-term per-action signed-grant security protocol. Only hardcoded read-only checks and bounded text-only chat are enabled, with no shell command input, no user-selected file paths, no desktop control, and no arbitrary agent execution. Model replies are displayed, never executed. Do not expose the Node server with Tailscale Funnel or public port forwarding.

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

Sign in under Xcode Settings → Apple Accounts. Keep your personal signing team out of Git: create `ios/Signing.local.xcconfig` containing `DEVELOPMENT_TEAM = YOUR_TEAM_ID`. The tracked `Config.xcconfig` optionally includes that ignored file for Debug and Release. Alternatively, select your team in Signing & Capabilities, but do not commit the resulting personal project changes. Connect your iPhone, select it as the run destination, and press Run. A free Apple ID may be sufficient for a personal development install, subject to Apple's current provisioning limits.

Unlock the iPhone and accept its computer-trust prompt. Enable [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/) if Xcode requires it; that involves a device restart and confirmation on the phone. Select a unique bundle identifier if your signing team cannot provision `dev.nova.operator`. Do not commit personal signing/team changes.

If iOS refuses the first launch of an installed development build, check Settings → General → VPN & Device Management and trust your own Developer App profile. Verify that the profile belongs to your signing account. Personal Team profiles expire; the profile issued during this setup expires on 2026-10-23, after which the app must be signed and installed again.

An unsigned compile can be checked after full Xcode and the iOS platform are installed:

```bash
xcodebuild -project ios/Nova.xcodeproj -scheme Nova \
  -destination 'generic/platform=iOS' -derivedDataPath .DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Open the **native Nova app** (not Safari), enter the Tailscale **HTTPS URL** and the pairing code displayed on the Mac. Tap Pair. Try `Hello Nova`, `Mac status`, and `Repo status`; open each job to see its result and event history.

The iPhone app is **not compiled in the Node tests**. Full unsigned and device-signed iOS builds have succeeded on Matthew's Mac. The native app is installed, paired, and has successfully requested Mac status, repository status, and hello jobs on his iPhone 13. Additional Mac status jobs succeeded after the USB cable was unplugged. This verifies the Wi-Fi/Tailscale connection; cellular operation has not yet been tested. HTTP redirects are rejected, and authenticated requests use the saved paired server address to avoid forwarding credentials to a changed address.

For local setup, Debug builds accept `NOVA_SETUP_URL` and `NOVA_SETUP_CODE` in their launch environment to prefill pairing on an unpaired phone. They still require a tap on Pair Nova, validate the HTTPS URL normally, and redeem a normal ten-minute, one-use invitation. These inputs are not saved until successful pairing and are ignored by Release builds. Never print or commit the pairing code; supply it through the developer launch environment, not a source change.

## Verification on Matthew's Mac — 2026-10-16

- Verified `942057e2ad85165ef09bd1199bd50256cfb228ee` exists and was the clean `origin/main` head at checkout.
- Node 24.19.0; nine backend tests pass, including actual database reopen, expired/reused pairing, cross-device isolation, revocation, shutdown, failed duplicate listener, loopback binding, and repository hook suppression.
- Installed Core as a user login service and exercised real `hello`, `mac.status`, and `repo.status` HTTP jobs. Verified automatic restart after SIGTERM, persisted credentials/results/stop flag, local resume, and test-device revocation. No test credential was retained.
- Repository status disables fsmonitor hooks and optional index writes, and skips submodule traversal. See [Git's status documentation](https://git-scm.com/docs/git-status) for why the default command can refresh the index and invoke fsmonitor.
- Tailscale 1.104.1 installed from its official package server; checksum and notarized signature verified. Network extension activated, account signed in, and Mac confirmed online. User-approved HTTPS Serve is running persistently with no Funnel configuration. Tested valid TLS, unauthenticated rejection, pairing, and a Mac status job via the private HTTPS address from the Mac. This does not prove phone/cellular connectivity. The test credential was revoked.
- Native iOS project generated with XcodeGen 2.46.0; shared scheme/workspace XML validated. Xcode 26.6 (17F113) and iOS development components installed; Apple agreement accepted with user consent. Unsigned and Personal Team signed iOS builds succeeded. Fixed missing version metadata, selected iPhone-only device family at target scope, and generated launch-screen/scene configuration. The signed 0.1.0 (1) app installed and launched on the trusted iPhone 13 running iOS 18.7.8. Signature and device provisioning verified. Initial pairing timeouts were resolved by installing Tailscale on the phone and actually connecting its VPN. Network failures now explain the Tailscale/Core connection checks.
- End-to-end native pairing and all three allowed job types succeeded from the phone. At about 14:32 America/Chicago, additional Mac status jobs succeeded with the USB cable removed; the Mac USB inventory confirmed the phone was disconnected. Tailscale connectivity was also verified over a direct Wi-Fi route. The phone's real pairing credential remains active; setup-test credentials were revoked. No public port forwarding or Funnel was enabled. Cellular access remains untested. The face is a static placeholder; voice, animated companion, AI planning, and computer control are not implemented. The hello field echoes text and does not interpret requests such as opening a browser.

## Emergency stop and recover

The **Emergency stop** button records a persistent stop flag and aborts active operations that support abort signals. New jobs are rejected until a local Mac operator runs:

```bash
npm run resume
```

For this v0.1 read-only executor, any jobs in progress when Core restarts are marked `interrupted`; they are never silently retried. This is groundwork for later side-effect reconciliation.

To revoke a lost or unpaired phone on the Mac, run `node core/cli.mjs devices`, then `node core/cli.mjs revoke DEVICE_ID` using the listed ID. The iPhone's Unpair button removes its local Keychain credential; use local revocation to invalidate that credential on Core too. No plaintext tokens are printed by these commands.

## Next engineering milestones

1. Verify remote operation across cellular data; the native build, pairing, and unplugged Wi-Fi operation have been tested.
2. Add Secure Enclave device signing, expiry, replay protection and action-bound MissionGrants before privileged actions.
3. Split untrusted planning into `nova-brain` and develop an enforceable executor sandbox with negative tests.
4. Integrate Codex/Claude with bounded worktrees, budgets, objective tests and verified containment.
5. Add APNs alerts, approvals and native macOS controls only after their authorization contracts are tested.
