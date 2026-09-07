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
[ "$(head -1 .deck/tasks/t9/runs/1.log | tr -d ' ')" = 0 ] && tr -d ' ' < .deck/tasks/t9/runs/1.log | grep -qE '^30[0-9]{4}$' && pass "oversize prompt falls back to stdin" || fail "oversize prompt falls back to stdin"

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
[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$HOME/.config/deck/secrets/api")" = 0o600 ] && ! grep -rq "sk-test" .deck && pass "apikey stored 0600 outside .deck" || fail "apikey storage"
deck hand add apih --account api --cost low --cmd 'python3 -c "import json,os,sys; sys.stdin.read(); assert len(os.environ[\"SMOKE_API_KEY\"]) == 14; print(json.dumps({\"usage\": {\"input_tokens\": 1000000, \"output_tokens\": 100000}}))"' >/dev/null
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
cat > bg-worker.sh <<'EOF'
#!/bin/sh
cat >/dev/null
i=0
while [ ! -f "$DECK_ROOT/bg.release" ] && [ "$i" -lt 200 ]; do
  sleep 0.05
  i=$((i + 1))
done
test -f "$DECK_ROOT/bg.release"
EOF
chmod +x bg-worker.sh
for i in 1 2 3; do deck hand add bg$i --account pv --cmd "$TMP/bg-worker.sh" >/dev/null; deck task add "bg$i" --id bg$i >/dev/null; done
deck run bg1 bg2 bg3 --bg >/dev/null
parallel_state="0 0"
for ((attempt=0; attempt<100; attempt++)); do
  parallel_state="$(deck task ls --status running --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d), len(set(x.get("hand") for x in d)))')"
  [ "$parallel_state" = "3 3" ] && break
  sleep 0.05
done
[ "$parallel_state" = "3 3" ] && pass "3 detached runs on 3 hands" || fail "parallel bg"
touch .deck/bg.release
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

deck hand add camel --account pv --cmd 'echo "{\"usage\":{\"inputTokens\":10,\"outputTokens\":5,\"cacheReadTokens\":100}}"' >/dev/null
deck task add "camel" --id t18 >/dev/null; expect 0 deck run t18 --hand camel
grep -q '"tokens_in": 110, "tokens_out": 5' .deck/ledger.jsonl && pass "cursor camelCase usage parsed" || fail "camelCase usage"

