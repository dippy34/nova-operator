# 0005. Desk companion is a low-trust device that can never approve

Status: Proposed
Date: 2026-10-16
Proposed by: Claude

## Context

A spare iPhone sits on the desk showing an animated character with voice interaction. Anyone in the room can talk to it, and voice can't reliably identify the speaker.

## Decision

- The desk companion gets its own device key with an **observer** role.
- It can display status and submit voice **requests**, which go through normal planning and policy.
- Core rejects every grant, approval, or kill-switch-release signed by an observer key. This is enforced in Core, not just hidden in the UI.

## Alternatives considered

- **Voice approvals with speaker verification.** Rejected: spoofable, and a recording is enough.
- **Approvals on the desk device with Face ID.** Possible later, but the desk device is likely unattended and set up for convenience, not security.

## Consequences

- All approvals happen on Matthew's primary iPhone.
- The desk companion stays simple: foreground app, Guided Access, its own wake-word detector.

## Objections

None yet.
