# Changelog

## 0.4.0 - 2026-09-07

- Add multi-account Claude, Codex, Cursor, API-key, and local-model routing.
- Add model discovery, probing, availability recovery, and per-run model and effort overrides.
- Add detached parallel runs, durable claims, event hooks, handoffs, and MCP access.
- Track vendor utilization windows, token usage, metered cost, and subscription-equivalent cost.
- Isolate vendor logins and keep credentials outside the portable `.deck/` protocol directory.
- Add portable end-to-end coverage for macOS and Linux, including account, routing, recovery,
  concurrency, usage, and MCP behavior.
- Pin release installation and verify the CLI checksum before replacement.
