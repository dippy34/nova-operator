# Technical limitations

Most of the plumbing exists today. The hard parts are effect descriptors, long-horizon reliability, and a short list of things macOS deliberately prevents.

## Works today with existing technology

- Tailscale/WireGuard phone-to-Mac connection, APNs sent from the Mac, Secure Enclave signing gated by Face ID.
- Claude Code via the Agent SDK (`canUseTool`, hooks, sandboxing); Codex via app-server or SDK with its sandbox and approval policies.
- Playwright on a dedicated Chrome profile.
- AX on AppKit and SwiftUI apps, and on Electron apps once `AXManualAccessibility` is set; AppleScript on scriptable apps; `shortcuts run`; ScreenCaptureKit; CGEvent in an unlocked session.
- Seatbelt sandboxes, SQLite journaling, git worktrees, APFS local snapshots, Keychain, power assertions.

## Needs substantial engineering

- Effect descriptors and reconcile probes for every adapter operation. The single largest workload.
- Dynamic task graph with leases, crash recovery, and approval binding.
- Supervision logic: stuck detection, objective acceptance checks, budgets.
- Per-app adapters for the top apps.
- An approval UX that's actually reviewable on a phone (diffs, recipients, screenshots).
- An eval harness with repeatable missions.

## Unreliable but potentially achievable

- Vision-driven control of custom-drawn apps (Figma canvas, games, Unity, many Qt apps) over long tasks. Per-step errors compound over 50-step tasks.
- Supervising agents on tasks with no objective test ("make the UI nicer").
- Prompt injection resistance. Mitigable with taint tracking and containment; not solved anywhere.
- Context coherence over multi-hour missions.
- Websites with bot detection. Nova should stop at a CAPTCHA, not solve it.

## Prevented by macOS or third-party security

| Restriction | Why | Workaround |
| --- | --- | --- |
| Unlocking the Mac, or driving the host GUI while locked | No API; the lock screen requires user authentication by design | GUI work in a VM guest session |
| Granting itself permissions | TCC approvals need a user in System Settings. MDM PPPC can pre-grant Accessibility but can't silently grant Screen Recording (verify) | Preflight before each mission |
| Admin dialogs, Touch ID, passkeys, Apple Pay, Keychain prompts | Secure input and/or physical presence, built to resist synthetic input | Treat as automatic approval stops |
| Remote wake on battery | MacBooks sleep in clamshell mode on battery; wake-on-network is AC and local only; `pmset disablesleep` is undocumented and risky for heat | Checkpoint and pause; scheduled wakes |
| DRM-protected content | Appears blank in screen capture | None |
| App Store distribution | Sandboxed apps can't control other apps | Notarized Developer ID build |
| iOS background limits | No persistent background connection; no API for custom always-on wake words | APNs; foreground desk app |
| Screen Recording re-prompts | Behavior has changed across macOS 15.x and 26 (verify on target OS) | Detect in preflight |
| Chrome default-profile debugging | Recent Chrome blocks `--remote-debugging-port` on the default profile | Dedicated profile, or extension-based control |
| Third-party restrictions | Automation-forbidding terms, rate limits, apps that block accessibility | Respect and stop |
