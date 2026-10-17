# Nova Operator

Nova is a native iPhone companion for a Mac-based AI operator. The personal prototype supports conversation, scoped computer control, remote takeover and scheduled work. Reliable coding-agent supervision, more desktop platforms and a separate desk companion remain planned work.

The core idea is **preauthorized autonomy**: before leaving, you grant Nova specific permissions. It completes everything inside those permissions on its own. When it hits something that needs new approval, it keeps doing all independent permitted work and asks you. It never bypasses authentication, security restrictions, or authorization boundaries.

## Status

**Preparing an invited beta; not ready for general distribution.** Follow [the beta plan](docs/BETA-PLAN.md) and [GitHub tracker #3](https://github.com/dippy34/nova-operator/issues/3). A new AI agent should read [the handoff](docs/HANDOFF.md) first. It records what was tested, what is installed and what remains unverified.

**Native prototype installed (2026-10-16).** Wireless iPhone pairing, Claude chat, autonomous Mac control, background work and iMessage reports are in use. Setup is now: install → pair with a QR or short code → choose a range → connect a Claude or OpenAI key in the Keychain → Ready. See [setup](docs/SETUP.md), [pairing](docs/PAIRING-PROTOCOL.md) and [computer control](docs/COMPUTER-CONTROL.md).

**Start here:** [Set up Nova](docs/SETUP.md). The native app is under `ios/`, and Mac Core under `core/`.

If setup fails, open **Set Up Nova… → Connection check** on the Mac. **Check Connection** explains local Core, private networking, pairing ownership and Mac permission problems. Preview and explicitly copy the support report if needed; it excludes keys, pairing codes, addresses, names, task content, screenshots and logs. Nothing is sent automatically. Developers can also run `npm run diagnostics` or `node core/cli.mjs diagnostics --json`. A green Mac check does not verify the iPhone connection or an AI task.

## Where things are

| Path | What it holds |
| --- | --- |
| [`docs/BETA-PLAN.md`](docs/BETA-PLAN.md) | Current beta milestones, acceptance checks and remaining gates |
| [`docs/HANDOFF.md`](docs/HANDOFF.md) | Starting context, verified state, commands and next task for another AI agent |
| [`docs/architecture.md`](docs/architecture.md) | The current proposed architecture: trust tiers, processes, contracts, policy, scheduler, remote layer |
| [`docs/diagrams/`](docs/diagrams/) | Mermaid diagrams: system, command execution, unattended supervision |
| [`docs/limitations.md`](docs/limitations.md) | What works today, what needs engineering, what's unreliable, what macOS prevents |
| [`docs/roadmap.md`](docs/roadmap.md) | Phased plan with deliverables, dependencies, and acceptance tests |
| [`docs/decisions/`](docs/decisions/) | Decision records (ADRs), one per significant choice, with status |
| [`docs/open-questions.md`](docs/open-questions.md) | Unresolved questions for the next reviewer |
| [`docs/reviews/`](docs/reviews/) | Historical reviews: the v1 review of the original design and the v2 challenge |
| [`CHANGELOG.md`](CHANGELOG.md) | Revision log: who changed what and why |
| [`AGENTS.md`](AGENTS.md) | Rules for AI contributors (Claude, ChatGPT, Codex) |

## How to contribute

Read [`AGENTS.md`](AGENTS.md) first. Use branches and pull requests for normal collaboration unless Matthew explicitly requests direct-to-main changes. Never claim untested security boundaries or enable high-impact unattended tools.
