# Rules for AI contributors

This repo is a shared design workspace. Claude, ChatGPT, Codex, and Matthew all edit it. These rules keep the design honest and the history readable.

## Scope

- **Design only, for now.** Do not add implementation code until Matthew says Phase 1 has started. Schemas, examples, and pseudocode inside docs are fine when they clarify a design point.
- Matthew is the decision maker. Assistants propose; Matthew accepts or rejects.

## How to change things

1. Work on a branch named `<author>/<topic>`, for example `claude/policy-engine` or `chatgpt/transport`.
2. Open a pull request. The other assistant (or Matthew) reviews it.
3. Edit documents in place. Don't append a competing second version of a section.
4. Add a row to [`CHANGELOG.md`](CHANGELOG.md) for every meaningful change: date, author, files, what changed, and why.
5. For any significant architectural choice, add or update a decision record in [`docs/decisions/`](docs/decisions/) using the template there.

## How to disagree

- If you think a claim is wrong, change it **and** record the disagreement: in the PR description, and in the relevant decision record's "Objections" section if one exists. Name the old claim and your reason.
- Don't quietly delete reasoning you disagree with. The point of two reviewers is that disagreements stay visible.
- A rejected proposal stays in its decision record with status `Rejected` and the reason.

## Evidence standards

- Separate **proven** (shipping technology, documented APIs) from **assumed** (plausible but untested).
- Mark anything you haven't verified against current docs with `(verify)`. Platform behavior (macOS, iOS, Chrome, agent SDKs) changes often.
- When you cite an API, framework, or OS behavior, link the source where you can.
- Don't claim something is impossible without naming the specific technical limitation.

## Non-negotiable design constraints

These come from Matthew's requirements. Proposals that violate them are out of scope:

- Nova must not bypass authentication, security restrictions, or explicit authorization boundaries.
- Authorization decisions are deterministic code. No model, local or cloud, sits in the authorization path.
- Every concrete action is checked at execution time, by effect, not by tool.
- The gateway or relay can never grant access to the Mac by itself.

## Writing style

- Lead each section with its conclusion.
- Short sentences, specific numbers and names, no filler.
- Keep diagrams as Mermaid source in Markdown so they render on GitHub and stay editable as text.
