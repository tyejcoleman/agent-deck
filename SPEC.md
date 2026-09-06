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

**ACCOUNT** — `{"id", "vendor", "login", "window": "5h", "limit": 100, "metric": "runs|tokens",
"cooldown_until", "env": {...}}`. `login` is a pointer ("tye@… via `claude login` on mac-mini"), never
a secret. `env` is applied to hands on this account when they run — this is how several logins of one
vendor coexist on one machine (e.g. `CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Headroom = `limit` minus usage
in the trailing `window` (from LEDGER). `cooldown_until` marks the account exhausted until that time.

**HAND** — `{"id", "vendor", "account", "model", "cost": "low|mid|high", "cmd"}`. `cmd` is a shell
string. Placeholders: `{prompt}` (shell-quoted), `{context}`, `{handoff}` (absolute paths), `{task}`.
If `{prompt}` is absent, the prompt is piped to stdin. Reusable presets, not a registry: delete any
hand nobody uses.

**TASK** — `{"id", "title", "status": "open|running|done|blocked|failed", "cost", "cwd", "hand",
"runs", "created"}`. `cost` is a routing preference. `cwd` is where the worker runs (default: the
directory containing `.deck/`).

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
`START` `END` `BLOCKED` `FAILED` `COOLDOWN` `ACCOUNT` `HAND` `NOTE`. Free to extend; keep them
uppercase and short.

## 3. Lifecycle

```
meta: deck task add "…"  →  edit tasks/<id>/CONTEXT.md
meta: deck run <task>    →  route → claim hand → run hand.cmd in task.cwd → parse usage → ledger
                             → read HANDOFF.md → release → task.status → emit END | BLOCKED | FAILED
meta: wake on the event  →  read HANDOFF.md → steer: new task, re-run, or stop
```

The worker is told (in its prompt and via `$DECK_CONTEXT`, `$DECK_HANDOFF`, `$DECK_TASK`) to write
HANDOFF.md before exiting. If it doesn't, `deck run` writes a stub from the output tail so the
meta-agent always has something to read. Exit `0` without a handoff is `END`; non-zero is `FAILED`;
non-zero with rate-limit text in the output is `BLOCKED` and puts the account on cooldown.

Workers driven by hand (interactive Claude Code, a human) close the loop with
`deck handoff <task> --status END --text "…"`.

## 4. Routing policy (not a DSL)

`deck route [--cost c] [--vendor v]` ranks free hands:

1. exclude claimed, cooling-down, or exhausted hands (account headroom ≤ 0), and vendor mismatches;
2. sort by cost-class distance from the requested `cost`, then most remaining headroom fraction,
   then least recently used.

`deck run` takes the first. No free hand → `BLOCKED` event with the earliest reset time. Anyone can
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

## 7. Non-goals

Scheduling, retries with backoff, multi-step DAGs, chat between hands, a UI, a database, a cloud.
If you need those, build them *on* the files — don't add them to the protocol.
