# Agent Deck

**Your coding agents are hands. Agent Deck is the roster.**

Agent Deck is a thin, open protocol that lets any meta-agent (Cos, OpenClaw, a Grok bot, a human) drive
your coding agents (Claude Code, Codex, Cursor, Gemini CLI, local models, anything with a CLI) as
*hands*: connect every subscription and API account you have once, see which one has headroom right
now, dispatch a task to the right hand, and get woken when it ends, blocks, or needs you to log in
again. It is a directory of JSON + Markdown files, one zero-dependency Python file, and an optional
MCP mirror. No daemon, no database, no cloud.

```
.deck/
  accounts/   every login you own: vendor, auth mode, rate windows, price, last check   (never secrets)
  hands/      named presets: claude-fable, codex-sol, cursor-fast, local-qwen -> account, model, cmd, cost
  tasks/      task.json + CONTEXT.md (what the worker needs) + HANDOFF.md (what it left)
  claims/     who holds which hand right now
  ledger.jsonl   usage per run: tokens, cost, seconds
  events.jsonl   the decklog: TASK CLAIM START END BLOCKED FAILED AUTH ... -> tail it to wake
  hooks.d/    optional executables that fire on events
```

Read [SPEC.md](SPEC.md) for the protocol (two pages). Everything below is the reference CLI.

## Install

One file, Python 3.8+, nothing else.

```bash
curl -fsSL https://raw.githubusercontent.com/tyejcoleman/agent-deck/main/install.sh | sh
# or: curl -fsSLo ~/.local/bin/deck https://raw.githubusercontent.com/tyejcoleman/agent-deck/main/deck && chmod +x ~/.local/bin/deck
```

Works on a Mac, a VPS, a box under your desk. Hosting the deck = wherever the folder lives; sync it
with git, SSH, or Syncthing and every machine sees the same roster.

## Sixty seconds

```bash
cd ~/ops && deck init

# accounts = every login you own. The record is a pointer; tokens stay with the vendor CLI / OS keychain.
deck account add claude-work --vendor claude --limit 200/5h --limit 1000/1w --monthly-usd 200 --now
deck account add codex-team  --vendor codex  --limit 50/5h --now
deck account add anthropic   --vendor claude --auth apikey --price 3/15 --now     # hidden key prompt
deck account add ollama      --vendor ollama                                       # local, free

# hands = reusable presets bound to an account. Templates for every vendor above are built in.
deck hand add claude-fable --account claude-work --model claude-fable-5-1 --cost high
deck hand add codex-sol    --account codex-team  --model gpt-5.6-sol      --cost mid
deck hand add local-qwen   --account ollama      --model qwen3-coder:30b

deck status                       # the roster: free / claimed / exhausted / needs-login, headroom
deck task add "Add retry to fetcher" --cost mid   # then edit .deck/tasks/<id>/CONTEXT.md
deck run <task-id>                # route -> claim -> run the hand -> ledger -> HANDOFF.md -> END|BLOCKED
deck events -f --type END,BLOCKED,AUTH   # wake on it, read the handoff, steer the next task
deck ledger --since 24h           # tokens / API cost / time per account + subscription $/mo
```

`deck <command> --json` gives machine output. `deck run --dry` prints exactly what would run.

## Accounts: connect everything once

An agent can set up every account (`deck account add`); only a human ever logs in. Three auth modes:

| mode | who holds the credential | how you log in |
|---|---|---|
| `oauth` (Claude Code, Codex, Cursor, Gemini subscriptions) | the vendor CLI, in a per-account dir `~/.config/deck/homes/<id>` (0700) | `deck account login <id>` → browser. `--headless` on a VPS → device code / URL you finish on your phone |
| `apikey` (Anthropic, OpenAI, Google, Cursor API; any custom `--key-env`) | OS keychain (macOS), `secret-tool` (Linux), else a 0600 file under `~/.config/deck/secrets/` | `deck account login <id>` → hidden prompt, or `--from-env VAR`, `--from-file F` (deleted after), or a pipe |
| `none` (Ollama, LM Studio, any `--base-url`) | nobody | `deck account check <id>` pings it and lists models |

Because each account gets its own config dir, you can hold several Claude / Codex / Cursor logins on one
machine and the deck routes around whichever is exhausted. Tokens refresh themselves for as long as the
vendor CLI keeps them; when one really expires:

