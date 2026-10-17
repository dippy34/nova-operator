# Continue Nova in Claude Code

The existing Claude desktop app now has a local environment named **Nova**, selected on `main` with Worktree off, pointing at `~/Projects/nova-operator`. No task has been submitted. Open that environment (or the existing folder in another Claude Code installation). The root `CLAUDE.md` imports the contributor rules, technical handoff and product context using [Claude Code’s documented import format](https://code.claude.com/docs/en/memory#import-additional-files). Local machine notes are in ignored `CLAUDE.local.md`. No transcript export or new pairing/key is required.

## Paste this as the first task

```text
Continue Project Nova in the existing local repository /Users/matthew/Projects/nova-operator, GitHub dippy34/nova-operator, branch main. I am transferring development from Codex to Claude Code. Do hands-on implementation and setup; do not restart or redesign the project from scratch.

First read CLAUDE.md, AGENTS.md, docs/HANDOFF.md, docs/PRODUCT-CONTEXT.md, docs/BETA-PLAN.md and GitHub issues #3 (tracker) and #4 (next B2 implementation task). Read ignored CLAUDE.local.md for this Mac’s setup and credential locations; never print or publish it. Inspect fresh Git status/history and preserve concurrent work. Treat prior verification as evidence for its exact scope, not proof that every feature works.

Nova is a native iPhone companion controlling a persistent Mac AI operator, with a unique minimal cyan smiley character. Keep the identity and native UI. Android/Windows and reliable coding-agent supervision are later work. Existing capabilities include scoped desktop control, voice, manual takeover, background research, schedules/monitors and private Tailscale pairing. Keep current owner pairing, Whole Mac range, API credentials and no overall spending cap. API billing remains the runtime choice. Do not enable public Funnel, bypass OS permissions, weaken deterministic execution-time authorization or silently alter my settings.

The local folder was relocated and the Core/native LaunchAgents and signed Mac app were updated. The current app still depends on the checkout and development Node. B2 is the next coding milestone: make the Mac app self-contained, with explicit runtime resources, a pinned verified runtime, separate mutable data, compatible migration, startup/recovery and rollback. Develop/test with isolated data first. Never bundle .env.local, .nova-data, private databases, signing files, credentials or local notes. Preserve the existing working install until replacements pass.

Validate the recorded baseline with appropriate tests and diagnostics. Start implementing the first bounded B2 change after inspecting the code; don’t stop after a plan. Keep the real-phone voice/recovery/Stop/takeover checks visibly outstanding until actually tested. Preserve the listening state/meter fixes. No paid model call is needed for baseline tests.

The product’s competitive advantage remains unproven. Read the product context instead of claiming schedules, remote control or a cute face are unique. Continue beta engineering without inventing proven market demand or silently narrowing the whole product to one use case.

Work on main as I previously authorized, use normal commits, never force-push or overwrite unrelated work, and keep GitHub issue #3, docs/HANDOFF.md, docs/BETA-PLAN.md and CHANGELOG.md current. On this Mac prefix shell commands with rtk per the local instructions. Explain progress in plain language. Ask me only for unavoidable device interaction, login, signing or OS permission steps.
```

## If using another computer

Clone the GitHub repository and use its `CLAUDE.md` and public docs. Private credentials, database, signed apps, local device setup and `CLAUDE.local.md` are intentionally not in GitHub. Do not claim a fresh clone is already paired or installed. Follow [SETUP.md](SETUP.md) for that machine.
