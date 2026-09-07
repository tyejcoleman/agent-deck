# Agent Deck — Protocol Spec (v1)

*Your coding agents are hands. Agent Deck is the roster.*

Agent Deck is a **directory**, not a service. A meta-agent (Cos, OpenClaw, a Grok bot, a human) reads the
deck to see which coding-agent "hands" are free, dispatches a task to one, and gets woken when the hand
ends or blocks. Workers (Claude Code, Codex, Cursor, anything with a CLI) do the actual work.

Design rules: files first · JSON + Markdown only · no daemon, no DB, no hosted plane · the CLI only
saves keystrokes · anything not read weekly gets cut.

## 1. Layout

```
.deck/
  deck.json                 {"version": 1, "name": "..."}
  AGENTS.md                 written by `deck init`; onboarding for any agent that lands here
  accounts/<id>.json        ACCOUNT  vendor login pointer + rate window (never secrets)
  hands/<id>.json           HAND     named worker preset bound to an account
  tasks/<id>/task.json      TASK     what to do, status, which hand, run count
  tasks/<id>/CONTEXT.md     CONTEXT  what the worker needs to start (markdown)
  tasks/<id>/HANDOFF.md     HANDOFF  what the worker left for the meta-agent (markdown)
  tasks/<id>/runs/<n>.log   raw worker output per run
  claims/<hand>.json        CLAIM    lease on a hand: who, which task, until when
  ledger.jsonl              LEDGER   one row per run: units, tokens, seconds, cost
  events.jsonl              EVENT    append-only decklog; `tail -f` it to wake
  hooks.d/<TYPE>-*          optional executables run on matching events
```

Root discovery: `$DECK_ROOT`, else the nearest `.deck/` walking up from cwd. Hosting = wherever the
folder lives (git, SSH, Syncthing, a VPS). Two machines sharing the folder share the deck.

## 2. Records

All records are flat JSON objects with an `id`. Unknown keys are preserved; add what you need.

**ACCOUNT** — `{"id", "vendor", "auth": "oauth|apikey|none", "env": {...}, "key_env", "base_url",
"limits": {"5h": 200, "1w": 1000}, "metric": "runs|tokens", "price": {"in": 3, "out": 15},
"monthly_usd", "check": {"ok", "at", "msg"}, "cooldown_until", "login", "usage_cmd", "status_cmd",
"login_cmd"}`. The record never contains a secret:

- `oauth` — the vendor CLI owns the login (Claude Code, Codex, Cursor, Gemini). `env` points its
  config-dir variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `CURSOR_CONFIG_DIR`, `GEMINI_CLI_HOME`) at
  `~/.config/deck/homes/<id>` (mode 0700), so any number of logins per vendor coexist and tokens
  refresh themselves as long as that dir persists. `deck account login <id>` runs the vendor's login
  (browser, or device code / paste-URL with `--headless`) — a human step by design.
- `apikey` — deck keeps the key in the OS keychain (macOS `security`, Linux `secret-tool`, else a 0600
  file under `~/.config/deck/secrets/`) and injects it as `key_env` into the worker's environment
  only. `deck account login <id>` reads it from a hidden prompt, `--from-env`, `--from-file` (then
  deleted), or a pipe. `DECK_SECRET_<ID>` in the environment overrides the store (CI).
- `none` — local servers (Ollama, LM Studio); `base_url` is health-checked and models are listed.

`check` is the cached result of `deck account check` (login status command, key presence, or HTTP
health) — refreshed by `deck run` when stale or failing, so a run never burns a claim on a dead login.
A worker that reports an auth failure flips `check.ok` to false (for API keys, the rejected key's
fingerprint is remembered until a different key is stored). Hands on such an account show
`needs-login` (or `down`) and are excluded from routing.

