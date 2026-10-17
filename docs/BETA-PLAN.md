# Invited beta plan

Nova is a working personal prototype, not a beta-ready release. The first beta is Mac + native iPhone, with 5–10 invited testers after the gates below pass. Android, Windows, coding-agent supervision and a separate desk companion remain later work.

**Tracker:** [Beta readiness #3](https://github.com/dippy34/nova-operator/issues/3). **Agent starting point:** [HANDOFF.md](HANDOFF.md). **Last updated:** 2026-10-16.

## Definition of ready

A new tester installs Nova, pairs their devices, adds their own API key, completes three useful wireless tasks, and stops or takes over a task without developer intervention. Repeat on a second Mac and account. All acceptance checks need recorded results; a successful build alone is insufficient.

## B0 — Reproducible source and handoff

Status: Source and handoff implemented; hosted CI remains outstanding. Local validation results are in the [handoff](HANDOFF.md).

- [x] Preserve existing commit history and publish the shared Cursor/Codex prototype on `main`.
- [x] Keep a single beta tracker, this plan, and an agent handoff in the repository.
- [x] Record the distinction between automated tests, native compilation, installed builds and real device behavior.
- [x] Add a handoff maintenance rule to `AGENTS.md`.
- [x] Prepare Claude Code imports, continuation prompt and product history; relocate the working checkout into Projects and verify its services, private setup, tests and build. This does not complete B2.
- [x] Run tests from an isolated source checkout without private state. 77 passed; the native integration test explicitly skipped until that checkout has its own app/key and a running helper. The installed development checkout passes all 78 tests.
- [ ] Add hosted continuous integration for backend tests, voice state tests and unsigned native builds. Local runs are currently the evidence.

## B1 — Reliability and support

Status: In progress. The connection check and support report are implemented. Live voice and recovery acceptance are outstanding.

- [x] Add a read-only Mac connection check covering local Core, unauthenticated rejection, Tailscale, Funnel, the private HTTPS route, saved setup, owner-only database file permissions, paired/controlling devices, native permissions and emergency-stop state.
- [x] Add a previewable, explicitly copied support report. Exclude secrets, codes, addresses, device names, task content, screenshots and raw logs. Do not upload automatically.
- [x] Test failed probes, missing/revoked owner, missing native grants, wrong service, unprotected routes, unsafe URLs, corrupt/missing databases and report privacy.
- [ ] On the real iPhone, run 20 listening → send → reply cycles. Include rapid repeated taps, cancellation, an empty recording, backgrounding and an audio interruption. No duplicate submission or lingering listening glow.
- [ ] Test Wi-Fi loss, iPhone VPN off/on, Mac sleep/wake, Core restart and stale phone state. Recovery must be understandable and must not silently replay input.
- [ ] Record real Stop and takeover behavior during a task and during scheduled work, including elapsed stop time and any input already in flight.

Mac diagnostics do not prove the phone is connected, that a provider key works, or that an AI task succeeds. Do not mark B1 complete from a green report.

## B2 — Self-contained Mac installation

Status: Not started. This is the next independent coding milestone; see [implementation issue #4](https://github.com/dippy34/nova-operator/issues/4).

- [ ] Bundle a pinned, verified runtime and only the Core resources needed at runtime. A customer must not need a checkout, development Node or Xcode.
- [ ] Separate immutable app resources from mutable Application Support data. Migrate existing installations with a backup and preserve pairing, keys, owner, chosen range, schedules and stop state.
- [ ] Launch and monitor Core from the installed app, with a clear recovery action. Preserve the current working developer service until the replacement passes isolated checks.
- [ ] Centralize app/Core build versions and record compatible data/protocol versions.
- [ ] Prove operation from a copied app in a path containing spaces, with the original checkout and development runtime unavailable.
- [ ] Test install, login restart, crash recovery, update, rollback and uninstall with saved-data retention.
- [ ] Prepare the signing, notarization and distribution route. A local development signature is not a distributable beta installer.

## B3 — First-time pairing

Status: QR and manual pairing exist; fresh-account acceptance is outstanding.

- [ ] Walk a new user through private networking on both devices, permissions, pairing, range and key entry.
- [ ] Explain mismatched accounts, disconnected VPN, offline Core, expired/reused codes and a revoked phone with actionable messages.
- [ ] Verify cellular connection and reconnection on a different network.
- [ ] Make controlling-device transfer explicit. Pairing another device must never accidentally grant control.
- [ ] Keep Core on loopback and use private HTTPS only. No public Funnel or unauthenticated port forwarding.

The invited beta may document Tailscale as a prerequisite. Do not advertise “download two apps and done” while it needs additional setup. A transport replacement needs its own decision and security review.

## B4 — Trust, provider keys and costs

Status: Ranges, owner checks, Keychain keys, Stop and takeover exist. Beta acceptance and optional budgets remain.

- [ ] Exercise out-of-range actions, role changes, owner revocation, stop, takeover, stale requests and scheduled work at execution time.
- [ ] Explain where screenshots/task content go and what Full Mac permits before activation.
- [ ] Add opt-in task/daily budgets with pre-request reservations, concurrent-work accounting, crash handling and tests for exhausted budgets. Preserve Matthew’s existing no-cap configuration unless he changes it.
- [ ] Show estimated usage and actionable quota, invalid-key, rate-limit and network errors. Usage estimates are not provider invoices.
- [ ] Verify selected-provider functionality separately. Mocked OpenAI tests are not proof of a live OpenAI account working.
- [ ] Review key removal, phone revocation and saved-data deletion, including outstanding jobs and schedules.

No model makes an authorization decision. Do not add unrestricted shell execution or weaken containment to satisfy a task.

## B5 — Release candidate and invited trial

Status: Not started.

- [ ] Verify VoiceOver, larger text, Reduce Motion, Increase Contrast and light/dark mode on the shipping screens.
- [ ] Finish privacy text, permission explanations, known limitations, feedback instructions and update/rollback documentation.
- [ ] Install on a second Mac/account without developer tools and record first-run results.
- [ ] Choose and verify the actual Mac/iPhone distribution route against current platform requirements. No App Store/TestFlight approval is assumed.
- [ ] Tag a tested release candidate, distribute to 5–10 invited testers and track setup completion, task success, recovery and takeover. Collect private content only with explicit consent.

## How agents maintain this plan

Work in milestone order where dependencies apply; continue independent engineering while physical-device checks wait for Matthew. Mark checkboxes only after the stated acceptance test passes. Update the tracker, `HANDOFF.md` and `CHANGELOG.md` at each meaningful checkpoint. Preserve failed results and limitations, never replace them with “should work.”
