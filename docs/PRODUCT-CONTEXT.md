# Product decisions and conversation context

This records Matthew’s requirements and corrections so another agent can continue without the original conversation. Requirements are user decisions; proposed positioning remains unvalidated.

## Product

- Nova is a persistent personal AI operator on the user’s computer, controlled through a native phone app. A website is not the requested product.
- First beta: Mac + iPhone. Android, Windows and other desktop platforms are desired later; do not describe them as implemented.
- Eventually supervise Claude Code/Codex and operate browser/native apps, with advance permissions and a separate spare-phone companion. Reliable coding-agent supervision is not finished.
- Matthew wants setup to feel like installing the app on both devices, pairing, selecting the AI’s range, adding a Claude/OpenAI key and using it. The current development install falls short of that.
- Pairing is wireless through Tailscale Serve with QR/manual codes. USB was investigated for pairing but not implemented; a cable was used for development installation. Do not promise plug-in-to-pair.
- The spare phone is an iPhone 13 on iOS 18.7.8. Jailbreak is neither required nor part of the plan.

## Autonomy, billing and trust

- Matthew asked for general mouse, keyboard and screen control, then chose autonomous operation within the selected range. Preserve his working configuration.
- Current ranges are Just chat, Chosen apps/folders and Whole Mac. Decisions must be enforced by deterministic code at execution, including role changes and scheduled work.
- Preserve a clear emergency stop and manual phone takeover/hand-back. The existence of controls is not proof that every timing/recovery combination is tested.
- Matthew considered subscription OAuth but chose API billing for now. Existing runtime credentials already work locally. Do not substitute subscription credentials, scrape OAuth tokens or assume API usage is included in a chat subscription.
- Matthew later chose no overall spending cap. B4 proposes optional task/daily budgets; keep existing no-cap behavior until he changes it. Never publish an old chat’s credit balance as if it were current.
- Never expose Core through public Funnel or unauthenticated forwarding, bypass OS permissions/authentication, or use model judgment as the authorization layer.

## Character and design

- Keep Nova’s own minimal cyan smiley face. Bird/cartoon directions and a replacement Siri-style orb were rejected.
- Matthew likes Apple’s clarity, polish and smooth native behavior, and explicitly rejected copying Siri’s identity. Nova uses its own restrained cyan/indigo/mint palette.
- The character should be cute and expressive, with meaningfully different states. Clear visible controls, accessibility and understandable connection/access labels matter more than decorative effects.
- Listening previously became glitchy and left an edge glow during tasks. The current fix isolates the meter, throttles the overlay to 15 Hz, simplifies the glow, makes start/send exclusive and rejects stale callbacks. Glow means active listening only. Preserve the voice regression tests and verify actual phone behavior.
- Use native materials with supported fallbacks and respect Reduce Motion, contrast and text-size settings. Do not claim complete accessibility testing from source alone.

## Known incidents to avoid repeating

- Pairing timed out until the phone’s Tailscale VPN was actually connected. A Mac-only HTTPS check did not prove the phone route worked.
- Nova said it was conversation-only despite Whole Mac being selected. Global range and paired-device ownership are separate. The current phone’s ownership was repaired, routing now refreshes role/status before sending, and non-owner computer jobs are rejected server-side.
- A clean source checkout initially failed its native protocol test because it assumed this installation’s private app/key existed. The test now skips explicitly when local prerequisites are absent and never invents a key for a different installation.
- Development paths were buried under Codex output directories. The canonical local checkout was relocated to `~/Projects/nova-operator`; services and the signed app were rebuilt for it. Keep local machine details in ignored `CLAUDE.local.md`.

## Product differentiation remains unresolved

Matthew challenged whether users would choose Nova over Claude remote features or existing monitoring apps. We have not established a proven competitive advantage or willingness to pay.

The current research found substantial overlap: [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) continues local sessions from a phone; [Claude Dispatch documentation](https://support.claude.com/en/articles/13947068-assign-tasks-from-anywhere-in-claude-cowork) describes desktop delegation and scheduled work, with availability restrictions; [MacOn](https://macon.id/companion) advertises remote control, AI operation, automation and provider choice. These are vendor descriptions, not independent comparative tests. Re-check current availability before relying on them.

Potential direction: dependable delegation with understandable boundaries, proof of completion, smooth takeover and recovery. This is a hypothesis to validate, not a unique capability already demonstrated. Native UI, a smiley face, API-key choice and schedules alone are insufficient evidence of differentiation.

The suggested validation is to choose one real workflow and compare setup effort, completion rate, human interventions and cost against existing alternatives. No workflow or positioning was accepted as the exclusive product direction. Continue the practical beta foundations while documenting this uncertainty.

## How Matthew wants work handled

Do real development and setup, not just plans or capability claims. Continue authorized reversible work independently; ask for unavoidable device interactions, login, signing or security permission grants. Keep explanations plain and concise. Preserve concurrent work and keep GitHub documentation sufficient for another AI agent to take over at any time.