Headroom = tightest of the `limits` windows, measured in the account's `metric` (`runs`, `tokens`, `usd`).
Three sources, most truthful wins: (1) **the vendor CLI's own session logs** on that login — Claude Code
writes one JSONL record per assistant turn under `<home>/projects/`; deck sums tokens and requests per
window across *every* session on the login (interactive included), deduplicated by request id — this is the
default metric (`tokens`) for such vendors; (2) the LEDGER (deck's own runs) for everything else; (3) an
optional `remote` reading from `deck account sync` via `usage_cmd`. `plan` names the subscription tier so the
weekly research task can fill `limits` with the vendor's published/observed quota; until then headroom shows
absolute usage ("1.4M tok in 5h (all sessions)") rather than a percentage. `price` (USD per 1M tokens)
computes `cost_usd` for runs whose vendor reports tokens but no cost. `monthly_usd` is informational.

**HAND** — `{"id", "vendor", "account", "model", "effort", "cost": "free|low|mid|high", "price", "cmd"}`.
`cmd` is a shell string. Placeholders: `{prompt}` (shell-quoted), `{context}`, `{handoff}`, `{taskdir}`
(absolute paths), `{task}`, `{model}` and `{effort}`. `{model}` expands *at run time* to the vendor's model
flag plus its effort flag (`--model X --effort high` / `-m X -c model_reasoning_effort=high` /
`--model 'X[effort=high]'`), so `deck run --model X --effort E` overrides a hand per run; precedence is
run flag → task field → hand default. Templates pass `--add-dir {taskdir}` so the worker may write
HANDOFF.md outside the repo. If `{prompt}` is absent, or the prompt exceeds 100KB (Linux caps one argv
string at 128KB), the prompt is piped to stdin. Reusable presets, not a registry: delete any hand nobody uses.

**TASK** — `{"id", "title", "status": "open|running|done|blocked|failed", "cost", "needs": [...], "model",
"effort", "cwd", "hand", "runs", "pid", "created"}`. `cost`/`needs`/`model` are routing preferences
(`needs` are matched against catalog `good_for` tags). `cwd` is where the worker runs (default: the
directory containing `.deck/`). `pid` is set while a run is live; a task whose runner died is reaped to
`failed` by the next `status`/`route`/`run`.

**CATALOG** (`models.json`) — `{"updated", "synced", "models": {"<id>": {"vendor", "available",
"seen", "good_for": [...], "efforts": [...], "cost", "context", "notes"}}}`. Scoped to the vendors you
have accounts for. Two freshness loops, both lazy: **sync** (`deck models sync`, auto when older than a day)
asks every account that can enumerate — Cursor (`cursor-agent models`), API-key accounts (`/models`
endpoints), local servers — and flips `available`; **research** (`deck models refresh --if-stale`, weekly)
creates a cheap TASK whose worker reads the vendors' docs, verifies ids with `deck models probe` (one tiny
real call), and writes entries via `deck models set`. Hands whose model is `available: false` show
`no-model` and are skipped by routing. A run that hits a model error marks the model, emits `MODEL`,
dispatches the research task detached, and re-routes the task once without that model.

**CONTEXT.md / HANDOFF.md** — free markdown. HANDOFF should carry these headings so any agent can
skim it: `## Status` (`END` or `BLOCKED`), `## What changed`, `## Open questions`, `## Next step`.

**CLAIM** — `{"hand", "task", "by", "since", "until"}`. A hand with a live claim (now < `until`) is
not free. Claims are created exclusively (`O_EXCL`), so two meta-agents can share a deck safely.
Expired claims are ignored and overwritten.

**LEDGER row** — `{"ts", "account", "hand", "task", "run", "units": 1, "tokens_in", "tokens_out",
"cost_usd", "seconds", "exit"}`. `deck run` appends one per run and best-effort parses tokens from
vendor JSON output (`"input_tokens"`, `"output_tokens"`, `"total_cost_usd"`). Anything else records
usage with `deck usage add`.

**EVENT** — `{"ts", "type", "task", "hand", "by", "msg", ...}`. Types: `TASK` `CLAIM` `RELEASE`
`START` `END` `BLOCKED` `FAILED` `COOLDOWN` `AUTH` `MODEL` `ACCOUNT` `HAND` `NOTE`. `AUTH` fires when an
account's usability flips (`ok: true|false`) and carries the exact fix (`run: deck account login <id>`);
it is the event a meta-agent forwards to the human. `MODEL` fires when a probe or a run learns a model
id is (un)available. Free to extend; keep them uppercase and short.

