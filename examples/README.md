# Examples

Copy what you need into your `.deck/`; delete the rest.

- `hands/` — presets for the three built-in vendors. `deck hand add` generates the same shape; these
  show what to edit (`cmd` placeholders: `{prompt}` `{context}` `{handoff}` `{task}`).
- `hooks.d/END-notify.sh` — wake a meta-agent on END/BLOCKED/FAILED. Rename the prefix to choose the
  event; `any-*` fires on everything. Must be executable.
- `hooks.d/BLOCKED-slack.sh` — post blocked tasks to a webhook.
- `hooks.d/AUTH-notify-human.sh` — forward "run: deck account login <id>" to wherever the human reads.
- `WORKER_SNIPPET.md` — paste into your repo's `AGENTS.md`/`CLAUDE.md` so workers know how to close a task.