1. the next `deck run` (or the worker's own error) flips the account to `needs-login`, emits an `AUTH`
   event with the exact command, and routes the task to another free hand if there is one;
2. your meta-agent forwards that one line to you: `deck account login claude-work`;
3. you run it (or `--headless` and tap the URL on your phone); the deck re-checks, emits `AUTH ok: true`,
   and the blocked work resumes.

Nothing in `.deck/` is ever a secret, so the folder is safe to sync and commit. `deck account check`
refreshes state without touching credentials; `deck account logout` drops a login or key.

## Costs and headroom

- Subscription windows: `--limit 200/5h --limit 1000/1w` (repeatable). The tightest window governs;
  `deck status` shows used/limit and the reset time. Estimates come from the deck's own ledger — if you
  also use the account outside the deck, give it a `--usage-cmd` that prints the vendor's numbers and run
  `deck account sync`.
- API accounts: `--price IN/OUT` in USD per 1M tokens (on the account or the hand) turns parsed tokens
  into `cost_usd`; Claude's own `total_cost_usd` is used when present.
- `--monthly-usd` on subscriptions shows up as a footer in `deck ledger`, so API spend and fixed
  subscription spend sit side by side.
- Local models are cost class `free` and rank first when a task asks for `--cost free`.

## How the loop works

1. **Meta-agent** writes a task + `CONTEXT.md` (or asks a worker to).
2. `deck run` picks a hand by policy: free, account has headroom, closest cost class, most headroom left,
   least recently used. It claims the hand (exclusive file, so two meta-agents can share a deck).
3. The hand's `cmd` runs in the task's `cwd` with the prompt + context. The worker is told to write
   `HANDOFF.md` (`## Status` END|BLOCKED, `## What changed`, `## Open questions`, `## Next step`) and
   gets `$DECK_CONTEXT`, `$DECK_HANDOFF`, `$DECK_TASK` in its environment.
4. `deck run` records a ledger row (tokens parsed from vendor JSON where available), releases the claim,
   sets the task status, and emits `END`, `BLOCKED` (rate-limit text detected → account cooldown), or
   `FAILED`. If the worker didn't write a handoff, a stub with the output tail is written so there is
   always something to read.
5. `hooks.d/END-*` / `hooks.d/BLOCKED-*` fire (ping Cos, post to Slack, whatever), and
   `deck events -f` wakes anything tailing the log.

Workers you drive by hand (interactive Claude Code, yourself) close the loop with
`deck handoff <task> --status END --text "..."`.

## Agent-native

- `deck init` drops `.deck/AGENTS.md`: any agent that lands in the folder learns the protocol in 30 lines.
- Every command is idempotent and shell-scriptable, so an agent can set the deck up unattended.
- `deck mcp` serves the same commands over MCP stdio. Add to Claude Code / Cursor / your bot:

```json
{ "mcpServers": { "deck": { "command": "deck", "args": ["mcp"], "env": { "DECK_ROOT": "/Users/you/ops/.deck" } } } }
```

  Tools: `deck_status`, `deck_route`, `deck_task_add`, `deck_task_ls`, `deck_task_show`, `deck_run`,
  `deck_handoff`, `deck_events`, `deck_ledger`, `deck_account_add`, `deck_account_ls`,
  `deck_account_check`, `deck_account_cooldown`, `deck_hand_add`, `deck_usage_add`. Each is a 1:1
  mirror of a CLI command. There is deliberately no login tool: credentials never pass through an agent.

## Vendor templates

`deck hand add` seeds `cmd` from the account's vendor (verified against Claude Code 2.1, codex-cli 0.153,
cursor-agent 2026.09, gemini-cli 0.58). Edit `hands/<id>.json` freely; deck only cares about the placeholders.

| vendor | login isolation | cmd |
|---|---|---|
| claude   | `CLAUDE_CONFIG_DIR` | `claude -p --permission-mode acceptEdits --output-format json --model M {prompt}` |
| codex    | `CODEX_HOME` | `codex exec --sandbox workspace-write --skip-git-repo-check --json -m M {prompt}` |
| cursor   | `CURSOR_CONFIG_DIR` | `cursor-agent -p --force --output-format json --model M {prompt}` |
| gemini   | `GEMINI_CLI_HOME` | `gemini -p {prompt} --approval-mode yolo --output-format json -m M` |
| ollama   | — (`OLLAMA_HOST`) | `codex exec --oss --local-provider ollama … -m M {prompt}` |
| lmstudio | — | `codex exec --oss --local-provider lmstudio … -m M {prompt}` |

Usage is parsed structurally from the JSON output: Claude's `usage` + `total_cost_usd`, Codex's
`turn.completed.usage`, Gemini's `stats.models[*].tokens`. When a vendor emits no usage, the ledger row
still carries `units` and `seconds`; add tokens by hand with `deck usage add`.

## Testing

```bash
bash tests/smoke.sh      # end-to-end with fake hands; no vendor CLIs or credentials needed
```

Covers routing, claims under contention, END/BLOCKED/FAILED, rate-limit cooldown, timeouts, oversize
prompts, bad cwd, hooks, torn log lines, corrupt records, token-metric and multi-window headroom, oauth
and API-key login round trips with secrets kept out of `.deck/`, worker auth-failure detection, rejected
keys, local-server health, and an MCP round trip. Passes on Python 3.8 and 3.12.

## Anti-bloat rules

1. Files first. The deck works with `cat`, `jq`, and an editor; the CLI only saves keystrokes.
2. CLI only for what hurts by hand (claims, runs, ledger math).
3. MCP is an optional mirror of the same files, never the source of truth.
4. No daemon, no DB, no hosted dashboard.
5. If a primitive isn't read weekly in real use, cut it.

Non-goals: scheduling, DAGs, retries with backoff, chat between hands, a UI. Build those *on* the files.

## Related

Handoff kits and continuity templates exist (`agent-handoff-kit`, `agent-handover-protocol`,
`agentctx`) and heavier orchestrators exist. Agent Deck is the slice they leave out: multi-account
roster + usage ledger + routing + wake, as plain files a meta-agent can own.

## License

MIT
