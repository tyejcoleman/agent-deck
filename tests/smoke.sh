#!/usr/bin/env bash
# End-to-end smoke test using fake hands (no vendor CLIs needed). Run: bash tests/smoke.sh
# shellcheck disable=SC2015,SC2016  # `cond && pass || fail` is safe (pass is an echo); single-quoted $VARs are meant for deck, not this shell
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
deck init >/dev/null && pass "init idempotent" || fail "init idempotent"

deck account add fake --vendor custom --limit 2/1h --env FOO=bar >/dev/null
deck account add other --vendor custom --limit 10 >/dev/null
deck hand add ok --account fake --cost low --cmd 'python3 -c "import os,sys; sys.stdin.read(); assert os.environ[\"FOO\"]==\"bar\"; open(os.environ[\"DECK_HANDOFF\"],\"w\").write(\"## Status\\nEND\\n## What changed\\nx\\n\"); print(\"{\\\"usage\\\":{\\\"input_tokens\\\":10,\\\"output_tokens\\\":5}}\")"' >/dev/null
deck hand add rl --account other --cost mid --cmd 'sh -c "echo rate limit reached; exit 1"' >/dev/null
deck hand add crash --account other --cost high --cmd 'sh -c "exit 3"' >/dev/null
deck hand add slow --account other --cost high --cmd 'sh -c "sleep 5"' >/dev/null
[ "$(deck route --cost low --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')" = ok ] && pass "route prefers cost match" || fail "route prefers cost match"

deck task add "first" --id t1 --cost low --text "## Goal
do it" >/dev/null
expect 0 deck run t1
grep -q '"tokens_in": 10' .deck/ledger.jsonl && pass "run END + ledger tokens" || fail "run END + ledger tokens"
grep -q '"type": "END", "task": "t1", "hand": "ok"' .deck/events.jsonl && pass "END event" || fail "END event"
[ ! -e .deck/claims/ok.json ] && pass "claim released" || fail "claim released"

deck task add "second" --id t2 --cost low >/dev/null
expect 0 deck run t2 --hand ok
[ "$(deck status --json | python3 -c 'import json,sys; print([h["state"] for h in json.load(sys.stdin)["hands"] if h["id"]=="ok"][0])')" = exhausted ] && pass "account exhausted after limit" || fail "account exhausted after limit"

deck task add "rl" --id t3 >/dev/null
expect 2 deck run t3 --hand rl
grep -q '"type": "COOLDOWN", "account": "other"' .deck/events.jsonl && pass "rate limit -> BLOCKED + cooldown" || fail "rate limit -> BLOCKED + cooldown"
deck account cooldown other --clear >/dev/null

deck task add "crash" --id t4 >/dev/null
expect 1 deck run t4 --hand crash
grep -q "FAILED (auto" .deck/tasks/t4/HANDOFF.md && pass "FAILED writes stub handoff" || fail "FAILED writes stub handoff"

deck task add "slow" --id t5 >/dev/null
expect 1 deck run t5 --hand slow --timeout 1s
grep -q "timeout after 1s" .deck/tasks/t5/HANDOFF.md && pass "timeout -> FAILED" || fail "timeout -> FAILED"

deck claim crash --task t4 --ttl 5m >/dev/null
expect 1 deck run t4 --hand crash --force
grep -q "is claimed by test" out.txt && pass "claimed hand refuses run" || fail "claimed hand refuses run"
deck release crash >/dev/null

deck task add "manual" --id t6 >/dev/null
deck handoff t6 --status BLOCKED --text "need creds" >/dev/null
[ "$(deck task show t6 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" = blocked ] && pass "manual handoff" || fail "manual handoff"

cat > .deck/hooks.d/END-hook.sh <<'EOF'
#!/bin/sh
echo "$DECK_EVENT_TYPE:$DECK_TASK" >> hook.log
EOF
chmod +x .deck/hooks.d/END-hook.sh
deck account cooldown fake --clear >/dev/null
deck account add fake --limit 0 >/dev/null
deck task add "hooked" --id t7 >/dev/null
expect 0 deck run t7 --hand ok
grep -q "END:t7" hook.log && pass "hooks fire on END" || fail "hooks fire on END"

deck account cooldown fake --for 1h >/dev/null; deck account cooldown other --for 1h >/dev/null
deck task add "nohand" --id t8 >/dev/null
expect 2 deck run t8
grep -q "no free hand" out.txt && pass "no free hand -> BLOCKED" || fail "no free hand -> BLOCKED"

deck account cooldown other --clear >/dev/null
# shellcheck disable=SC2016
deck hand add argv --account other --cost low --cmd 'sh -c "printf %s \"\$1\" | wc -c; cat | wc -c" -- {prompt}' >/dev/null
python3 -c "print('x'*300000)" > big.md
deck task add "big" --id t9 --file big.md >/dev/null
expect 0 deck run t9 --hand argv
[ "$(head -1 .deck/tasks/t9/runs/1.log)" = 0 ] && grep -qE '^30[0-9]{4}$' .deck/tasks/t9/runs/1.log && pass "oversize prompt falls back to stdin" || fail "oversize prompt falls back to stdin"

