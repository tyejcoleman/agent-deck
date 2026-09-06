<!-- Paste into the AGENTS.md / CLAUDE.md of any repo whose work is dispatched from an Agent Deck. -->

## Agent Deck

If `$DECK_TASK` is set, you were started by `deck run` as a worker hand.

- Your brief is in `$DECK_CONTEXT`. Read it first.
- When you finish or get stuck, write `$DECK_HANDOFF` with exactly these headings, then stop:

```markdown
## Status
END            <!-- or BLOCKED -->
## What changed
## Open questions
## Next step
```

- If you are running interactively instead (no `$DECK_TASK`), close your task with
  `deck handoff <task-id> --status END --text "<what changed / next step>"`.
- Never write secrets into `.deck/`.
