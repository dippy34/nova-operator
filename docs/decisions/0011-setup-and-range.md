# 0011. Onboarding, access range and Keychain provider keys

Status: Proposed
Date: 2026-10-16
Proposed by: Cursor, at Matthew's request
Amends: [0009](0009-autonomous-computer-control.md), [0010](0010-work-agents-and-takeover.md)

## Context

Matthew asked to make Nova cuter, more accessible, and much easier to set up: install on computer and phone → pair → choose what the AI may access → enter an API key → start. Existing Claude configuration and unlimited spending must stay. Keys must live in the computer's secure storage. Remote access must stay private and authenticated. USB pairing only if real platform APIs support it.

## Decision

- **Wireless pairing is the default.** The Mac shows a QR (`nova://pair?v=1&u&c&n`) and an 8-character short code. Both redeem one expiring invitation. Owner role is created only on the Mac. Core rate-limits wrong codes and revokes devices individually.
- **USB pairing is not implemented.** No supported public API lets an iPhone app establish app connectivity over a cable. The UI says a cable does not pair Nova.
- **Three ranges**, enforced in deterministic code at execution time: Just chat (no Operator, no remote control), Chosen apps & folders (signed `scope` plus folder tools), Whole Mac. Installs that already had an owner migrate to `full` so Matthew skips the step.
- **Takeover pauses** a running task instead of cancelling it. Hand back resumes from a fresh screenshot. A takeover that lapses without Hand back ends the task.
- **Claude and OpenAI keys** live in the login Keychain (`dev.nova.provider`). `.env.local` remains a Claude fallback. Connection tests use free model-list endpoints. OpenAI is labeled as separate from ChatGPT subscription billing. The phone may upload a key only over the authenticated HTTPS session; the key is never stored on the phone.
- **OpenAI** uses the Responses API (`gpt-6.1-sol`) with the same executor, range checks and metering as Claude. Chat on a non-owner device stays Claude-only.

## Consequences

- Chosen-apps screenshots hide other windows; some UI chrome may be missing. Global shortcuts (Spotlight, app switcher, screenshot keys) are refused in that range.
- A ChatGPT Plus or Pro subscription still does not pay for Nova's OpenAI API calls.
- Matthew decides Accepted/Rejected.
