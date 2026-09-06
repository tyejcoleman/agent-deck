#!/bin/sh
# Post blocked tasks to a Slack/Discord-style webhook. Set DECK_WEBHOOK_URL in the environment that runs `deck run`.
[ -n "${DECK_WEBHOOK_URL:-}" ] || exit 0
MSG=$(python3 -c 'import json,sys; e=json.load(sys.stdin); print("BLOCKED %s on %s: %s" % (e.get("task"), e.get("hand","-"), e.get("msg","see HANDOFF.md")))')
curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"text\": \"$MSG\"}" "$DECK_WEBHOOK_URL" >/dev/null
