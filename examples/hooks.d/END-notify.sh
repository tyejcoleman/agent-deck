#!/bin/sh
# Fires on END. Copy as BLOCKED-notify.sh / FAILED-notify.sh too, or rename to any-notify.sh for everything.
# Event JSON is on stdin; DECK_EVENT_TYPE, DECK_TASK, DECK_HAND, DECK_ROOT are in the environment.
# Replace the last line with whatever wakes your meta-agent: a bot ping, `openclaw resume`, a curl, a tmux send-keys.
HANDOFF="$DECK_ROOT/tasks/$DECK_TASK/HANDOFF.md"
printf '%s %s task=%s hand=%s\n%s\n' "$(date -u +%FT%TZ)" "$DECK_EVENT_TYPE" "$DECK_TASK" "$DECK_HAND" "$(head -20 "$HANDOFF" 2>/dev/null)" >> "$DECK_ROOT/../deck-wake.log"
