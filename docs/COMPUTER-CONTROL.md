# Reviewed Mac computer sessions

Nova now implements app-scoped screen capture, left click, scroll, printable text entry and a small set of keys. Each input requires review and device authentication in the native iPhone app. This is not unrestricted unattended control, shell access, or coding-agent supervision.

## Use

1. Open Nova on the paired owner iPhone. Select Calculator, Chrome, Safari, TextEdit, Notes or Finder under **Computer control**.
2. Tap **Start 20-minute session** and read the sharing notice. This brings the selected app forward. Its current window and your task are sent to Anthropic when you request a computer task. Other apps/windows are not captured.
3. Send a task, such as “Click the 7 button.” Nova returns the captured window and one proposed input. Review the target and any typed text, then tap **Approve action** or **Reject**. Approving uses Face ID/passcode through iOS LocalAuthentication. It does not yet create a Secure Enclave signed server request.
4. After an approved input, Nova captures the result and proposes the next step or reports completion. A task has at most eight planning rounds. No click/type/key/scroll runs automatically. The app may need a moment to load the screen preview.
5. **End computer session** revokes the session; **Emergency stop** revokes all sessions and aborts work. Resume after emergency stop remains Mac-only. Sessions do not survive a Core restart or expire later than 20 minutes.

Keep the selected app in front. Switching apps, moving the window, or changing its pixels/accessibility state invalidates the review. Capture a fresh task rather than retrying an uncertain action. Strict screenshot hashes can reject animated pages or blinking carets; this initial version favors rejecting stale input over acting on a different screen.

Close private documents and credentials before starting. A best-effort native check rejects recognizable keys present in the inspected accessibility text, and typing into recognized password fields is denied. This is not complete pixel redaction. Handle authentication, purchases, transfers, legal agreements, security changes and irreversible operations directly. Review matters: general GUI effects cannot always be inferred from a coordinate or a key.

## Setup on another Mac

- Build the signed Mac helper with `NOVA_MAC_SIGN_IDENTITY='your installed signing identity' npm run operator:build`. It lives in ignored `.nova-data/Nova Operator.app`. Its signed configuration pins the Core data directory; callers cannot supply an alternative signing key.
- In System Settings → Privacy & Security, explicitly allow **Nova Operator** Accessibility and Screen Recording. No root access or Full Disk Access is required.
- Use `node core/cli.mjs devices` to find the exact verified primary phone ID, then `npm run computer:owner -- DEVICE_ID`. The owner must already be paired. Companion devices must not be designated owners. Disable future sessions locally with `npm run computer:owner -- disable`; ending a live session immediately can also be done with emergency stop.
- Run `npm test`. On the target Mac, the native helper must be built so its protocol tests run rather than skip. The macOS sandbox tests must pass. Then update Core with `npm run service:install`, and build/install the current iOS project.
- Sandbox absence/failure disables model execution; there is no unsandboxed runtime fallback. Non-macOS machines cannot run this helper.

## Enforced boundaries

Core authenticates the phone, checks the locally assigned owner, session app and expiry, emergency stop, current device revocation state, action schema and exact single-use approval ID. Different actions within one job have different IDs. A delayed or duplicated approval cannot authorize the next action. The model cannot choose another app, invoke shell tools, modify permissions, expand the session or raise its budget.

Every native request carries an HMAC-bound payload, fresh nonce and five-second expiry. The helper consumes the nonce before dispatch and checks the operation/app/arguments again. Before input it checks the frontmost bundle, PID, focused-window frame, accessibility fingerprint, and the exact captured PNG hash. Click/scroll targets are hit-tested against the selected PID and kept inside the window; keyboard events target that PID. The small check-to-event race is not an atomic OS transaction. An action can have effects inside its selected app, and a general GUI action can trigger external effects; exact human review is mandatory.

The Brain worker runs under a tested Seatbelt profile: no direct network, no Mach lookups, no file writes, no subprocesses, and file-data reads limited to code/runtime/system resources. It cannot read Core's database, `.env.local`, operator HMAC key, or user files. An inherited IPC channel is its only provider path. Core brokers one bounded request to the fixed Anthropic Messages endpoint, inserts the API key, denies redirects, caps model/tokens/text/image size, and derives spending from the actual provider response rather than trusting the worker's cost claim. No server-side paid tools or automatic retries are enabled.

The $1 shared Nova estimate-based allowance remains active. Each planning round reserves $0.01; unknown outcomes retain the reservation. Screens add input tokens. One click task may use a planning request before and after input. API charges already incurred cannot be undone by stopping.

Screens are kept in Core memory for the session, accessible only to the owning device over the private authenticated connection. They are cleared when the session ends or Core restarts. Job/action summaries, typed text and model results remain in the private SQLite journal. The executor is trusted and has OS permissions; it is not itself sandboxed. Processes share a macOS account, so this does not protect against a malicious local user or compromise of Core. It is not a complete implementation of the proposed long-term grant/signature architecture.

## Verification checkpoint

- Signed native Mac helper and signed iPhone app build successfully; updated iPhone app installation succeeded.
- macOS reports Accessibility and Screen Recording allowed after Matthew's explicit grant.
- 27 tests pass on this Mac, with no skips. These include actual Seatbelt probes for private-file reads/writes, child processes, direct TCP (permission errors), DNS, contained-worker IPC, provider bounds, exact-approval races, wrong-device/expired/revoked/stopped sessions, and native forged/expired/replayed payload rejection. Five additional native argument-validation probes pass.
- A real Haiku 5.5 image/planning request passed through the contained worker and Core broker using a blank synthetic image. It returned the requested `done` result, “Planner connected,” without proposing or executing input. Usage: 1,141 input / 56 output tokens, estimated $0.000143. This separately verifies account access to the image/tool schema, not GUI delivery.
- Native screen capture, real input delivery and the full iPhone approval round trip still require the on-device smoke test. Model/parser and fake-executor tests alone do not prove those behaviors.

API references: [Apple screenshot capture](https://developer.apple.com/documentation/ScreenCaptureKit/SCScreenshotManager/captureImage(contentFilter:configuration:completionHandler:)), [AX hit testing](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition), [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent), [Claude tool calls](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls).
