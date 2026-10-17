# Autonomous Mac computer control

Nova controls the whole Mac without asking. Matthew chose this on 2026-10-16 (see [ADR 0009](decisions/0009-autonomous-computer-control.md)): any app, no per-action approval, voice in and out on the iPhone. It replaces the reviewed, app-scoped sessions of ADR 0008.

## Use

1. Open Nova on the paired owner iPhone. Tap the mic and speak, or type, then send. Plain questions get a spoken answer; requests that need the Mac make Nova act on it.
2. Nova says what it is about to do, then does it with its own glowing cursor. Your real pointer is put back where you left it after each click. The iPhone shows the narration, each action and the latest screenshot.
3. When Nova finishes it reads its answer aloud. Turn **Speak replies** off to keep it silent.
4. Stop it with **Stop this task** on the iPhone, **Control-Option-S** on the Mac (or **Stop Nova** in its menu-bar menu), or **Emergency stop**, which blocks Nova until `npm run resume` is run on the Mac.

Nova remembers the conversation for as long as the iPhone app stays open: each launch sends a new conversation ID, and Core keeps the last 24 messages for it (including what Nova drew). Memory is also cleared when Core restarts or after an emergency stop.

The iPhone stays on Nova's face unless Nova uses the Mac or draws something. When an answer is easier to see, Claude calls the `show` tool and the face shrinks into a header while the screen becomes a graph of any functions (parsed and plotted on the iPhone), a bar, line or pie chart, a chalkboard that Nova writes one step at a time while saying each step (with simple chalk sketches), cards, or a table. Several visuals in one answer play in order and can be swiped between. Tap × to go back to the face. Visuals cost only the tokens Claude spends describing them; verified 2026-10-16 with a real board plus graph for x² − 5x + 6 ($0.027).

## Taking over

On the face, swipe up to see the Mac, then tap **Take over** (or press and hold the face → Take control). The iPhone turns sideways and you drive: tap to click, double-tap to double-click, press and hold to right-click, pinch to zoom, drag the side pad to scroll, and type or press keys at the side. Whatever Nova was doing **pauses**. Tap **Hand back** when you're done so it can continue from a new screenshot; scheduled Mac work waits until then. If you never hand back, the paused task ends after five minutes.

Remote control is off while Nova's range is Just chat. In Chosen apps, Nova can only see and click the apps you picked.

## Work: background agents, schedules and monitors

Ask in plain words, for example "research the three best budget headphones in the background", "every weekday at 8, brief me on tech news", or "check this page every 30 minutes and tell me when it's back in stock".

- **Background agents** run in parallel (up to four) while Nova or you use the Mac. They can search and read the web and make visuals, but cannot see or use the Mac. Orange lights circle Nova's face while they work.
- **Schedules** run once, every N minutes, or daily (optionally on chosen weekdays, until a time). A schedule that needs the Mac takes turns with Nova; if you ask Nova for something, it goes first and the scheduled run retries within two minutes.
- **Monitors** are schedules that stay quiet until something worth telling you happens, then report, and can end themselves when the thing you were waiting for has happened.
- **Reports** appear as a banner on the face, are read aloud if the app is open, show as a Mac notification, are texted by iMessage when a number is set (`node core/cli.mjs imessage +12245551234`; `off` to stop; macOS asks once to let `node` control Messages), and stay in the Work view (swipe left on the face, or tap the banner or the pill at the bottom). Visuals in a report can be shown on the face again. Swipe a schedule or running agent to delete or stop it, or ask Nova.
- **Staying awake:** while plugged in, the Mac does not sleep so the iPhone can always reach Nova; with work pending it also stays awake on battery. The display can sleep, and Nova wakes it before scheduled Mac work. Closing the lid on battery still sleeps the Mac, and a locked screen stops scheduled Mac work.

Work survives Core restarts (schedules are in SQLite); running agents are marked interrupted.

## How it works

- **Brain:** Core runs Anthropic's computer-use toolset (`computer_toolset_20260801`) with Claude Sonnet 5.5 and adaptive thinking ([docs](https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/computer-use-tool)). Claude sees the main display scaled to fit 1366 px on the long side and can zoom into regions at full resolution. It can click (left, right, middle, double, triple, with modifiers), drag, move, scroll, type, press key combinations and wait.
- **Hands:** the Nova Operator menu-bar app posts system-wide mouse and keyboard events, so they go to whatever is on screen. Its cursor overlay is excluded from screenshots.
- **Research:** Nova and its agents use Anthropic's server-side web search and web fetch (`web_search_20260318`, `web_fetch_20260318`). Searches cost $10 per 1,000 plus tokens.
- **Voice:** the iPhone uses on-device Apple speech recognition (when the iPhone supports it) and the system text-to-speech voice. Neither costs anything.

## Limits that still apply

- **Owner only:** only the iPhone paired from the Mac with "This iPhone controls the Mac" (or `node core/cli.mjs pair --owner`) can run computer tasks. Other paired devices get text chat. Just chat turns computer tasks and remote control off for everyone.
- **One task on the Mac at a time,** at most 40 Claude rounds per task. Up to four background agents in parallel.
- **Spending:** no limit, by Matthew's choice (ADR 0010). Every Claude round is metered to the usage Anthropic reports, and the panel shows the running total. When the Claude credits run out, Nova says so. Schedules spend while nobody is watching; research with web search costs more than a plain question (a test with two agents and one scheduled check cost $0.51).
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
