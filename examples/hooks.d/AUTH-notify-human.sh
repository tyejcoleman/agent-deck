#!/bin/sh
# Fires when an account flips between usable and needs-login. The event's msg already contains the exact
# command for the human ("run: deck account login <id>"); forward it wherever the human reads.
# Replace the last line with a bot ping, a webhook, `osascript -e 'display notification ...'`, etc.
MSG=$(python3 -c 'import json,sys; e=json.load(sys.stdin); print(("OK " if e.get("ok") else "LOGIN NEEDED ") + e.get("account","") + ": " + e.get("msg",""))')
printf '%s %s\n' "$(date -u +%FT%TZ)" "$MSG" >> "$DECK_ROOT/../deck-wake.log"
