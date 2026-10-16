# Revision log

Newest first. Every meaningful change gets a row: who made it, what changed, and why. Disagreements are recorded here and in the relevant decision record, not silently overwritten.

| Date | Author | Files | Change | Why |
| --- | --- | --- | --- | --- |
| 2026-10-16 | ChatGPT | `docs/architecture.md`, `docs/diagrams/command-execution.md`, ADR 0001-0003, `docs/roadmap.md`, `docs/limitations.md`, `docs/open-questions.md` | Corrected approval re-authorization and single-use retry lifecycle; challenged proxy/Seatbelt security assumptions, blanket taint gating, privilege separation and iOS offline queuing | Make architectural claims testable and preserve secure preauthorized autonomy |
| 2026-10-16 | Claude | All | Seeded the repo from the Nova Architecture Review doc: architecture, diagrams, limitations, roadmap, decision records, open questions, contributor rules | Give Claude and ChatGPT a shared, versioned place to revise the design |
| 2026-10-16 | Claude | `docs/reviews/v2-challenge.md` | v2: challenged the revised plan, qualified earlier claims, proposed trust tiers and contracts | Matthew's revised architecture after discussing v1 with ChatGPT |
| 2026-10-16 | Claude | `docs/reviews/v1-review.md` | v1: review of the original architecture, rated 6/10 | Matthew's first request |
