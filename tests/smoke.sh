#!/usr/bin/env bash
# End-to-end smoke test using fake hands (no vendor CLIs needed). Run: bash tests/smoke.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HERE:$PATH" DECK_AGENT=test
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; exit 1; }
expect() { local code=$1; shift; set +e; "$@" >out.txt 2>&1; local got=$?; set -e; [ "$got" = "$code" ] || { cat out.txt; fail "$* (exit $got, wanted $code)"; }; }

deck init --name smoke >/dev/null
[ -f .deck/deck.json ] && [ -f .deck/AGENTS.md ] || fail init
deck init >/dev/null && pass "init idempotent"

deck account add fake --vendor custom --limit 2 --window 1h --env FOO=bar >/dev/null
deck account add other --vendor custom --limit 10 >/dev/null
deck hand add ok --account fake --cost low --cmd 'python3 -c "import os,sys; sys.stdin.read(); assert os.environ[\"FOO\"]==\"bar\"; open(os.environ[\"DECK_HANDOFF\"],\"w\").write(\"## Status\\nEND\\n## What changed\\nx\\n\"); print(\"{\\\"usage\\\":{\\\"input_tokens\\\":10,\\\"output_tokens\\\":5}}\")"' >/dev/null
deck hand add rl --account other --cost mid --cmd 'sh -c "echo rate limit reached; exit 1"' >/dev/null
deck hand add crash --account other --cost high --cmd 'sh -c "exit 3"' >/dev/null
deck hand add slow --account other --cost high --cmd 'sh -c "sleep 5"' >/dev/null
[ "$(deck route --cost low --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')" = ok ] && pass "route prefers cost match"

deck task add "first" --id t1 --cost low --text "## Goal
do it" >/dev/null
expect 0 deck run t1
grep -q '"tokens_in": 10' .deck/ledger.jsonl && pass "run END + ledger tokens"
grep -q '"type": "END", "task": "t1", "hand": "ok"' .deck/events.jsonl && pass "END event"
[ ! -e .deck/claims/ok.json ] && pass "claim released"

deck task add "second" --id t2 --cost low >/dev/null
expect 0 deck run t2 --hand ok
[ "$(deck status --json | python3 -c 'import json,sys; print([h["state"] for h in json.load(sys.stdin)["hands"] if h["id"]=="ok"][0])')" = exhausted ] && pass "account exhausted after limit"

deck task add "rl" --id t3 >/dev/null
expect 2 deck run t3 --hand rl
grep -q '"type": "COOLDOWN", "account": "other"' .deck/events.jsonl && pass "rate limit -> BLOCKED + cooldown"
deck account cooldown other --clear >/dev/null

deck task add "crash" --id t4 >/dev/null
expect 1 deck run t4 --hand crash
grep -q "FAILED (auto" .deck/tasks/t4/HANDOFF.md && pass "FAILED writes stub handoff"

deck task add "slow" --id t5 >/dev/null
expect 1 deck run t5 --hand slow --timeout 1s
grep -q "timeout after 1s" .deck/tasks/t5/HANDOFF.md && pass "timeout -> FAILED"

deck claim crash --task t4 --ttl 5m >/dev/null
expect 1 deck run t4 --hand crash --force
grep -q "is claimed by test" out.txt && pass "claimed hand refuses run"
deck release crash >/dev/null

deck task add "manual" --id t6 >/dev/null
deck handoff t6 --status BLOCKED --text "need creds" >/dev/null
[ "$(deck task show t6 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" = blocked ] && pass "manual handoff"

cat > .deck/hooks.d/END-hook.sh <<'EOF'
#!/bin/sh
echo "$DECK_EVENT_TYPE:$DECK_TASK" >> hook.log
EOF
chmod +x .deck/hooks.d/END-hook.sh
deck account cooldown fake --clear >/dev/null
deck account add fake --limit 0 >/dev/null
deck task add "hooked" --id t7 >/dev/null
expect 0 deck run t7 --hand ok
grep -q "END:t7" hook.log && pass "hooks fire on END"

deck account cooldown fake --for 1h >/dev/null; deck account cooldown other --for 1h >/dev/null
deck task add "nohand" --id t8 >/dev/null
expect 2 deck run t8
grep -q "no free hand" out.txt && pass "no free hand -> BLOCKED"

deck event NOTE --msg hi >/dev/null
[ "$(deck events --type NOTE -n 1 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["msg"])')" = hi ] && pass "events filter"

printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"deck_task_ls","arguments":{"status":"done"}}}' \
  | deck mcp | python3 -c '
import json,sys
a,b=[json.loads(l) for l in sys.stdin]
assert a["result"]["serverInfo"]["name"]=="agent-deck"
assert not b["result"]["isError"] and "t1" in b["result"]["content"][0]["text"]' && pass "mcp initialize + tools/call"

echo "all good"