deck task add "badcwd" --id t10 >/dev/null; deck task set t10 cwd=/nonexistent >/dev/null
expect 1 deck run t10 --hand argv
grep -q "could not start worker" out.txt && [ ! -e .deck/claims/argv.json ] && pass "bad cwd -> FAILED, claim released" || fail "bad cwd -> FAILED, claim released"

deck claim argv --task other --by someone-else >/dev/null
deck hand add argv2 --account other --cost low --cmd 'sh -c "cat >/dev/null"' >/dev/null
deck task add "fallthrough" --id t11 --cost low >/dev/null
expect 0 deck run t11
[ "$(deck task show t11 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["hand"])')" = argv2 ] && pass "claimed hand -> next ranked hand" || fail "claimed hand -> next ranked hand"
deck release argv >/dev/null

python3 -c "import json; json.dump({'hand':'argv','task':'old','by':'ghost','since':'2026-01-01T00:00:00Z','until':'2026-01-01T01:00:00Z'}, open('.deck/claims/argv.json','w'))"
expect 0 deck claim argv --task new
pass "expired claim taken over"; deck release argv >/dev/null

deck account add tok --vendor custom --metric tokens --limit 100/1h >/dev/null
deck hand add tokh --account tok --cmd 'echo "{\"usage\":{\"input_tokens\":90,\"output_tokens\":20}}"' >/dev/null
deck task add tk --id t12 >/dev/null; expect 0 deck run t12 --hand tokh
[ "$(deck status --json | python3 -c 'import json,sys; print([h["state"] for h in json.load(sys.stdin)["hands"] if h["id"]=="tokh"][0])')" = exhausted ] && pass "token-metric headroom" || fail "token-metric headroom"

printf '{"ts": "2026-09-06T00:00:00Z", "acc' >> .deck/ledger.jsonl; echo >> .deck/ledger.jsonl
expect 0 deck status
grep -q "skipping bad line" out.txt && grep -q "tokh" out.txt && pass "torn jsonl line skipped" || fail "torn jsonl line skipped"
echo '{oops' > .deck/hands/broken.json
expect 1 deck status
grep -q "bad JSON in hands/broken.json" out.txt && pass "corrupt record named"; rm .deck/hands/broken.json

# ---- accounts: auth modes, secrets, costs (file secret store under a scratch HOME) ----
export DECK_SECRETS=file HOME="$TMP/home"; mkdir -p "$HOME"
deck account add oa --vendor custom --auth oauth --env OA_HOME="~/.config/deck/homes/oa" --status-cmd 'test -f "$OA_HOME/token"' \
  --login-cmd 'mkdir -p "$OA_HOME" && printf %s "$OA_SECRET" > "$OA_HOME/token"' >/dev/null
[ "$(deck account ls --json | python3 -c 'import json,sys; print([a["check"]["ok"] for a in json.load(sys.stdin) if a["id"]=="oa"][0])')" = False ] && pass "oauth account starts needs-login" || fail "oauth account starts needs-login"
OA_SECRET=real-oauth-token deck account login oa >/dev/null
grep -q '"type": "AUTH", "account": "oa", "ok": true' .deck/events.jsonl && grep -q real-oauth-token "$HOME/.config/deck/homes/oa/token" && ! grep -rq real-oauth-token .deck && pass "oauth login -> AUTH ok, token outside .deck" || fail "oauth login"

export SMOKE_KEY="sk-test-abcdef"
deck account add api --vendor custom --auth apikey --key-env SMOKE_API_KEY --price 3/15 >/dev/null
deck account login api --from-env SMOKE_KEY >/dev/null
[ "$(stat -c %a "$HOME/.config/deck/secrets/api")" = 600 ] && ! grep -rq "sk-test" .deck && pass "apikey stored 0600 outside .deck" || fail "apikey storage"
deck hand add apih --account api --cost low --cmd 'sh -c "cat >/dev/null; [ \${#SMOKE_API_KEY} = 14 ] || exit 9; echo {\\\"usage\\\":{\\\"input_tokens\\\":1000000,\\\"output_tokens\\\":100000}}"' >/dev/null
deck task add "api" --id t13 >/dev/null; expect 0 deck run t13 --hand apih
grep -q '"cost_usd": 4.5' .deck/ledger.jsonl && ! grep -rq "sk-test" .deck && pass "key injected into worker; cost from price" || fail "key injection / cost"

deck hand add rej --account api --cost low --cmd 'sh -c "echo invalid api key; exit 1"' >/dev/null
deck task add "rej" --id t14 >/dev/null; expect 2 deck run t14 --hand rej
grep -q '"type": "AUTH", "account": "api", "ok": false' .deck/events.jsonl && pass "worker auth failure -> BLOCKED + AUTH" || fail "auth failure detection"
expect 1 deck account check api
grep -q "rejected" out.txt && pass "rejected key stays needs-login" || fail "rejected key"
export SMOKE_KEY2="sk-test-new"; deck account login api --from-env SMOKE_KEY2 >/dev/null
expect 0 deck account check api; pass "new key clears rejection"

