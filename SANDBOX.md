# Agent Deck sandbox (Cursor cloud agents)

`.cursor/environment.json` makes any Cursor cloud agent working on this repo boot with `deck` and the four
vendor CLIs installed and the smoke suite already run. What it cannot carry across VMs is a login:
sandboxes are fresh each run.

Two ways to give a sandbox agent hands:

1. **Bring keys as secrets** (zero login). In Cursor → Cloud Agents → Secrets add e.g. `DECK_SECRET_ANTHROPIC`
   and `DECK_SECRET_OPENAI`; then in the sandbox: `deck account add anthropic --vendor claude --auth apikey`
   — the deck reads the key from the environment, never stores it, and `deck status` shows real `$`.
2. **Device-code login once per sandbox** (subscription). Tell the agent: "run `deck account login claude
   --headless` in tmux and give me the URL"; finish it on your phone. Tokens live only in that VM.

Everything else is identical to a laptop or a VPS: `deck init` in an ops folder, `deck account add`, `deck
hand add`, tasks, `deck run … --bg`, `deck events -f`. For a *persistent* deck use a machine you own — see
README "Hosting".
