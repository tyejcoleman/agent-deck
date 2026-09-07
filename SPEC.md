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
  tasks/<id>/RECEIPT.json   RECEIPT  exact sealed input verified before/after a review run
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

Headroom = the tightest window. Sources, in order of truth, **all local files, never the network, never a
token** (the same posture as [tokenroom](https://github.com/tyejcoleman/tokenroom) ADR-1):

1. **The vendor's own utilization numbers**, read from official surfaces. For Claude Code: `deck account tap
   <id>` wires `deck tap` as that login's statusline command; every render hands it the `rate_limits` payload
   (`five_hour`/`seven_day` `used_percentage`, `resets_at`), which it records under `~/.config/deck/usage/`
   keyed by login dir and echoes as a remaining-first HUD line (an existing statusline is chained, not
   replaced). Claude Code's own `cachedUsageUtilization` in `<home>/.claude.json` is the second reading;
   the fresher wins. These windows are authoritative (`metric: "%"`, limit 100) and show as
   `94% left of 5h (tap)` when 6% is used, with the reading's age once it is over two minutes old.
2. **The login's own session logs** (`<home>/projects/*.jsonl`, one record per turn): tokens and requests per
   window across every session, deduplicated by request id. Used for the token detail, and to estimate drift
   between readings: when a fresher reading lands, `tokens_per_pct` is learned from the tokens spent between
   the two; until the next reading, usage is shown as `≈` from tokens spent since — never presented as fact.
   A window whose `reset_at` has passed reads 0.
3. **The LEDGER** (deck's own runs) for vendors with neither, in the account's `metric` (`runs`, `tokens`,
   `usd`), against `limits`. `usage_cmd` + `deck account sync` can feed any other number.

For Codex the same role is played by the newest non-null `rate_limits` snapshot in the login's session
rollouts (`<home>/sessions/**/rollout-*.jsonl`) — lagging and often null in current builds, but official
and local. Every LEDGER row carries `billing`: `metered` (API keys, or a priced run on a dollar-denominated
allowance such as Cursor's Other Models pool), `equiv` (a flat subscription's API-equivalent value, e.g.
Claude's `total_cost_usd`), `local`, or `subscription`. Only `metered` dollars count toward a `usd` limit or
appear as spend; equivalents are displayed with `≈`.

On a rate-limit response the account cools down until the vendor's exact reset time when known (the tap's
`resets_at`, the epoch Claude Code appends to its limit message, or a "try again at 7:58 PM" / "resets in 2h"
hint parsed from the output), else a short default. `plan` is a
label for the research task (vendors without utilization surfaces). `price` computes `cost_usd`;
`monthly_usd` is informational. Observed on a Max account (2026-09-07): headless `claude -p` runs *did*
move the 5h window (3% → 5% after a $0.31 run); the deck asserts neither way — it reads the numbers.

**HAND** — `{"id", "vendor", "account", "model", "effort", "cost": "free|low|mid|high", "price", "cmd"}`.
`cmd` is a shell string. Placeholders: `{prompt}` (shell-quoted), `{context}`, `{handoff}`, `{taskdir}`
(absolute paths), `{task}`, `{model}` and `{effort}`. `{model}` expands *at run time* to the vendor's model
flag plus its effort flag (`--model X --effort high` / `-m X -c model_reasoning_effort=high` /
`--model 'X[effort=high]'`), so `deck run --model X --effort E` overrides a hand per run; precedence is
run flag → task field → hand default. Templates pass `--add-dir {taskdir}` so the worker may write
HANDOFF.md outside the repo. If `{prompt}` is absent, or the prompt exceeds 100KB (Linux caps one argv
string at 128KB), the prompt is piped to stdin. Reusable presets, not a registry: delete any hand nobody uses.

**TASK** — `{"id", "title", "status": "open|running|done|blocked|failed|stale", "cost", "needs": [...], "model",
"effort", "cwd", "hand", "runs", "pid", "created", "input"}`. `cost`/`needs`/`model` are routing preferences
(`needs` are matched against catalog `good_for` tags). `cwd` is where the worker runs (default: the
directory containing `.deck/`). `pid` is set while a run is live; a task whose runner died is reaped to
`failed` by the next `status`/`route`/`run`. An absent `input` is explicitly `unbound`: backward-compatible
work, but not immutable review evidence.

`deck task seal <id> --revision <ref> [--artifact <file> ...]` adds the immutable **INPUT** manifest after
`CONTEXT.md` is final and before the first run. With no arguments it defaults to `HEAD`; artifact-only
binding is also allowed. A revision seal resolves and records the Git repository, exact commit and tree,
and requires the checkout to be at that commit with no tracked or untracked changes. The manifest always
records the task cwd and `CONTEXT.md` SHA-256, records each artifact's absolute path and SHA-256, and signs
the canonical manifest with its own SHA-256 digest. A sealed task cannot be resealed, even before a run;
cannot be changed through `task set`; and has exactly one result. Create a new task so evidence identity
and its receipt are never rewritten. Deck prints the exact replacement-task and reseal commands.

Deck derives the input state whenever a task is shown, listed, summarized, dispatched, waited on, or read
through MCP:

- `current` — manifest digest, cwd, context, revision/tree/clean checkout, artifacts, and any receipted
  handoff/run log still match;
- `stale` — any of those checks differs or is unavailable; a formerly `done` task is surfaced as `stale`;
- `unbound` — no input manifest exists.

Dispatch rejects `stale` before claim, then rechecks after the synchronous CLAIM hook and immediately
before START; drift there releases the claim without worker execution or ledger activity. A bound run
exports `DECK_INPUT_DIGEST`, records it in START, the ledger, and the terminal event, then verifies again
after execution and synchronous RELEASE hooks before it may emit
END. If an otherwise successful run drifted, it emits STALE and returns the same attention exit class as
BLOCKED. This is fail-closed review validity, not source checkout locking; the worker may intentionally
change its inputs, but that run cannot certify them.

**RECEIPT** — `{"task", "run", "hand", "status", "input_digest", "verified_before", "verified_after",
"input_state", "revision", "tree", "artifacts", "issues", "handoff_path", "handoff_sha256",
"run_log_path", "run_log_sha256"}`. It is written for a bound run or manual
handoff after post-validation. It proves what was checked and when; it does not claim that unbound work is
validated. A manual handoff omits the run-log fields. Later input, handoff, or log drift leaves the
historical receipt intact while the task surface becomes stale.

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
"cost_usd", "seconds", "exit", "input_state", "input_digest"}`. `deck run` appends one per run and best-effort parses tokens from
vendor JSON output (`"input_tokens"`, `"output_tokens"`, `"total_cost_usd"`). Anything else records
usage with `deck usage add`.

**EVENT** — `{"ts", "type", "task", "hand", "by", "msg", ...}`. Types: `TASK` `SEAL` `CLAIM` `RELEASE`
`START` `END` `BLOCKED` `FAILED` `STALE` `COOLDOWN` `AUTH` `MODEL` `ACCOUNT` `HAND` `NOTE`. `AUTH` fires when an
account's usability flips (`ok: true|false`) and carries the exact fix (`run: deck account login <id>`);
it is the event a meta-agent forwards to the human. `MODEL` fires when a probe or a run learns a model
id is (un)available. Free to extend; keep them uppercase and short.

## 3. Lifecycle

```
meta: deck task add "…"  →  edit tasks/<id>/CONTEXT.md → optionally seal revision/artifacts
meta: deck run <task>    →  verify input → route → claim → run hand.cmd → verify input → receipt + ledger
                             → read HANDOFF.md → release → task.status → emit END | BLOCKED | FAILED | STALE
meta: wake on the event  →  read HANDOFF.md → steer: new task, re-run, or stop
```

Parallelism is the number of free hands: `deck route` lists them; `deck run t1 t2 t3 --bg` detaches one
run per task, each claiming its own hand; `deck wait t1 t2 t3` (or the events) collects them. Sequential
work is just `deck run` without `--bg`. There is no scheduler — the meta-agent decides how many to
dispatch by reading headroom, and the claim files make that decision safe across several meta-agents.

The worker is told (in its prompt and via `$DECK_CONTEXT`, `$DECK_HANDOFF`, `$DECK_TASK`, and, when bound,
`$DECK_INPUT_DIGEST`) to write
HANDOFF.md before exiting. If it doesn't, `deck run` writes a stub from the output tail so the
meta-agent always has something to read. Exit `0` without a handoff is `END`; non-zero is `FAILED`;
non-zero with rate-limit text in the output is `BLOCKED` and puts the account on cooldown. A worker
that cannot start (bad `cwd`, missing binary, timeout) is `FAILED` too. A successful bound run whose
inputs drift is `STALE`. In every case the claim is
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
