# Nova agent handoff

Start here when continuing Nova with another AI agent. This file and the source on GitHub are the durable context; do not require access to the original chat.

Last updated: 2026-10-16 by Codex. Read [AGENTS.md](../AGENTS.md), [BETA-PLAN.md](BETA-PLAN.md) and [tracker #3](https://github.com/dippy34/nova-operator/issues/3) before editing.

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
- The Mac app still embeds absolute checkout/runtime/data paths. It is not a self-contained beta download, and the local Apple Development signature is not a customer distribution solution.
- B1 now adds a Mac connection check and a support report. The check reads existing setup without creating/migrating it, makes unauthenticated health/auth GETs on loopback and the private HTTPS origin, checks Tailscale and native permission status, and never changes settings or executes desktop actions. It does not validate a provider key or phone connectivity.

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
| `core/cli.mjs`, `service.mjs` | Local setup commands and development Core login service |
| `macos/Operator.swift` | Signed native executor, TCC permissions, menu/setup UI and support report buttons |
| `macos/build.mjs`, `install.mjs` | Development app build and per-user native login item |
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
| Real phone speech/Stop/takeover acceptance | Outstanding |

## Next bounded task

Start **B2: a self-contained Mac application** in an isolated output directory. First extract runtime/data path configuration so Core, the native helper, CLI and login service agree. Preserve the existing development defaults and the live install. Bundle only explicit runtime resources plus a pinned verified Node binary and its license. Never copy `.env.local`, `.nova-data`, signing files, private databases or Keychain contents into an app or archive.

The acceptance test must copy the app elsewhere and remove access to the source checkout/developer runtime. Test data migration, service startup/recovery and rollback against temporary data before touching Matthew’s real setup. A build that only works on his existing paths does not close B2.

Physical-device checks can remain outstanding while this independent work proceeds. For a fresh agent on a different computer, no device access or current credentials should be assumed.

## Handoff protocol

At every meaningful checkpoint: update this file’s actual state and verification, update beta checkboxes with evidence, add a `CHANGELOG.md` row, commit only understood source changes, and update tracker #3 with links. Record commit IDs and remaining checks. Inspect fresh Git status first because Cursor and Matthew also edit this repository. Keep private local configuration out of source control. Read the historical Phase 1 docs as historical checkpoints, not a current capability list.
