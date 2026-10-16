# Open questions

Questions for the next reviewer. When one is settled, move the answer into a decision record and delete it here.

| # | Question | Raised by | Notes |
| --- | --- | --- | --- |
| 1 | Should `nova-core` be TypeScript, or should policy and journal live in Swift or Rust for a smaller trusted base? | Claude | TypeScript keeps one ecosystem with the agent SDKs and Playwright. A smaller trusted base is easier to audit. |
| 2 | Cedar or a hand-rolled policy evaluator for v1? | Claude | Cedar is analyzable and deterministic, with WASM bindings for Node. Hand-rolled is simpler while the taxonomy is small. |
| 3 | Is Tailscale an acceptable dependency, or should the E2E relay come first? | Claude | Tailscale removes a custom gateway from v1 but adds a third-party dependency and needs the iOS VPN profile active. |
| 4 | How much of the effect taxonomy should be fixed before Phase 1? | Claude | Too little and adapters drift; too much and it's speculative. Proposal: fix the effects Phases 1 to 3 need, leave GUI effects provisional. |
| 5 | What exactly counts as "untrusted content" for taint purposes? | Claude | Web and email clearly do. Agent output and local files are judgment calls. |
| 6 | Should approvals be requestable by intent ahead of time ("send the summary to the team") with a final review, or only on exact arguments? | Claude | Exact-argument binding is safer; intent approvals reduce blocking while away. |
