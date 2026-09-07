# Changelog

## 0.4.1 - 2026-09-07

- Add opt-in task sealing for exact clean Git revisions/trees, context, and artifact SHA-256 digests.
- Verify sealed inputs before dispatch, immediately after claim, after execution and release hooks, and whenever task state is read; surface drift as
  `STALE` without claiming a hand or allowing a stale successful review to remain `END`.
- Write one immutable result per sealed task, bind handoff/run-log hashes into its receipt, and carry the
  input digest through worker environment, events, and ledger rows.
- Expose current, stale, and unbound task-input state through the CLI and MCP while preserving legacy tasks.
- Report account utilization as remaining capacity consistently across status and routing surfaces.
- Keep first-run output focused on the three required account/login/hand steps; make `task show` human-first
  and print exact replacement commands when evidence becomes stale.

## 0.4.0 - 2026-09-07

- Add multi-account Claude, Codex, Cursor, API-key, and local-model routing.
- Add model discovery, probing, availability recovery, and per-run model and effort overrides.
- Add detached parallel runs, durable claims, event hooks, handoffs, and MCP access.
- Track vendor utilization windows, token usage, metered cost, and subscription-equivalent cost.
- Isolate vendor logins and keep credentials outside the portable `.deck/` protocol directory.
- Add portable end-to-end coverage for macOS and Linux, including account, routing, recovery,
  concurrency, usage, and MCP behavior.
- Serialize per-hand claims so concurrent detached tasks cannot erase or share one another's lease.
- Pin release installation and verify the CLI checksum before replacement.
