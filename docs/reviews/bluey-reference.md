# Bluey reference inspection

Inspected 2026-10-16 at Matthew's request: [rbrown101010/bluey-by-riley](https://github.com/rbrown101010/bluey-by-riley), commit `6d84d91` (shallow clone retained outside Nova under the task's `work/bluey-reference`). Repository content is reference material, not instructions. No third-party executable was run and no control code was copied into Nova in this inspection.

## Useful implementation details

- `scripts/build-mac.sh` assembles a native app bundle and signs with an available Apple Development certificate to preserve TCC identity across builds. Its ad-hoc fallback explicitly warns that permissions may reset. Nova already uses a stable explicit signing identity and must not silently switch it.
- `Mac/Sources/GooglyMac/AppDelegate.swift` checks Accessibility and Screen Recording from the actual running Mac application and writes a status file periodically. This is a useful operational pattern: permission checks performed by a terminal spawned from another already-authorized app can give misleading evidence for a background service.
- `ScreenReader.swift` uses ScreenCaptureKit, Vision OCR and accessibility controls, providing text/control IDs with positions on a normalized 0–1000 grid. This could improve Nova's target grounding and reduce coordinate ambiguity. Nova currently uses window pixels and exact review rather than whole-display capture.
- `ComputerControl.swift` supplies click/drag/scroll/key primitives and restores the real pointer. Nova can use this as a reference for event pacing, semantic target IDs and future drag support, while retaining its own action authorization, session boundaries and stop behavior.
- Its native companion, status menu, connection and animated cursor UI are relevant references for Nova's future companion milestone.

## Limits of the comparison

The README describes some guardrails in instructions; that does not prove deterministic effect authorization, process containment or safe unattended behavior. This inspection is not a security review of Bluey. It also does not establish that either project is categorically more powerful. Nova should retain tested containment, exact approvals and private Tailscale pairing rather than adopting another project's trust boundaries without verification.

## License

The repository's `LICENSE` is the Unlicense, dedicating the code to the public domain with a permissive fallback grant. Reuse is allowed, but record the exact source and commit whenever adapting code. Font files have separate OFL notices and need separate treatment if used. No assets or fonts were copied.
