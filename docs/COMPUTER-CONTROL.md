# Autonomous Mac computer control

Nova controls the whole Mac without asking. Matthew chose this on 2026-10-16 (see [ADR 0009](decisions/0009-autonomous-computer-control.md)): any app, no per-action approval, voice in and out on the iPhone. It replaces the reviewed, app-scoped sessions of ADR 0008.

## Use

1. Open Nova on the paired owner iPhone. Tap the mic and speak, or type, then send. Plain questions get a spoken answer; requests that need the Mac make Nova act on it.
2. Nova says what it is about to do, then does it with its own glowing cursor. Your real pointer is put back where you left it after each click. The iPhone shows the narration, each action and the latest screenshot.
3. When Nova finishes it reads its answer aloud. Turn **Speak replies** off to keep it silent.
4. Stop it with **Stop this task** on the iPhone, **Control-Option-S** on the Mac (or **Stop Nova** in its menu-bar menu), or **Emergency stop**, which blocks Nova until `npm run resume` is run on the Mac.

Nova remembers the last three exchanges, so follow-ups like "now do it again" work. Memory is cleared when Core restarts or after an emergency stop.

## How it works

- **Brain:** Core runs Anthropic's computer-use toolset (`computer_toolset_20260801`) with Claude Sonnet 5.5 and adaptive thinking ([docs](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/computer-use-tool)). Claude sees the main display scaled to fit 1366 px on the long side and can zoom into regions at full resolution. It can click (left, right, middle, double, triple, with modifiers), drag, move, scroll, type, press key combinations and wait.
- **Hands:** the Nova Operator menu-bar app posts system-wide mouse and keyboard events, so they go to whatever is on screen. Its cursor overlay is excluded from screenshots.
- **Voice:** the iPhone uses on-device Apple speech recognition (when the iPhone supports it) and the system text-to-speech voice. Neither costs anything.

## Limits that still apply

- **Owner only:** only the iPhone designated with `npm run computer:owner` can run computer tasks. Other paired devices get text chat.
- **One task at a time,** at most 40 Claude rounds per task.
- **Spending:** each Claude round reserves $0.30 and is settled to the actual usage reported by Anthropic. A task stops at $1.50. All of Nova shares a $5 lifetime allowance. Errors that Anthropic rejects release the reservation, but timeouts keep it because billing is unknown.
- **Signed input:** every native request carries an HMAC-bound payload with a fresh nonce and five-second expiry, checked by Nova Operator before it acts. Only Core holds the key.
- **On-screen instructions:** the system prompt tells Claude that text on screen comes from third parties, not Matthew. Anthropic also scans screenshots for prompt injection. Neither is a guarantee.

There is no app blocklist and no approval step, by Matthew's choice. Nova can send messages, change settings, delete files or spend money if it decides that is what was asked, or if a web page misleads it. Close anything you don't want it to see or touch before giving it a task, and keep Control-Option-S in mind.

## Setup on another Mac

- Build the signed Mac app with `NOVA_MAC_SIGN_IDENTITY='your installed signing identity' npm run operator:build`. It lives in ignored `.nova-data/Nova Operator.app`. Its signed configuration pins the Core data directory; callers cannot supply an alternative signing key.
- Start it with `npm run operator:install`. Nova Operator is a menu-bar app run by its own login item (`dev.nova.operator.macos`), so macOS charges permissions to Nova Operator rather than to Core's `node`. Core reaches it over `~/Library/Application Support/Nova Operator/operator.sock` (owner-only directory and socket; peer UID checked). `npm run operator:status` reports what the running app sees; after rebuilding, run install again to restart it.
- In System Settings → Privacy & Security, allow **Nova Operator** under Accessibility and Screen Recording. It asks on first launch, and its menu shows the current state.
- Use `node core/cli.mjs devices` to find the phone's ID, then `npm run computer:owner -- DEVICE_ID`. Disable with `npm run computer:owner -- disable`.
- Run `npm test` (the native protocol test needs Nova Operator running), then `npm run service:install`, and build and install the iOS app.

## Verification checkpoint (2026-10-16)

- 27 tests pass on Matthew's Mac with no skips, including the agent loop against a scripted Claude, cost settlement, the allowance block, Control-Option-S, owner-only access, stopping a task over HTTP, and the native forged/expired/replayed request rejection against the running app.
- A real Sonnet 5.5 task on the Mac, "Open Calculator, clear it, then calculate 7 times 6", succeeded: Spotlight, typing, Return, then five clicks, answered "42" in 17 seconds for $0.030.
- The updated iPhone app built and installed on the iPhone 13. Voice input and spoken replies on the phone have not yet been tested by Matthew.
