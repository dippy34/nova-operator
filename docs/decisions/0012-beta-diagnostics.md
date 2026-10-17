# 0012. Read-only beta diagnostics with a minimal support report

Status: Proposed
Date: 2026-10-16
Proposed by: Codex

## Context

The iPhone previously timed out when its VPN was disconnected and later reported conversation-only access because its paired role differed from the Mac’s global range. A beta user needs specific recovery instructions without publishing private logs or giving a support tool new privileges.

## Decision

Implement a local Mac connection check shared by the CLI and native setup UI. Open the existing database read-only and query only setup fields and device counts. Do not use Store’s migration constructor. Test unauthenticated health and protected-route rejection over loopback and the private Tailscale HTTPS origin. Read the native helper’s permission status without screenshots or input. Do not change services, networking, permissions, ownership or stop state.

Construct the report from fixed messages, check IDs/statuses and validated runtime version/enumeration fields. Never include raw subprocess output, exceptions, server bodies, database rows, keys, codes, addresses, names, paths, prompts, screenshots or logs. Let the user preview and copy it; do not upload automatically.

## Alternatives considered

Exporting raw logs or a database would aid debugging but expose private tasks, pairing metadata and settings. Automatically repairing settings would blur a diagnostic check with granting access or resuming stopped work. Both are outside this milestone.

## Consequences

The same report can be reproduced and privacy-tested. It cannot establish phone reachability, provider account validity, real model task completion, OS containment or beta readiness. Keep those as separate acceptance tests. Future additional diagnostic fields require an explicit privacy review and regression tests.

## Objections

None recorded. Status remains Proposed; only Matthew changes decision records to Accepted or Rejected.