# ---- subscription headroom from the vendor CLI's own session logs (Claude Code JSONL shape) ----
LH="$HOME/.config/deck/homes/logsacct"; mkdir -p "$LH/projects/-tmp-x"
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z); OLD=$(date -u -d '-2 days' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -v-2d +%Y-%m-%dT%H:%M:%S.000Z)
cat > "$LH/projects/-tmp-x/s1.jsonl" <<EOF
{"type":"assistant","timestamp":"$NOW","requestId":"r1","message":{"id":"m1","model":"x","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100,"output_tokens":50}}}
{"type":"assistant","timestamp":"$NOW","requestId":"r1","message":{"id":"m1","model":"x","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100,"output_tokens":50}}}
{"type":"assistant","timestamp":"$OLD","requestId":"r0","message":{"id":"m0","model":"x","usage":{"input_tokens":5000,"output_tokens":5000}}}
{"type":"user","timestamp":"$NOW","message":{"role":"user","content":"hi"}}
EOF
deck account add logsacct --vendor claude --home "$LH" --status-cmd true --limit 2000/5h --limit 20000/1w >/dev/null
HR=$(deck account ls --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="logsacct"][0]; h=a["headroom"]; w={x["window"]:x for x in h["windows"]}; print(a["metric"], w["5h"]["tokens"], w["5h"]["requests"], w["1w"]["tokens"], h["source"])')
[ "$HR" = "tokens 1160 1 11160 logs" ] && pass "local session logs: dedup by requestId, per-window tokens/requests" || fail "local logs ($HR)"
deck account add logsacct --metric runs 2>out.txt >/dev/null; grep -q "old metric" out.txt && pass "warns when metric changes under existing limits" || fail "metric warning"

# ---- subscription utilization from official local surfaces: Claude Code's cache, then tokenroom state; drift estimate ----
NOWMS=$(python3 -c 'import time; print(int(time.time()*1000)-600000)')
python3 - "$LH" "$NOWMS" <<'EOF2'
import json, sys, time
home, ms = sys.argv[1], int(sys.argv[2])
json.dump({"cachedUsageUtilization": {"fetchedAtMs": ms, "utilization": {"five_hour": {"utilization": 40, "resets_at": "2099-01-01T05:00:00.000000+00:00"}, "seven_day": {"utilization": 12, "resets_at": "2099-01-03T12:00:00.000000+00:00"}}}}, open(home + "/.claude.json", "w"))
EOF2
deck account add logsacct --metric tokens --limit 0 >/dev/null
[ "$(deck account ls --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="logsacct"][0]; h=a["headroom"]; print(h["window"], h["used"], h["source"], a["remote"]["source"])')" = "5h 40.0 claude-cache claude-cache" ] && pass "claude-cache utilization governs (tightest window)" || fail "claude-cache: $(deck account ls --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="logsacct"][0]; print(a.get("remote"), a["headroom"]["window"], a["headroom"]["used"], a["headroom"].get("source"))')"
# the deck's own statusline tap: record -> read -> learn tokens-per-percent across two readings -> chain -> off
export DECK_USAGE_DIR="$TMP/usage"
PAY='{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":4102444800},"seven_day":{"used_percentage":12,"resets_at":4102531200}},"context_window":{"used_percentage":18},"model":{"id":"m"},"cost":{"total_cost_usd":0.01}}'
HUD=$(echo "$PAY" | CLAUDE_CONFIG_DIR="$LH" deck tap)
[ "$HUD" = "deck · 5h 50% left ↻00:00 · 1w 88% left ↻00:00 · ctx 82% left" ] && pass "tap prints remaining-first HUD" || fail "tap HUD ($HUD)"
echo garbage | CLAUDE_CONFIG_DIR="$LH" deck tap >/dev/null && pass "tap never fails on junk" || fail "tap junk"
deck account sync logsacct >/dev/null
[ "$(deck account ls --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="logsacct"][0]; h=a["headroom"]; print(h["source"], h["window"], h["used"])')" = "tap 5h 50.0" ] && pass "tap reading wins over the older claude-cache" || fail "tap read"
sleep 1
cat >> "$LH/projects/-tmp-x/s1.jsonl" <<EOF2
{"type":"assistant","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%S.500Z)","requestId":"r2","message":{"id":"m2","model":"x","usage":{"input_tokens":2000,"output_tokens":0}}}
EOF2
sleep 1; echo "${PAY/\"used_percentage\":50/\"used_percentage\":52}" | CLAUDE_CONFIG_DIR="$LH" deck tap >/dev/null
deck account sync logsacct >/dev/null
[ "$(deck account ls --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="logsacct"][0]; print(a.get("tokens_per_pct"), a["headroom"]["used"])')" = "1000 52.0" ] && pass "learns tokens-per-percent from two readings + logs" || fail "tpp learn ($(deck account ls --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="logsacct"][0]; print(a.get("tokens_per_pct"), a.get("remote"))'))"
[ "$(echo "$PAY" | CLAUDE_CONFIG_DIR="$LH" deck tap --chain 'cat >/dev/null; echo other-hud')" = "other-hud" ] && pass "tap --chain keeps an existing statusline" || fail "tap chain"
printf '{"statusLine":{"type":"command","command":"echo mine"}}\n' > "$LH/settings.json"
deck account tap logsacct >/dev/null && grep -q -- "--chain 'echo mine'" "$LH/settings.json" && deck account tap logsacct --off >/dev/null && [ "$(python3 -c 'import json; print(json.load(open("'"$LH"'/settings.json"))["statusLine"]["command"])')" = "echo mine" ] && pass "account tap wires/chains/restores settings.json" || fail "account tap wiring"
unset DECK_USAGE_DIR

# missing vendor CLI is its own state (checked with an empty PATH so the host's installs don't matter)
mkdir -p "$TMP/gemhome"; deck account add gem --vendor gemini --home "$TMP/gemhome" >/dev/null 2>&1
PATH="$(dirname "$(command -v python3)")" python3 "$HERE/deck" account check gem >out.txt 2>&1 || true
grep -q "gemini is not installed" out.txt && deck hand add gemh --account gem --cmd true >/dev/null && deck status | grep -q "gemh .*no-cli" && pass "missing vendor CLI -> no-cli with install hint" || fail "no-cli ($(cat out.txt))"
python3 - "$HERE/deck" <<'EOF2' | grep -q ok && pass "parse_reset understands epoch, clock and duration hints" || fail "parse_reset"
import sys
src = open(sys.argv[1]).read().replace('if __name__ == "__main__":', "if False:")
ns = {}; exec(compile(src, "deck", "exec"), ns); pr = ns["parse_reset"]
assert pr("You have hit your usage limit. Try again at 7:58 PM") is not None
assert pr("Claude AI usage limit reached|1900000000") == "2030-03-17T17:46:40Z"
assert pr("rate limit; resets in 2 hours 10 minutes") is not None
assert pr("no hint here") is None
print("ok")
EOF2

deck hand add priced --account pv --model catalog-priced --cmd 'echo "{\"usage\":{\"inputTokens\":1000000,\"outputTokens\":0}}"' >/dev/null
deck models set catalog-priced vendor=pvend price=2/10 >/dev/null
deck task add "priced" --id t19 >/dev/null; expect 0 deck run t19 --hand priced
grep -q '"cost_usd": 2.0' .deck/ledger.jsonl && pass "catalog model price -> cost_usd when hand/account have none" || fail "catalog price"

# billing semantics: subscription $ is API-equivalent, metered $ is real; codex rollout reader
OA_SECRET=x deck account add oa --login-cmd true >/dev/null
deck hand add oah --account oa --cmd 'echo "{\"usage\":{\"input_tokens\":1000,\"output_tokens\":10},\"total_cost_usd\":0.5}"' >/dev/null
deck task add "equiv" --id t20 >/dev/null; expect 0 deck run t20 --hand oah
grep -q '"cost_usd": 0.5, "billing": "equiv"' .deck/ledger.jsonl && grep -q '"billing": "metered"' .deck/ledger.jsonl && pass "ledger tags subscription $ as equiv, priced/API $ as metered" || fail "billing tags"
deck ledger | grep -E "^oa " | grep -q -- "-  *0.50" && pass "ledger separates metered from API-equivalent dollars" || fail "ledger columns ($(deck ledger | grep '^oa '))"
CH="$HOME/.config/deck/homes/cx"; mkdir -p "$CH/sessions/2026/09/07"
python3 - "$CH" <<'EOF2'
import json, sys, time, datetime as dt
d = sys.argv[1]; now = dt.datetime.now(dt.timezone.utc)
lines = [{"timestamp": (now - dt.timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%S.000Z"), "type": "event_msg", "payload": {"type": "token_count", "info": None, "rate_limits": None}},
         {"timestamp": (now - dt.timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%S.000Z"), "type": "event_msg", "payload": {"type": "token_count", "info": None,
          "rate_limits": {"primary": {"used_percent": 31.0, "window_minutes": 299, "resets_in_seconds": 7200}, "secondary": {"used_percent": 64.0, "window_minutes": 10079, "resets_in_seconds": 200000}}}}]
open(d + "/sessions/2026/09/07/rollout-1.jsonl", "w").write("\n".join(json.dumps(x) for x in lines) + "\n")
EOF2
deck account add cx --vendor codex --home "$CH" --status-cmd true >/dev/null 2>&1
[ "$(deck account ls --json | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin) if x["id"]=="cx"][0]; h=a["headroom"]; print(h["source"], h["window"], h["used"])')" = "codex-rollout 1w 64.0" ] && pass "codex rollout rate_limits snapshot -> windows (tightest governs)" || fail "codex rollout"

deck event NOTE --msg hi >/dev/null
[ "$(deck events --type NOTE -n 1 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["msg"])')" = hi ] && pass "events filter" || fail "events filter"

printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"deck_task_ls","arguments":{"status":"done"}}}' \
  | deck mcp | python3 -c '
import json,sys
a,b=[json.loads(l) for l in sys.stdin]
assert a["result"]["serverInfo"]["name"]=="agent-deck"
assert not b["result"]["isError"] and "t1" in b["result"]["content"][0]["text"]' && pass "mcp initialize + tools/call" || fail "mcp initialize + tools/call"

echo "all good"