## 3. Lifecycle

```
meta: deck task add "…"  →  edit tasks/<id>/CONTEXT.md
meta: deck run <task>    →  route → claim hand → run hand.cmd in task.cwd → parse usage → ledger
                             → read HANDOFF.md → release → task.status → emit END | BLOCKED | FAILED
meta: wake on the event  →  read HANDOFF.md → steer: new task, re-run, or stop
```

Parallelism is the number of free hands: `deck route` lists them; `deck run t1 t2 t3 --bg` detaches one
run per task, each claiming its own hand; `deck wait t1 t2 t3` (or the events) collects them. Sequential
work is just `deck run` without `--bg`. There is no scheduler — the meta-agent decides how many to
dispatch by reading headroom, and the claim files make that decision safe across several meta-agents.

The worker is told (in its prompt and via `$DECK_CONTEXT`, `$DECK_HANDOFF`, `$DECK_TASK`) to write
HANDOFF.md before exiting. If it doesn't, `deck run` writes a stub from the output tail so the
meta-agent always has something to read. Exit `0` without a handoff is `END`; non-zero is `FAILED`;
non-zero with rate-limit text in the output is `BLOCKED` and puts the account on cooldown. A worker
that cannot start (bad `cwd`, missing binary, timeout) is `FAILED` too. In every case the claim is
released and the task leaves `running` — a run never leaves the deck half-updated.

Workers driven by hand (interactive Claude Code, a human) close the loop with
`deck handoff <task> --status END --text "…"`.

## 4. Routing policy (not a DSL)

`deck route [--cost c] [--vendor v]` ranks free hands:

1. exclude claimed, needs-login/down/no-model, cooling-down, or exhausted hands (account headroom ≤ 0),
   and vendor mismatches (a task's `model` implies its vendor via the catalog);
2. sort by: hand already on the requested model, then overlap of catalog `good_for` with the task's
   `needs`, then cost-class distance from the requested `cost`, then most remaining headroom fraction,
   then least recently used.

`deck run` claims the first hand whose claim sticks (losing a race to another meta-agent just means
trying the next one). No free hand → `BLOCKED` event with the earliest reset time. Anyone can
implement a different policy by reading the same files; the CLI's version is ~20 lines.

## 5. Wake

`events.jsonl` is the bus. Two ways to wake a meta-agent, both optional:

- `deck events -f` (or `tail -f .deck/events.jsonl`) — filter on `END|BLOCKED|FAILED`.
- `hooks.d/` — any executable whose name starts with an event type (`END-ping-cos.sh`) or `any-` runs
  on that event with the JSON on stdin and `DECK_EVENT`, `DECK_EVENT_TYPE`, `DECK_TASK`, `DECK_HAND`,
  `DECK_ROOT` in the environment. 60s timeout, failures are logged, never fatal.

## 6. MCP (optional mirror)

`deck mcp` serves the same commands over MCP stdio so Claude Code / Cursor / Grok bots can use the deck
without learning the CLI. Every tool maps 1:1 to a CLI invocation and returns its `--json` output.
The files stay the protocol; MCP is convenience.

## 7. Security posture

`.deck/` is safe to sync and commit: it holds pointers, limits, and state, never credentials. OAuth
tokens live where the vendor CLI puts them (per-account dirs under `~/.config/deck/homes/`, 0700);
API keys live in the OS keychain or a 0600 file under `~/.config/deck/secrets/`. Secrets reach exactly
one place: the environment of the worker process that needs them. The CLI never prints them, `--json`
never includes them, and MCP exposes no login tool — logging in is a human action in a terminal, where
an agent may relay the printed URL / one-time device code but never sees a token.

## 8. Non-goals

Scheduling, retries with backoff, multi-step DAGs, chat between hands, a UI, a database, a cloud, a
token-refresh daemon (the vendor CLIs already do that). If you need those, build them *on* the files —
don't add them to the protocol.
