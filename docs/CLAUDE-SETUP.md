# Nova Claude conversation

Nova sends chat from the native iPhone app through Mac Core to Anthropic. [Reviewed computer sessions](COMPUTER-CONTROL.md) also support app-window screen capture and approved mouse/keyboard input. Coding-agent supervision, voice and long-term memory remain unimplemented. Ordinary chat text is never interpreted as executable code.

## Private API key

Create `.env.local` in the repository root, containing one line:

```dotenv
ANTHROPIC_API_KEY=your-key-here
```

Save it as plain text with permissions `600` (`chmod 600 .env.local`). This file is ignored by Git. Never put the key in chat, commit it, put it in the iPhone app, or add it to the LaunchAgent plist. Nova reads this file for each request, so changing the key does not require restarting Core. A missing key or broader file permissions disables chat. Create/manage keys in your own Claude Console account. Key values must never be printed while diagnosing configuration.

Update Core with `npm run service:install`. Build/install the current native Xcode app; existing pairing survives an app update. The iPhone needs Tailscale connected and Core running, but needs no USB cable for conversations. Tap the send arrow under **Talk to Nova**. The most recent question/reply appears there; older exchanges remain in Recent jobs. Core health checks/polling do not call Claude.

## Cost controls

- Model: `claude-haiku-5-5`; no automatic fallback to a more expensive model.
- Input: 2,000 characters; history: at most two prior successful exchanges from that device, with truncated context.
- Output: 512 tokens per request; replies may be cut short. Thinking disabled, no caching/retries. Ordinary chat has no tools. Computer sessions use one proposal tool; it cannot execute input directly.
- Only one active AI request. Emergency stop aborts local requests and blocks new work until local resume. Aborting cannot reverse usage already billed remotely.
- $1 lifetime Nova allowance in SQLite, shared across paired devices and persistent across restarts. This is not the account balance or a daily allowance.
- Each dispatched request reserves $0.01. Confirmed token usage replaces the reservation with an estimate rounded up to USD micro-units. Unknown outcomes retain the reservation. Budget denial occurs before model dispatch.
- Increasing the local allowance requires a deliberate change to `AI_BUDGET_MICROS` in `core/ai.mjs` and a Core restart. No prompt can raise it. Do not delete the database to reset it: that also destroys pairing/history and accounting evidence.

Rates used: $0.10/million input and $0.50/million output tokens for short prompts, [verified 2026-10-16](https://platform.claude.com/docs/en/about-claude/pricing). Example: 1,000 input + 300 output tokens estimates $0.00025. This is an estimate for Nova's short text requests, not coding-agent tasks. Anthropic's invoice is authoritative. Price changes, taxes and other apps using the key are outside Nova's allowance. The reported $8.46 account credit has not been independently verified by Nova.

## Verification

`npm test` includes fake-provider tests for request shape, cost calculation, durable allowance, no dispatch over budget, concurrent-request rejection, per-device history isolation, authentication and emergency-stop cancellation. These tests do not spend API credits. Signed iPhone build and live-account results are recorded separately after execution; a passing fake-provider test does not prove account/model access.

The worker now runs inside a target-Mac-tested OS sandbox and uses Core's fixed API broker; Core holds the API key and provider accounting. The native executor runs separately with OS permissions and requires exact reviewed actions. See [ADR 0008](decisions/0008-reviewed-app-control.md). The earlier text-only checkpoint is recorded in ADR 0007.

### Verified on Matthew's Mac, 2026-10-16

- All 15 backend tests passed, including the new fake-provider safety/accounting tests.
- Xcode built and signed the updated native app; installation on the iPhone 13 succeeded. Matthew then unlocked/opened Nova and confirmed chat works. Core independently recorded a successful `ai.chat` from the paired `Nova iPhone`: 134 input / 25 output tokens, estimated $0.000026. The native iPhone → private Core → Claude → native reply path is verified.
- Core was reinstalled as the login service. A real, authenticated `ai.chat` job went through Core, the separate worker and Anthropic, returning: “Yes, Nova's Claude connection is working.” Usage: 156 input tokens, 18 output tokens, estimated $0.000025 at the documented rates. No retries. The temporary setup device credential was revoked afterward.
- The private key was detected without printing it. No API key or signing credential is tracked in Git.