deck account add loc --vendor ollama --base-url http://127.0.0.1:1 >/dev/null 2>&1
[ "$(deck status --json | python3 -c 'import json,sys; a=[h for h in json.load(sys.stdin)["hands"]]; print("ok")')" = ok ] || fail status
deck hand add loch --account loc --cmd true >/dev/null
deck status | grep -q "loch .*down" && pass "local server down -> hand state down" || fail "local down state"

deck account add mw --vendor custom --auth none --limit 5/5h --limit 3/1w --metric runs >/dev/null
deck hand add mwh --account mw --cmd 'sh -c "cat >/dev/null"' >/dev/null
for i in 1 2 3; do deck task add "mw$i" --id mw$i >/dev/null; deck run mw$i --hand mwh >/dev/null; done
[ "$(deck account ls --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="mw"][0]["headroom"]; print(a["window"], a["state"])')" = "1w exhausted" ] && pass "multi-window: tightest window governs" || fail "multi-window"

# ---- run-time model/effort, parallel bg runs, wait, reaper, catalog + self-recovery ----
deck account add pv --vendor custom --auth none >/dev/null
deck hand add ph --account pv --vendor pvend --model good-1 --cost mid --cmd 'sh -c "cat>/dev/null; case \"\$*\" in *bad-model*) echo \"Error: unknown model: \$*\"; exit 1;; esac; echo {\\\"result\\\":\\\"OK\\\"}" x {model} e={effort}' >/dev/null
deck task add "dry" --id t15 >/dev/null
deck run t15 --hand ph --model m9 --effort high --dry | grep -q -- "--model m9 e=high" && pass "run-time --model/--effort expansion" || fail "model/effort expansion"
for i in 1 2 3; do deck hand add bg$i --account pv --cmd 'sh -c "cat>/dev/null; sleep 1"' >/dev/null; deck task add "bg$i" --id bg$i >/dev/null; done
deck run bg1 bg2 bg3 --bg >/dev/null
sleep 0.5; [ "$(deck task ls --status running --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 3 ] && pass "3 detached runs in parallel" || fail "parallel bg"
expect 0 deck wait bg1 bg2 bg3 --timeout 30s
pass "wait returns when all finish"
deck task add "dead" --id t16 >/dev/null
python3 -c "import json; p='.deck/tasks/t16/task.json'; t=json.load(open(p)); t.update(status='running', hand='bg1', pid=999999, started='2026-01-01T00:00:00Z'); json.dump(t, open(p,'w'))"
deck status >/dev/null
[ "$(deck task show t16 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" = failed ] && pass "dead runner reaped" || fail "reaper"
expect 0 deck models probe good-1 --hand ph
expect 1 deck models probe bad-model --hand ph
[ "$(deck models --no-sync --json | python3 -c 'import json,sys; m=json.load(sys.stdin)["models"]; print(m["good-1"]["available"], m["bad-model"]["available"])')" = "True False" ] && [ -z "$(find .deck/tasks -maxdepth 1 -name 'probe-*')" ] && pass "probe records availability, leaves no task" || fail "probe"
deck hand add bm --account pv --model bad-model --cmd true >/dev/null
deck status | grep -q "bm .*no-model" && pass "hand on unavailable model excluded" || fail "no-model state"
python3 -c "import json; p='.deck/models.json'; m=json.load(open(p)); m['models']['bad-model']['available']=True; json.dump(m,open(p,'w'))"
deck hand rm bm >/dev/null
deck hand add cheap --account pv --vendor pvend --model good-1 --cost low --cmd 'sh -c "cat>/dev/null"' >/dev/null
deck task add "recover" --id t17 --model bad-model --cost mid >/dev/null
expect 0 deck run t17
grep -q '"type": "MODEL", "model": "bad-model"' .deck/events.jsonl && [ "$(deck task show t17 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d.get("rejected_model"))')" = "done bad-model" ] \
  && [ -n "$(find .deck/tasks -maxdepth 1 -name 'models-refresh*')" ] && pass "model error -> catalog marked, research task dispatched, re-routed to END" || fail "self-recovery"
deck wait "$(basename "$(find .deck/tasks -maxdepth 1 -name 'models-refresh*' | head -1)")" --timeout 20s >/dev/null || true

deck event NOTE --msg hi >/dev/null
[ "$(deck events --type NOTE -n 1 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["msg"])')" = hi ] && pass "events filter" || fail "events filter"

printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"deck_task_ls","arguments":{"status":"done"}}}' \
  | deck mcp | python3 -c '
import json,sys
a,b=[json.loads(l) for l in sys.stdin]
assert a["result"]["serverInfo"]["name"]=="agent-deck"
assert not b["result"]["isError"] and "t1" in b["result"]["content"][0]["text"]' && pass "mcp initialize + tools/call" || fail "mcp initialize + tools/call"

echo "all good"
