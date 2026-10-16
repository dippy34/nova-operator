# Nova Operator

Nova is a persistent AI operator for a MacBook. It controls apps and workflows, supervises coding agents like Claude Code and Codex, and works autonomously for long stretches. You control it remotely from a native iPhone app; a spare iPhone can sit on the desk as an animated, voice-driven companion.

The core idea is **preauthorized autonomy**: before leaving, you grant Nova specific permissions. It completes everything inside those permissions on its own. When it hits something that needs new approval, it keeps doing all independent permitted work and asks you. It never bypasses authentication, security restrictions, or authorization boundaries.

## Status

**Native prototype installed (2026-10-16).** Wireless iPhone pairing, read-only Mac checks and Claude chat are verified. Reviewed app-scoped mouse/keyboard/screen control is built and installed, with a negatively tested Brain sandbox and 27 passing tests; its live iPhone input smoke test is pending. Each input requires an exact owner approval. Unrestricted unattended control and coding-agent supervision remain disabled. See [current computer-control evidence and limits](docs/COMPUTER-CONTROL.md).

**Start here:** [Phase 1 installation and testing guide](docs/PHASE1-START.md). The native app is under `ios/`, and Mac Core under `core/`.

## Where things are

| Path | What it holds |
| --- | --- |
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
