# 0010. Background agents, schedules, unlimited spending and iPhone take-over

Status: Proposed (spending removal decided by Matthew; the rest are Cursor's defaults awaiting his review)
Date: 2026-10-16
Proposed by: Cursor, at Matthew's request
Amends: [0009](0009-autonomous-computer-control.md)

## Context

Matthew asked for two things: to see the Mac on his iPhone and take over himself, and for Nova to be "more like a work AI" that monitors workflows, stays awake, runs on wake-up schedules and runs agents in parallel. Asked about limits, he said: "remove the limit. Just when it exhausts the credits, it exhausts the credits." He did not answer the other questions (what parallel agents may do, how Nova reaches him, what "stay awake" means, what happens to Nova's task when he takes over), so Cursor used the recommended choice for each.

## Decision

- **No spending limit.** The $5 lifetime allowance and $1.50 per-task cap are removed. Usage is still metered and shown. When Anthropic reports an empty credit balance, Nova says so plainly. The 40-round limit per task remains as a loop guard.
- **Take-over.** The owner iPhone can click, double-click, right-click, scroll, type and press keys on the live screen. Matthew's input is marked `direct`, so Nova Operator moves the real pointer without Nova's cursor or pointer restore. Taking over **pauses** whatever Nova is doing on the Mac until Hand back (or five minutes with no hand-back, which ends the task). Scheduled Mac work still waits while he is in control. See [0011](0011-setup-and-range.md).
- **Parallel agents are research-only.** Nova can start up to four background agents with web search, web fetch and visuals but no Mac access, so they cannot conflict with the screen or each other. Terminal access was offered and not chosen.
- **Schedules and monitors.** Nova can schedule one-time, interval (Mac tasks at most every 5 minutes) and daily runs, optionally on certain weekdays and until a time. Monitors reply `NOTHING_NEW` to stay quiet and `STOP_MONITOR` to end themselves, and remember their last eight messages. Runs that need the Mac take turns with Nova, and yield (retrying within two minutes) when Matthew asks Nova for something.
- **Reports** go to an inbox on the iPhone, are read aloud when the app is open, show as a macOS notification, and are texted by iMessage once a handle is set (Matthew chose iMessage for every report so he hears about them abroad with the app closed). The handle lives only in Core's private SQLite settings (`node core/cli.mjs imessage +NUMBER`, or `off`), never in the repo. Core sends through the Mac's Messages app with `osascript`, passing the handle and text as arguments rather than script, and texts are cut to 1,500 characters. It needs Automation permission for `node` to control Messages; a failed send is recorded as an `imessage` event. Push was not built: it needs the paid Apple Developer Program.
- **Staying awake.** Core keeps the Mac from sleeping while on power (`caffeinate -s`) so the iPhone can always reach it, and also on battery while work is pending (`-i`). Before a scheduled Mac run it wakes the display. Waking a sleeping Mac (`pmset schedule`) needs an administrator password and was not set up. Closing the lid on battery still sleeps the Mac.

## Consequences

- Nova can spend the whole Claude balance without asking, including from schedules while nobody is watching. A one-minute research monitor runs 1,440 times a day.
- Reports and their text come from web pages and screens. They are passed to Nova as information, not instructions, but this is not a guarantee.
- A locked screen stops scheduled Mac work; Nova will report that it needs the password.
- Report texts pass through Apple's iMessage service, and with Automation permission any code running as `node` on this Mac can send Messages.
