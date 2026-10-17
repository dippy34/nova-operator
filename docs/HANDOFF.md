# Nova agent handoff

Start here when continuing Nova with another AI agent. This file and the source on GitHub are the durable context; do not require access to the original chat.

Last updated: 2026-10-17 by Claude Code (B2 path resolver and packaging build mode). Read [AGENTS.md](../AGENTS.md), [PRODUCT-CONTEXT.md](PRODUCT-CONTEXT.md), [BETA-PLAN.md](BETA-PLAN.md) and [tracker #3](https://github.com/dippy34/nova-operator/issues/3) before editing. [CLAUDE-CODE-START.md](CLAUDE-CODE-START.md) has the ready-to-paste continuation task.

## Local project location

The canonical checkout is now `~/Projects/nova-operator`. The complete repository and ignored local data/signing configuration were moved together. Core and native Operator LaunchAgents were reinstalled from the new location, and the Mac app was rebuilt with the same signing identity and new paths; the Applications copy was updated. Existing pairing, access range, provider storage and Mac grants were retained. All 12 Mac diagnostic checks pass after relocation; SQLite integrity passes. Private rollback data and machine details stay in `.nova-data/` and ignored `CLAUDE.local.md`.

This is a development-folder relocation, not a self-contained distribution. B2 remains open. The root `CLAUDE.md` imports durable project context; no hidden chat transcript is needed. The existing Claude desktop app is installed on Matthew’s Mac; a standalone Claude CLI was not found. A local Claude Code environment named **Nova** has been created and selected for the new folder on `main`, with Worktree off. No coding task has been submitted by this transfer.

## Current objective and authority

Matthew requested a documented GitHub beta plan and hands-on implementation. Work on `main`, preserve concurrent Cursor/user changes and normal Git history, and never force-push. The immediate product is a native iPhone app paired privately to a Mac operator. Keep Nova’s own minimalist cyan smiley character and clear native controls; do not replace it with a Siri copy or a website.

Do not ask for routine implementation permission. Matthew must perform physical device interactions, sign-ins, signing account steps and OS security approvals when needed. No authorization exists to buy services, publish an App Store release or send messages to third parties. Do not create scheduled follow-ups unless requested.

## Actual state

- Shared native setup, access ranges, Keychain providers, UI and listening fixes were checkpointed as `ad1a84b` and pushed to `main`, retaining ten previously local commits. This preserves Cursor’s work along with Codex’s fixes; it is a prototype checkpoint, not a release endorsement.
- Core runs as a per-user login service. The signed Mac menu app runs separately and receives authenticated requests over an owner-only local Unix socket. Private remote connectivity uses Tailscale Serve; Core refuses non-loopback binding. Never use Funnel or public port forwarding.
- A real iPhone previously paired and ran Claude chat and wireless status requests. Matthew confirmed those flows. More recent Mac control/work capabilities include historical Cursor verification in `CHANGELOG.md`; do not reinterpret that as acceptance testing for every current combination.
- Matthew’s current iPhone was repaired as the controlling device while retaining Whole Mac range. Keep its current pairing, owner, range, keys, schedules and emergency-stop state. Never put actual device IDs, hostnames, account addresses or credentials in this public document.
- The latest iPhone listening fix is installed. Its last attempted automatic launch was blocked by the phone being locked. **Real speech smoothness, repeated cycles and glow cleanup still need a phone check.** Automated state tests do not measure frame rate or microphone behavior.
- The code supports Claude and OpenAI routes. Recent tests use mocks/local HTTP and make no paid model calls. Live OpenAI support has not been established by these checks.
- There is currently **no overall API spending cap**, by Matthew’s earlier choice. Optional beta budget controls are planned; do not silently enable a cap for his setup.
- B2 has started. `core/paths.mjs` is the one source of code/runtime/data locations for Core, CLI, login service, native build and owner tool; development paths are unchanged (`b6a86f2`). `npm run operator:package -- --out <dir>` builds a separate packaged app with an explicit Core file list, the pinned Node 24.19.0 arm64 runtime (checksum and Node.js Foundation Developer ID signature verified) and its license, audited against an exact file list. The packaged native executor derives its paths from its own bundle (`NovaLayout=app`). `npm run package:check` proves a copied app in a path with spaces runs Core/CLI with this checkout, development Node and live Nova data blocked by a sandbox.
- The **installed** Mac app is still the development build with absolute checkout/runtime/data paths; it was not rebuilt or replaced. The packaged app does not yet launch/monitor Core, migrate data or install a login item, and it is not signed for distribution or notarized. The local Apple Development signature is not a customer distribution solution.
- Known B2 collision: development and packaged builds both use `~/Library/Application Support/Nova Operator/operator.sock`, the native bundle ID `dev.nova.operator.macos` and the Core LaunchAgent label `dev.nova.operator.core`. Packaged data also defaults to that Application Support folder. Never run both installs at once; the migration step must stop and replace the development services deliberately, with rollback.
- B1 now adds a Mac connection check and a support report. The check reads existing setup without creating/migrating it, makes unauthenticated health/auth GETs on loopback and the private HTTPS origin, checks Tailscale and native permission status, and never changes settings or executes desktop actions. It does not validate a provider key or phone connectivity.

## Latest billing question

During the transfer Matthew asked whether Claude Code could use API billing instead of subscription session usage. This was a question; no billing/login/key changes or paid coding task were made. Nova itself already uses the existing Claude API key. [Claude Code authentication docs](https://code.claude.com/docs/en/authentication) document Console/API authentication in the standalone CLI and state that Desktop/cloud do not read `ANTHROPIC_API_KEY` or `apiKeyHelper`. The direct API-key path is therefore the CLI or an editor integration that wraps it, not setting an environment variable on the prepared Desktop environment. Existing project instructions and local files work with either frontend. Do not confuse Nova runtime billing, Claude Code subscription usage, Console purchased credits and Desktop extra usage. Confirm the desired frontend before changing this setup, and never print the existing key.

## Code map

| Location | Responsibility |
| --- | --- |
| `core/server.mjs`, `db.mjs` | Authenticated HTTP jobs, status/setup routes, SQLite journal, devices and persistent settings |
| `core/computer.mjs`, `policy.mjs` | Current owner checks, range enforcement, native execution, Stop and takeover |
| `core/agent.mjs`, `openai.mjs` | Provider agent loops; keep model planning separate from deterministic authorization |
| `core/ai.mjs`, `claude-worker.mjs` | Legacy conversation-only lane; non-owner phones may chat but cannot submit computer jobs |
| `core/work.mjs` | Background research, schedules, monitors, reports and optional iMessage delivery; do not test actual messaging without explicit authorization |
| `core/setup.mjs`, `tailscale.mjs`, `keys.mjs` | Pairing/setup status, private networking and provider keys |
| `core/diagnostics.mjs`, `diagnostics.test.mjs` | Read-only connection checks and privacy-filtered support report |
| `core/paths.mjs`, `paths.test.mjs` | Shared code/runtime/data locations; development vs packaged layout; `NOVA_DATA_DIR` isolation |
| `core/cli.mjs`, `service.mjs` | Local setup commands and development Core login service |
| `macos/Operator.swift` | Signed native executor, TCC permissions, menu/setup UI and support report buttons |
| `macos/build.mjs`, `install.mjs` | Development app build and per-user native login item |
| `macos/package.mjs`, `runtime.json`, `package.test.mjs`, `package-check.mjs` | Packaged-app build mode, pinned runtime, file audit and the copied-app sandbox acceptance check |
| `ios/NovaApp/NovaModel.swift` | Networking, fresh-role routing, voice coordination, listener/speaker lifecycle |
| `ios/NovaApp/VoiceCaptureState.swift`, `ios/VoiceTests/` | Generation-based recording state and meter mailbox; standalone regression tests |
| `ios/NovaApp/ContentView.swift`, `Theme.swift`, `Home.swift`, `Onboarding.swift` | Smiley face, lightweight listening-only glow, native navigation, setup and controls |

The listener’s audio levels do not publish through the whole page. A leaf view reads a locked meter at 15 Hz. Start/send transitions are exclusive; stale recognition callbacks cannot affect a new recording. Stop clears the listening state before final recognition waits. Keep these properties when editing voice code.

## Reproduce verification

Use the installed supported Node runtime (22.13+), full Xcode and local signing configuration where applicable. No npm dependency install is currently needed. On Matthew’s machine all shell invocations must be prefixed with `rtk`; see his local `/Users/matthew/.codex/RTK.md`. Other agents should obey their own environment instructions.

```sh
npm test
swift test --package-path ios --scratch-path /tmp/nova-voice-checks
node core/cli.mjs diagnostics --json
xcodebuild -project ios/Nova.xcodeproj -scheme Nova \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/nova-ios-build \
  CODE_SIGNING_ALLOWED=NO build
```

For B2 packaging, `npm run package:check` (about a minute; first run downloads the pinned Node archive to `~/Library/Caches/dev.nova.build/`) builds an ad-hoc-signed app in a temporary folder and runs the copied-app checks. It never touches services, the installed app or saved data. Ad-hoc signing there is only for the check.

For the signed Mac build, supply the existing local `NOVA_MAC_SIGN_IDENTITY` without committing it, run `npm run operator:build`, then run the built executable with `self-test`. Native protocol tests run only when this checkout has its built app and existing key and the helper is available; report any skipped tests. A fresh checkout must never create a key for another running installation. Do not grant permissions automatically or use an ad-hoc replacement identity that loses the working grants.

Use `npm run diagnostics` for human-readable results. The normal JSON report omits keys, codes, hostnames/IPs, account/device names, folder paths, task text, screenshots and raw logs. It is safe by construction for this defined set of fields; do not extend it by dumping objects or exception messages. Nothing uploads automatically. The Mac setup UI offers **Check Connection**, report preview and **Copy Support Report**.

## Latest verification

These checks ran locally on 2026-10-16. Automated providers were mocked; no paid AI requests were made for this milestone. Outstanding items remain unverified.

| Check | Result |
| --- | --- |
| Shared prototype backend baseline | 63 tests passed; no skipped tests; local/mocked providers |
| Voice state/meter suite | 11 tests passed; no microphone or paid provider request |
| Signed native iPhone build | Succeeded for the checkpointed iPhone source; this does not prove live recording behavior |
| New diagnostics regression suite | 15 tests passed, including real loopback Core/auth, read-only DB checks, probe timeouts and privacy failures |
| Full suite after diagnostics integration | 78 tests passed; 0 failed, 0 skipped; includes running native protocol rejection tests |
| Updated signed Mac app build/self-test | Built and signed with the existing local identity; signature verification and native negative-key/range self-test passed; installed with Accessibility and Screen Recording retained |
| Running Mac’s connection check and UI | All 12 Mac checks passed. Native UI check, report preview, copy confirmation and individual accessibility elements verified. This does not verify phone/AI behavior |
| Isolated source checkout without private app/data/key files | 77 tests passed, 1 native integration test explicitly skipped. The initial clean-clone run failed because the old test created a missing local key; its prerequisite guard is fixed. The real installed checkout still passes all 78 tests, including native rejection checks |
| Projects relocation | Both LaunchAgents and both app configurations point to Projects; same signed Mac identity, native self-test and all 12 diagnostics pass; SQLite integrity and owner/range state preserved |
| Revalidation from the relocated checkout | All 78 backend tests and 11 voice tests passed; iOS unsigned build succeeded from the new path. No phone reinstall or live paid AI task was performed |
| B2 shared paths (2026-10-17, `b6a86f2`) | 87 backend tests passed, 0 skipped, including 9 path tests (Core and CLI from another folder against isolated data in a path with spaces). Live Core service restarted on the new code: 12/12 Mac checks. Installed native app not rebuilt |
| B2 packaging build mode (2026-10-17) | 92 backend tests passed, 0 skipped, 11 voice tests passed. `npm run package:check`: 9/9 — pinned runtime checksum/signature, exact file audit, no checkout path in configuration, sandbox negative controls, app-layout resolution in Core and native executor, development-bundle resolution unchanged, owner-only isolated data, Core start/401/clean stop. 12/12 live Mac checks afterwards |
| Real phone speech/Stop/takeover acceptance | Outstanding |

## Next bounded task

Implementation issue: [B2 #4](https://github.com/dippy34/nova-operator/issues/4). Done so far: shared paths and a packaged-app build mode with a copied-app acceptance check (see Latest verification).

Next: **launch and monitor the bundled Core from the packaged app, and migrate data with rollback — against temporary data only.**

1. Decide how the packaged app runs Core: the native app supervising the bundled runtime, or a packaged login item. Either way resolve the socket, bundle ID and LaunchAgent label collision listed under Actual state, and record it in a decision record.
2. Add a migration command that copies development `.nova-data` (database file set, operator key, nonces) to Application Support with a backup and integrity check, and a rollback that restores the development install. Test it only with temporary `HOME`/data. Never move Matthew’s live data until the replacement passes and he is told.
3. Add a database schema version and centralize app/Core versions (currently package 0.1.0, health 0.1.0, native app 0.2.0).
4. Extend `package:check` to login restart, crash recovery, update over an older package, rollback and uninstall with retained data.

Still open beyond that: Intel/universal runtime (arm64 only today), GPG verification of Node’s checksum list (verify — only the pinned SHA-256 and Developer ID signature are checked), hardened runtime/notarization/distribution, and real TCC behavior of a packaged executor. Physical-device checks can remain outstanding while this independent work proceeds. For a fresh agent on a different computer, no device access or current credentials should be assumed.

## Handoff protocol

At every meaningful checkpoint: update this file’s actual state and verification, update beta checkboxes with evidence, add a `CHANGELOG.md` row, commit only understood source changes, and update tracker #3 with links. Record commit IDs and remaining checks. Inspect fresh Git status first because Cursor and Matthew also edit this repository. Keep private local configuration out of source control. Read the historical Phase 1 docs as historical checkpoints, not a current capability list.
