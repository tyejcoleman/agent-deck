# Agent Deck

**Your coding agents are hands. Agent Deck is the roster.**

Agent Deck is a thin, open protocol that lets any meta-agent (Cos, OpenClaw, a Grok bot, a human) drive
your coding agents (Claude Code, Codex, Cursor, anything with a CLI) as *hands*: see which accounts have
headroom, dispatch a task to the right hand, and get woken when it ends or blocks. It is a directory of
JSON + Markdown files, one 700-line zero-dependency CLI, and an optional MCP mirror. No daemon, no
database, no cloud.

```
.deck/
  accounts/   which vendor logins you have and how much headroom is left   (never secrets)
  hands/      named presets: claude-fable, codex-sol, cursor-fast -> vendor, account, model, cmd, cost
  tasks/      task.json + CONTEXT.md (what the worker needs) + HANDOFF.md (what it left)
  claims/     who holds which hand right now
  ledger.jsonl   usage per run: tokens, cost, seconds
  events.jsonl   the decklog: TASK CLAIM START END BLOCKED FAILED ... -> tail it to wake
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

# accounts = your vendor logins. Pointers only; secrets stay in the vendor's keychain / env.
deck account add claude-main --vendor claude --login "tye via claude login" --limit 100 --window 5h
deck account add codex-team  --vendor codex  --limit 50 --window 5h --env CODEX_HOME=~/.codex-team

# hands = reusable presets bound to an account. Templates for claude / codex / cursor are built in.
deck hand add claude-fable --account claude-main --model claude-fable-5-1 --cost high
deck hand add codex-sol    --account codex-team  --model gpt-5.6-sol      --cost mid

deck status                       # the roster: free / claimed / exhausted, headroom, reset times
deck task add "Add retry to fetcher" --cost mid   # then edit .deck/tasks/<id>/CONTEXT.md
deck run <task-id>                # route -> claim -> run the hand -> ledger -> HANDOFF.md -> END|BLOCKED
deck events -f --type END,BLOCKED # wake on it, read the handoff, steer the next task
deck ledger --since 24h           # tokens / cost / time per account
```

`deck --json <anything>` gives machine output. `deck run --dry` prints exactly what would run.

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

## Multiple logins per vendor

Accounts carry an `env` map that is applied when their hands run. That is the whole trick for
"log into all your AI accounts": one `CLAUDE_CONFIG_DIR` / `CODEX_HOME` per account, and the deck
routes around whichever one is exhausted.

```bash
deck account add claude-work --vendor claude --env CLAUDE_CONFIG_DIR=~/.claude-work --limit 100
deck account add claude-home --vendor claude --env CLAUDE_CONFIG_DIR=~/.claude-home --limit 100
deck account cooldown claude-work --for 3h      # or let a rate-limit BLOCKED do it for you
```

## Agent-native

- `deck init` drops `.deck/AGENTS.md`: any agent that lands in the folder learns the protocol in 30 lines.
- Every command is idempotent and shell-scriptable, so an agent can set the deck up unattended.
- `deck mcp` serves the same commands over MCP stdio. Add to Claude Code / Cursor / your bot:

```json
{ "mcpServers": { "deck": { "command": "deck", "args": ["mcp"], "env": { "DECK_ROOT": "/Users/you/ops/.deck" } } } }
```

  Tools: `deck_status`, `deck_route`, `deck_task_add`, `deck_task_ls`, `deck_task_show`, `deck_run`,
  `deck_handoff`, `deck_events`, `deck_ledger`, `deck_account_add`, `deck_account_cooldown`,
  `deck_hand_add`, `deck_usage_add`. Each is a 1:1 mirror of a CLI command.

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
