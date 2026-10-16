# Nova Operator - implementation begins

**Phase 1 started on 2026-10-16.** This is the first runnable, intentionally limited implementation. The architecture and security decisions in `docs/` remain proposals until validated.

The Mac-side service and native iPhone app source are in `core/` and `ios/`. Instructions: **[docs/PHASE1-START.md](docs/PHASE1-START.md)**.

## Functional first slice

- Mac Core on `127.0.0.1:8787`, exposed privately with Tailscale Serve.
- One-time pairing code and iPhone Keychain credential storage.
- Native SwiftUI app, no web dashboard required.
- SQLite job/event history and a remote emergency stop.
- Hardcoded read-only Mac actions only. No model or unrestricted computer control yet.

## Try backend

```bash
npm test
npm run start
```

**Never port-forward the Node server publicly.** The current app intentionally lacks long-term signed capability tokens and executor sandboxing; those must be completed before enabling potentially destructive actions.
