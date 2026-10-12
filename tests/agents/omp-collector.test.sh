#!/bin/bash
# Tests for bin/omarchy-agent-usage-omp, bin/omarchy-agent-usage-claude and
# bin/agents-update.
#
# Every case runs the real collectors against a stubbed `omp` on PATH and a
# synthetic stats.db, so the record contract, the failure paths and the atomic
# write are all exercised without touching the network, the machine's own omp
# install, or ~/.local/state/haseen/agents/usage.
#
#   bash tests/agents/omp-collector.test.sh

set -u

command -v jq >/dev/null || { echo "jq is required" >&2; exit 77; }

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
collector="$plugin_dir/bin/omarchy-agent-usage-omp"
claude_collector="$plugin_dir/bin/omarchy-agent-usage-claude"
wrapper="$plugin_dir/bin/agents-update"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fixtures="$work/fixtures"
stub_dir="$work/bin"
mkdir -p "$fixtures/home/agent" "$stub_dir"

CONTRACT_KEYS="activeDates activeDays authHelpText hasLocalStats id limits modelUsage name ready \
recentDays schemaVersion statsSource tierLabel todayPrompts todaySessions todayTokensByModel todayTotalTokens \
totalPrompts totalSessions updatedAt usageStatusText"

TOTAL_FAIL=0
ROW=""
ROW_FAIL=0

row() { ROW="$1"; ROW_FAIL=0; printf '\n== %s\n' "$ROW"; }
row_end() {
  if (( ROW_FAIL == 0 )); then
    printf '   PASS\n'
  else
    printf '   FAIL (%d)\n' "$ROW_FAIL"
    TOTAL_FAIL=$((TOTAL_FAIL + ROW_FAIL))
  fi
}
fail() { ROW_FAIL=$((ROW_FAIL + 1)); printf '     ! %s\n' "$*"; }
assert_eq() { [[ "$2" == "$3" ]] || fail "$1: expected [$2] got [$3]"; }
assert_ne() { [[ "$2" != "$3" ]] || fail "$1: did not expect [$2]"; }
assert_true() { [[ "$2" == "true" ]] || fail "$1: expected true got [$2]"; }
assert_empty() { [[ -z "$2" ]] || fail "$1: expected empty got [$2]"; }
assert_contains() { [[ "$3" == *"$2"* ]] || fail "$1: expected [$2] in [$3]"; }
assert_not_contains() { [[ "$3" != *"$2"* ]] || fail "$1: did not expect [$2] in [$3]"; }
assert_file() { [[ -f "$2" ]] || fail "$1: $2 does not exist"; }
assert_no_file() { [[ -e "$2" ]] && fail "$1: $2 exists"; return 0; }

contract_keys_json() { printf '%s\n' $CONTRACT_KEYS | jq -Rn '[inputs]'; }
record_path() { printf '%s\n' "$XDG_STATE_HOME/haseen/agents/usage/omp.json"; }
claude_record() { printf '%s\n' "$XDG_STATE_HOME/haseen/agents/usage/claude.json"; }
usage_dir() { printf '%s\n' "$XDG_STATE_HOME/haseen/agents/usage"; }
listing() { PATH=/usr/bin:/bin ls -A "$(usage_dir)" 2>/dev/null | tr '\n' ' ' | tr -d ' '; }
calls() { cat "$fixtures/calls.log" 2>/dev/null; }
usage_calls() { grep -c '^usage --json' "$fixtures/calls.log" 2>/dev/null || true; }

# ---------------------------------------------------------------- stub `omp`
# Serves fixtures and records every invocation. OMP_STUB_USAGE / OMP_STUB_STATS
# choose what each subcommand does; OMP_STUB_USAGE_FILE swaps the limits
# fixture without touching the fixture directory.

cat > "$stub_dir/omp" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${OMP_STUB_DIR}/calls.log"
command="$1"; shift || true

serve() { # serve <mode> <fixture>
  case "$1" in
  ok) cat "$2" ;;
  fail) printf '%s\n' "omp: request failed (HTTP 500)" >&2; exit 1 ;;
  failnet) printf '%s\n' "connect ETIMEDOUT 1.2.3.4:443 (fetch failed)" >&2; exit 1 ;;
  garbage) printf '%s\n' "not json at all"; printf '%s\n' '{"broken": '; exit 0 ;;
  esac
  exit 0
}

case "$command" in
config) printf '%s\n' "${OMP_STUB_HOME}/agent" ;;
usage) serve "${OMP_STUB_USAGE:-ok}" "${OMP_STUB_USAGE_FILE:-${OMP_STUB_DIR}/usage.json}" ;;
stats)
  printf '%s\n' "Syncing session files..." >&2
  serve "${OMP_STUB_STATS:-ok}" "${OMP_STUB_STATS_FILE:-${OMP_STUB_DIR}/stats.txt}"
  ;;
*) printf '%s\n' "omp: unknown command $command" >&2; exit 64 ;;
esac
STUB
chmod +x "$stub_dir/omp"
export OMP_STUB_DIR="$fixtures"
export PATH="$stub_dir:$PATH"

# The limits fixtures carry reset times, because the collector drops a cached
# window once its window has reset (window_is_open). Hard-coded epochs made
# this file expire: the two 7-day windows reset on 2026-09-13, so the
# cached-limits reuse cases ("expected [4] got [2]") failed from then on. They
# are relative to the run instead, which is the contract the cases are about —
# a cached window that has NOT reset is reused.
now_ms=$(date +%s%3N)
res_30d=$((now_ms + 2592000000))
res_7d=$((now_ms + 604800000))
# Two Claude accounts on independent clocks: each keeps its own reset.
res_5h_a=$((now_ms + 3600000))
res_5h_b=$((now_ms + 7200000))
res_7d_a=$((now_ms + 259200000))
res_7d_b=$((now_ms + 432000000))
iso() { python3 -c "import datetime as dt;print(dt.datetime.fromtimestamp($1/1000, dt.timezone.utc).isoformat())"; }


cat > "$fixtures/usage.json" <<'JSON'
{"generatedAt":1789048041985,"accountsWithoutUsage":[],"disabledCredentials":[],
 "capacity":{"openai-codex":[{"window":"30d","durationMs":2592000000,"meter":"chat","accounts":1,"usedAccounts":0.05,"remainingAccounts":0.95}]},
 "reports":[
  {"provider":"openai-codex","fetchedAt":1789047817156,
   "limits":[{"id":"openai-codex:primary","label":"30 days",
     "scope":{"provider":"openai-codex","windowId":"30d","shared":true},
     "window":{"id":"30d","label":"30 days","durationMs":2592000000,"resetsAt":1791481984000},
     "amount":{"used":5,"limit":100,"remaining":95,"usedFraction":0.05,"remainingFraction":0.95,"unit":"percent"},
     "status":"ok"}],
   "resetCredits":{"availableCount":2},
   "metadata":{"planType":"free","allowed":true,"limitReached":false,"email":"user@example.com",
     "accountId":"d6b25d4b-64e6-4931-a562-43b46a02d866","orgName":"free"}},
  {"provider":"anthropic","fetchedAt":1789047881059,
   "limits":[
    {"id":"anthropic:5h","label":"Claude 5 Hour",
     "scope":{"provider":"anthropic","windowId":"5h","shared":true},
     "window":{"id":"5h","label":"5 Hour","durationMs":18000000},
     "amount":{"used":0,"limit":100,"remaining":100,"usedFraction":0,"remainingFraction":1,"unit":"percent"},
     "status":"ok"},
    {"id":"anthropic:7d","label":"Claude 7 Day",
     "scope":{"provider":"anthropic","windowId":"7d","shared":true},
     "window":{"id":"7d","label":"7 Day","durationMs":604800000,"resetsAt":1789340399907},
     "amount":{"used":100,"limit":100,"remaining":0,"usedFraction":1,"remainingFraction":0,"unit":"percent"},
     "status":"exhausted"},
    {"id":"anthropic:7d:fable","label":"Claude 7 Day (Fable)",
     "scope":{"provider":"anthropic","windowId":"7d","shared":null},
     "window":{"id":"7d","label":"7 Day","durationMs":604800000,"resetsAt":1789340399907},
     "amount":{"used":100,"limit":100,"remaining":0,"usedFraction":1,"remainingFraction":0,"unit":"percent"},
     "status":"exhausted"}],
   "metadata":{"email":"user@example.com","accountId":"a215ea0e-6240-47a5-953a-74e03b704e9c"}}]}
JSON

cat > "$fixtures/usage-empty.json" <<'JSON'
{"generatedAt":1789048041985,"reports":[],
 "accountsWithoutUsage":[{"provider":"kimi-code","type":"oauth","accountId":"d55fn1ms"}]}
JSON

cat > "$fixtures/usage-clamped.json" <<'JSON'
{"generatedAt":1,"reports":[{"provider":"anthropic","metadata":{"email":"two@example.com"},
 "limits":[
  {"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
   "window":{"id":"5h","label":"5 Hour"},"amount":{"usedFraction":1.5},"status":"warning"},
  {"id":"anthropic:7d","label":"Claude 7 Day","scope":{"provider":"anthropic","windowId":"7d","shared":true},
   "window":{"id":"7d","label":"7 Day"},"amount":{"usedFraction":0},"status":"unavailable"},
  {"id":"anthropic:7d:x","label":"Claude 7 Day (X)","scope":{"provider":"anthropic","windowId":"7d","shared":true},
   "window":{"id":"7d","label":"7 Day"},"status":"ok"}]}]}
JSON

# Two independent Claude subscriptions, each marking its windows shared:true
# (shared across that account's models), with their own percentages and reset
# times — and an older repeat of the first account's report, which the newer
# one must replace rather than sit beside it.
cat > "$fixtures/usage-accounts.json" <<JSON
{"generatedAt":1,"reports":[
 {"provider":"openai-codex","fetchedAt":100,
  "limits":[{"id":"openai-codex:primary","label":"30 days","scope":{"provider":"openai-codex","windowId":"30d","shared":true},
    "window":{"id":"30d","label":"30 days","resetsAt":$res_30d},"amount":{"usedFraction":0.05},"status":"ok"}],
  "metadata":{"email":"user@example.com","accountId":"codex-0001"}},
 {"provider":"anthropic","fetchedAt":50,
  "metadata":{"email":"alice@example.com","accountId":"acct-aaaa1111","orgId":"org-1111"},
  "limits":[
   {"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour","resetsAt":$res_5h_a},"amount":{"usedFraction":0.99},"status":"ok"}]},
 {"provider":"anthropic","fetchedAt":90,
  "metadata":{"email":"bob@example.com","accountId":"acct-bbbb2222","orgId":"org-2222"},
  "limits":[
   {"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour","resetsAt":$res_5h_b},"amount":{"usedFraction":0.6},"status":"ok"},
   {"id":"anthropic:7d","label":"Claude 7 Day","scope":{"provider":"anthropic","windowId":"7d","shared":true},
    "window":{"id":"7d","label":"7 Day","resetsAt":$res_7d_b},"amount":{"usedFraction":0.9},"status":"ok"},
   {"id":"anthropic:7d:fable","label":"Claude 7 Day (Fable)","scope":{"provider":"anthropic","windowId":"7d","shared":null},
    "window":{"id":"7d","label":"7 Day","resetsAt":$res_7d_b},"amount":{"usedFraction":0.1},"status":"ok"}]},
 {"provider":"anthropic","fetchedAt":100,
  "metadata":{"email":"alice@example.com","accountId":"acct-aaaa1111","orgId":"org-1111"},
  "limits":[
   {"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour","resetsAt":$res_5h_a},"amount":{"usedFraction":0.2},"status":"ok"},
   {"id":"anthropic:7d","label":"Claude 7 Day","scope":{"provider":"anthropic","windowId":"7d","shared":true},
    "window":{"id":"7d","label":"7 Day","resetsAt":$res_7d_a},"amount":{"usedFraction":0.4},"status":"ok"},
   {"id":"anthropic:7d:fable","label":"Claude 7 Day (Fable)","scope":{"provider":"anthropic","windowId":"7d","shared":null},
    "window":{"id":"7d","label":"7 Day","resetsAt":$res_7d_a},"amount":{"usedFraction":0.5},"status":"ok"}]}]}
JSON

# Three accounts whose short names collide: one address in two organisations
# (same account id, different org) and a second address sharing the local part.
cat > "$fixtures/usage-same-local.json" <<JSON
{"generatedAt":1,"reports":[
 {"provider":"anthropic","metadata":{"email":"alice@example.com","accountId":"acct-aaaa1111","orgId":"org-1111","orgName":"Personal"},
  "limits":[{"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour","resetsAt":$res_5h_a},"amount":{"usedFraction":0.1},"status":"ok"}]},
 {"provider":"anthropic","metadata":{"email":"alice@work.example","accountId":"acct-cccc3333"},
  "limits":[{"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour","resetsAt":$res_5h_b},"amount":{"usedFraction":0.2},"status":"ok"}]},
 {"provider":"anthropic","metadata":{"email":"alice@example.com","accountId":"acct-aaaa1111","orgId":"org-9999","orgName":"Team"},
  "limits":[{"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour","resetsAt":$res_5h_a},"amount":{"usedFraction":0.3},"status":"ok"}]}]}
JSON

# Identity edges. One account id on two providers is two subscriptions; one
# account's newer report arrives BEFORE its older repeat (so "last one wins"
# would keep the stale 0.8); two reports with no account id share an address,
# which is not proof they are one account.
cat > "$fixtures/usage-identity.json" <<JSON
{"generatedAt":1,"reports":[
 {"provider":"anthropic","fetchedAt":200,"metadata":{"email":"carol@example.com","accountId":"acct-shared"},
  "limits":[{"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour","resetsAt":$res_5h_a},"amount":{"usedFraction":0.3},"status":"ok"}]},
 {"provider":"openai-codex","fetchedAt":200,"metadata":{"email":"carol@example.com","accountId":"acct-shared"},
  "limits":[{"id":"openai-codex:primary","label":"30 days","scope":{"provider":"openai-codex","windowId":"30d","shared":true},
    "window":{"id":"30d","label":"30 days","resetsAt":$res_30d},"amount":{"usedFraction":0.05},"status":"ok"}]},
 {"provider":"anthropic","fetchedAt":100,"metadata":{"email":"carol@example.com","accountId":"acct-shared"},
  "limits":[{"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour","resetsAt":$res_5h_a},"amount":{"usedFraction":0.8},"status":"ok"}]},
 {"provider":"anthropic","metadata":{"email":"same@example.com"},
  "limits":[{"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour","resetsAt":$res_5h_b},"amount":{"usedFraction":0.1},"status":"ok"}]},
 {"provider":"anthropic","metadata":{"email":"same@example.com"},
  "limits":[{"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour","resetsAt":$res_5h_b},"amount":{"usedFraction":0.2},"status":"ok"}]}]}
JSON

# A signed-in Claude account whose every window came back unmeasured.
cat > "$fixtures/usage-nodata.json" <<'JSON'
{"generatedAt":1,"accountsWithoutUsage":[],"reports":[
 {"provider":"anthropic","fetchedAt":1,"metadata":{"email":"dave@example.com","accountId":"acct-dddd4444"},
  "limits":[
   {"id":"anthropic:5h","label":"Claude 5 Hour","scope":{"provider":"anthropic","windowId":"5h","shared":true},
    "window":{"id":"5h","label":"5 Hour"},"amount":{"usedFraction":0},"status":"unavailable"},
   {"id":"anthropic:7d","label":"Claude 7 Day","scope":{"provider":"anthropic","windowId":"7d","shared":true},
    "window":{"id":"7d","label":"7 Day"},"amount":{"usedFraction":0},"status":"unknown"}]}]}
JSON

# Swap the two frozen epochs the fixtures were written with for live ones.
sed -i "s/1789340399907/$res_7d/g; s/1791481984000/$res_30d/g" "$fixtures/usage.json"

# -------------------------------------------------------------- stats fixture
# omp prints progress lines before the document, and the first one carries a
# decoy JSON object: the collector must still read the document.

cat > "$fixtures/stats.txt" <<'TXT'
Syncing session files...
Synced 37 new entries from 7 files (41515 total)
cache {"note":"decoy object, not the document"} warmed

{"overall":{"totalRequests":20,"totalInputTokens":26,"totalOutputTokens":4,"totalCost":1.5,
  "firstTimestamp":1788961642732,"lastTimestamp":1789048039385},
 "byModel":[
  {"model":"model-a","provider":"anthropic","totalRequests":8,"totalInputTokens":8,"totalOutputTokens":2,
   "totalCacheReadTokens":1,"totalCacheWriteTokens":3,"totalCost":0.5},
  {"model":"model-b","provider":"deepseek","totalRequests":12,"totalInputTokens":18,"totalOutputTokens":2,
   "totalCacheReadTokens":5,"totalCacheWriteTokens":7,"totalCost":1.0}],
 "timeSeries":[{"timestamp":1789041600000,"requests":3,"errors":0,"tokens":300,"cost":0.1}]}
done.
TXT

# --------------------------------------------------------- synthetic stats.db
# The two tables the collector reads, and the same DDL ~/.omp/stats.db uses,
# filled with a known history: two messages today, one yesterday, one six days
# ago, four user prompts.

python3 - "$fixtures/home/stats.db" <<'PY'
import datetime as dt, sqlite3, sys

db = sys.argv[1]
today = dt.datetime.now().date()
yesterday = today - dt.timedelta(days=1)
week_ago = today - dt.timedelta(days=6)
def ms(day, hour=12):
  return int(dt.datetime.combine(day, dt.time(hour)).timestamp() * 1000)

con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_file TEXT NOT NULL, entry_id TEXT NOT NULL,
  folder TEXT NOT NULL, model TEXT NOT NULL, provider TEXT NOT NULL, api TEXT NOT NULL,
  timestamp INTEGER NOT NULL, duration INTEGER, ttft INTEGER, stop_reason TEXT NOT NULL,
  error_message TEXT, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
  cache_read_tokens INTEGER NOT NULL, cache_write_tokens INTEGER NOT NULL,
  total_tokens INTEGER NOT NULL, premium_requests REAL NOT NULL, cost_input REAL NOT NULL,
  cost_output REAL NOT NULL, cost_cache_read REAL NOT NULL, cost_cache_write REAL NOT NULL,
  cost_total REAL NOT NULL, cost_no_cache_input REAL, agent_type TEXT NOT NULL DEFAULT 'main',
  UNIQUE(session_file, entry_id));
CREATE INDEX idx_messages_timestamp ON messages(timestamp);
CREATE TABLE user_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_file TEXT NOT NULL, entry_id TEXT NOT NULL,
  folder TEXT NOT NULL, timestamp INTEGER NOT NULL, model TEXT, provider TEXT,
  chars INTEGER NOT NULL, words INTEGER NOT NULL, yelling INTEGER NOT NULL, profanity INTEGER NOT NULL,
  anguish INTEGER NOT NULL, negation INTEGER NOT NULL DEFAULT 0, repetition INTEGER NOT NULL DEFAULT 0,
  blame INTEGER NOT NULL DEFAULT 0, UNIQUE(session_file, entry_id));
""")

def message(session, entry, model, provider, timestamp, input_tokens, output_tokens, total):
  con.execute(
    "INSERT INTO messages (session_file, entry_id, folder, model, provider, api, timestamp,"
    " stop_reason, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,"
    " total_tokens, premium_requests, cost_input, cost_output, cost_cache_read,"
    " cost_cache_write, cost_total) VALUES (?,?,'/tmp',?,?,'chat',?,'end_turn',?,?,0,0,?,0,0,0,0,0,0)",
    (session, entry, model, provider, timestamp, input_tokens, output_tokens, total))

def prompt(session, entry, provider, timestamp):
  con.execute(
    "INSERT INTO user_messages (session_file, entry_id, folder, timestamp, provider, chars, words, yelling,"
    " profanity, anguish) VALUES (?,?,'/tmp',?,?,10,2,0,0,0)",
    (session, entry, timestamp, provider))

# s2 is a DeepSeek session: it counts for Oh My Pi, never for Claude.
message("s1", "e1", "model-a", "anthropic", ms(today, 9), 6, 4, 10)
message("s2", "e2", "model-b", "deepseek", ms(today, 10), 15, 5, 20)
message("s1", "e3", "model-a", "anthropic", ms(yesterday), 4, 1, 5)
message("s3", "e4", "model-a", "anthropic", ms(week_ago), 6, 1, 7)
prompt("s1", "u1", "anthropic", ms(today, 9))
prompt("s1", "u2", "anthropic", ms(today, 9))
prompt("s2", "u3", "deepseek", ms(today, 10))
prompt("s1", "u4", "anthropic", ms(yesterday))
con.commit()
con.close()
PY

# One model id served by two providers (the live stats.db has such ids), plus
# a prompt omp stored without a provider: the Claude record may count only the
# Anthropic half, and an unattributed prompt belongs to Oh My Pi's totals only.
mkdir -p "$fixtures/combined-home/agent"
python3 - "$fixtures/home/stats.db" "$fixtures/combined-home/stats.db" <<'PY'
import datetime as dt, sqlite3, sys

source, target = sys.argv[1], sys.argv[2]
today = dt.datetime.now().date()
yesterday = today - dt.timedelta(days=1)
def ms(day, hour=12):
  return int(dt.datetime.combine(day, dt.time(hour)).timestamp() * 1000)

ddl = [row[0] for row in sqlite3.connect(source).execute(
  "SELECT sql FROM sqlite_master WHERE type IN ('table', 'index') AND sql IS NOT NULL AND name NOT LIKE 'sqlite_%'")]
con = sqlite3.connect(target)
for statement in ddl:
  con.execute(statement)

def message(session, entry, model, provider, timestamp, input_tokens, output_tokens, total):
  con.execute(
    "INSERT INTO messages (session_file, entry_id, folder, model, provider, api, timestamp,"
    " stop_reason, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,"
    " total_tokens, premium_requests, cost_input, cost_output, cost_cache_read,"
    " cost_cache_write, cost_total) VALUES (?,?,'/tmp',?,?,'chat',?,'end_turn',?,?,0,0,?,0,0,0,0,0,0)",
    (session, entry, model, provider, timestamp, input_tokens, output_tokens, total))

def prompt(session, entry, provider, timestamp):
  con.execute(
    "INSERT INTO user_messages (session_file, entry_id, folder, timestamp, provider, chars, words, yelling,"
    " profanity, anguish) VALUES (?,?,'/tmp',?,?,10,2,0,0,0)",
    (session, entry, timestamp, provider))

message("c1", "e1", "shared-model", "anthropic", ms(today, 9), 6, 4, 10)
message("c2", "e2", "shared-model", "openrouter", ms(today, 10), 30, 10, 40)
message("c3", "e3", "claude-only", "anthropic", ms(yesterday), 3, 2, 5)
prompt("c1", "u1", "anthropic", ms(today, 9))
prompt("c2", "u2", "openrouter", ms(today, 10))
prompt("c2", "u3", None, ms(today, 10))
con.commit()
con.close()
PY

cat > "$fixtures/stats-combined.txt" <<'TXT'
{"overall":{"totalRequests":3},
 "byModel":[
  {"model":"shared-model","provider":"anthropic","totalInputTokens":6,"totalOutputTokens":4,
   "totalCacheReadTokens":0,"totalCacheWriteTokens":0},
  {"model":"shared-model","provider":"openrouter","totalInputTokens":30,"totalOutputTokens":10,
   "totalCacheReadTokens":0,"totalCacheWriteTokens":0},
  {"model":"shared-model","totalInputTokens":100,"totalOutputTokens":0,
   "totalCacheReadTokens":0,"totalCacheWriteTokens":0}]}
TXT

# ------------------------------------------------------------ case scaffolding

new_case() { # new_case <name>
  case_dir="$work/case-$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/state" "$case_dir/cache" "$case_dir/home/agent"
  export XDG_STATE_HOME="$case_dir/state"
  export XDG_CACHE_HOME="$case_dir/cache"
  export HOME="$case_dir/home"
  export OMP_STUB_HOME="$fixtures/home"
  export OMP_STUB_USAGE=ok OMP_STUB_STATS=ok
  export OMP_STUB_USAGE_FILE="$fixtures/usage.json"
  export OMP_STUB_STATS_FILE="$fixtures/stats.txt"
  : > "$fixtures/calls.log"
}

# ============================================================================
row "(a) real omp shapes, print mode"

new_case a
out=$(cd / && "$collector"); rc=$?
assert_eq "exit code" 0 "$rc"
echo "$out" | jq -e . >/dev/null 2>&1 || fail "stdout is not JSON"
assert_eq "contract keys" \
  "$(printf '%s\n' $CONTRACT_KEYS | sort | paste -sd' ')" \
  "$(echo "$out" | jq -r 'keys | join(" ")')"
assert_eq "schemaVersion" 1 "$(echo "$out" | jq -r .schemaVersion)"
assert_eq "id" omp "$(echo "$out" | jq -r .id)"
assert_eq "name" "Oh My Pi" "$(echo "$out" | jq -r .name)"
assert_true "ready" "$(echo "$out" | jq -r .ready)"
assert_true "hasLocalStats" "$(echo "$out" | jq -r .hasLocalStats)"
assert_empty "usageStatusText" "$(echo "$out" | jq -r .usageStatusText)"
assert_empty "authHelpText" "$(echo "$out" | jq -r .authHelpText)"
assert_eq "tierLabel" "Codex · Claude" "$(echo "$out" | jq -r .tierLabel)"
assert_eq "labels name provider and window" "Codex · 30-day|Claude · 5-hour|Claude · 7-day|Claude · 7-day (Fable)" \
  "$(echo "$out" | jq -r '[.limits[].label] | join("|")')"
assert_eq "titles equal labels" "$(echo "$out" | jq -r '[.limits[].title] | join("|")')" \
  "$(echo "$out" | jq -r '[.limits[].label] | join("|")')"
# percent stays a 0-1 fraction: Panel.qml alarms at >= 0.9 and draws the meter
# as 1 - percent.
assert_eq "percents out of range" 0 "$(echo "$out" | jq '[.limits[] | select(.percent < 0 or .percent > 1)] | length')"
assert_eq "percent values" "0.05|0.0|1.0|1.0" "$(echo "$out" | jq -r '[.limits[].percent] | join("|")')"
assert_eq "resetsAt converted from epoch ms" \
  "$(python3 -c "import datetime as dt;print(dt.datetime.fromtimestamp($res_30d/1000, dt.timezone.utc).isoformat())")" \
  "$(echo "$out" | jq -r '.limits[0].resetsAt')"
assert_eq "a window with no reset time stays blank" "" "$(echo "$out" | jq -r '.limits[1].resetsAt')"
# local stats, from the synthetic stats.db: today 3 prompts, 2 sessions, 30 tokens
assert_eq "todayPrompts" 3 "$(echo "$out" | jq -r .todayPrompts)"
assert_eq "todaySessions" 2 "$(echo "$out" | jq -r .todaySessions)"
assert_eq "todayTotalTokens" 30 "$(echo "$out" | jq -r .todayTotalTokens)"
assert_eq "todayTokensByModel" '{"model-a":10,"model-b":20}' "$(echo "$out" | jq -c .todayTokensByModel)"
assert_eq "totalPrompts" 4 "$(echo "$out" | jq -r .totalPrompts)"
assert_eq "totalSessions" 3 "$(echo "$out" | jq -r .totalSessions)"
assert_eq "activeDays" 3 "$(echo "$out" | jq -r .activeDays)"
assert_eq "activeDates" 3 "$(echo "$out" | jq -r '.activeDates | length')"
assert_eq "recentDays length" 7 "$(echo "$out" | jq -r '.recentDays | length')"
assert_eq "recentDays are token totals" "7|0|0|0|0|5|30" \
  "$(echo "$out" | jq -r '[.recentDays[].messageCount] | join("|")')"
# Model totals include older history even when the CLI's recent window does not.
assert_eq "all-time model history from database" "16|6|0|0" \
  "$(echo "$out" | jq -r '[.modelUsage["model-a"].inputTokens, .modelUsage["model-a"].outputTokens,
    .modelUsage["model-a"].cacheReadInputTokens, .modelUsage["model-a"].cacheCreationInputTokens] | join("|")')"
row_end

row "(c) empty reports (no provider signed in)"
new_case c
export OMP_STUB_USAGE_FILE="$fixtures/usage-empty.json"
out=$("$collector"); rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "limits empty" 0 "$(echo "$out" | jq -r '.limits | length')"
assert_contains "sign-in guidance" "Kimi but no usage reported" "$(echo "$out" | jq -r .authHelpText)"
assert_eq "tierLabel empty" "" "$(echo "$out" | jq -r .tierLabel)"
assert_eq "stats still reported" 4 "$(echo "$out" | jq -r .totalPrompts)"
row_end

row "(d) omp exits non-zero on both sources"
new_case d
export OMP_STUB_HOME="$work/case-d/home"   # no stats.db either: nothing is derivable
OMP_STUB_USAGE=fail OMP_STUB_STATS=fail "$collector" --write 2>"$work/d.err"; rc=$?
assert_ne "exit code" 0 "$rc"
assert_ne "stderr message" "" "$(cat "$work/d.err")"
assert_no_file "record" "$(record_path)"
assert_eq "no temp file left" "" "$(listing)"
row_end

row "(e) omp prints garbage"
new_case e
export OMP_STUB_HOME="$work/case-e/home"
OMP_STUB_USAGE=garbage OMP_STUB_STATS=garbage "$collector" --write 2>"$work/e.err"; rc=$?
assert_ne "exit code" 0 "$rc"
assert_no_file "record" "$(record_path)"
assert_eq "no temp file left" "" "$(listing)"
row_end

row "(f) omp not installed drops a stale record"
new_case f
mkdir -p "$(usage_dir)"
printf '%s\n' '{"id":"omp","totally":"stale"}' > "$(record_path)"
PATH="/usr/bin:/bin" "$collector" --write 2>"$work/f.err"; rc=$?
assert_eq "exit code" 2 "$rc"
assert_contains "message names omp" "omp not found" "$(cat "$work/f.err")"
assert_no_file "stale record removed" "$(record_path)"
PATH="/usr/bin:/bin" "$collector" >/dev/null 2>&1; rc=$?
assert_eq "print mode also exits 2" 2 "$rc"
row_end

row "(g) limits fail, local stats fine"
new_case g
OMP_STUB_USAGE=fail "$collector" --write; rc=$?
assert_eq "exit code" 0 "$rc"
rec=$(cat "$(record_path)")
assert_eq "limits empty" 0 "$(echo "$rec" | jq -r '.limits | length')"
assert_eq "prompts kept" 3 "$(echo "$rec" | jq -r .todayPrompts)"
assert_contains "auth help explains" "could not read provider limits" "$(echo "$rec" | jq -r .authHelpText)"
assert_eq "no retry for a server error" "" "$(echo "$rec" | jq -r '.retryAdvised // ""')"
assert_eq "no keys beyond the contract" "" \
  "$(echo "$rec" | jq -r --argjson known "$(contract_keys_json)" 'keys - $known | join(" ")')"
row_end

row "(h) transient limits failure: cached rows, expired rows dropped, retry advised"
new_case h
mkdir -p "$XDG_CACHE_HOME/haseen/agents/agent-usage"
printf '%s\n' "{\"fetchedAtMs\":$(( $(date +%s%3N) - 60000 )),\"limits\":[
 {\"label\":\"Claude · 7-day\",\"title\":\"Claude · 7-day\",\"percent\":0.75,\"resetsAt\":\"2099-01-01T00:00:00+00:00\"},
 {\"label\":\"Claude · 5-hour\",\"title\":\"Claude · 5-hour\",\"percent\":0.5,\"resetsAt\":\"2000-01-01T00:00:00+00:00\"}]}" \
  > "$XDG_CACHE_HOME/haseen/agents/agent-usage/omp-limits-all.json"
OMP_STUB_USAGE=failnet "$collector" --write; rc=$?
assert_eq "exit code" 0 "$rc"
rec=$(cat "$(record_path)")
assert_eq "only the open cached window survives" "Claude · 7-day" "$(echo "$rec" | jq -r '.limits[0].label')"
assert_eq "one row" 1 "$(echo "$rec" | jq -r '.limits | length')"
assert_true "retryAdvised" "$(echo "$rec" | jq -r .retryAdvised)"
assert_eq "retryAdvised is the only extra key" "retryAdvised" \
  "$(echo "$rec" | jq -r --argjson known "$(contract_keys_json)" 'keys - $known | join(" ")')"
row_end

row "(i) no-data statuses skipped, percent clamped"
new_case i
export OMP_STUB_USAGE_FILE="$fixtures/usage-clamped.json"
out=$("$collector")
assert_eq "only the warning row survives" "Claude · 5-hour" "$(echo "$out" | jq -r '.limits[0].label')"
assert_eq "one row" 1 "$(echo "$out" | jq -r '.limits | length')"
assert_eq "1.5 clamped to 1" true "$(echo "$out" | jq -r '.limits[0].percent == 1')"
row_end

row "(j) several accounts on one provider: shared:true never merges accounts"
new_case j
export OMP_STUB_USAGE_FILE="$fixtures/usage-accounts.json"
out=$("$collector")
assert_eq "a row per account and window, tagged by account" \
  "Codex · 30-day|Claude · 5-hour (alice)|Claude · 5-hour (bob)|Claude · 7-day (alice)|Claude · 7-day (bob)|Claude · 7-day (Fable) (alice)|Claude · 7-day (Fable) (bob)" \
  "$(echo "$out" | jq -r '[.limits[].label] | join("|")')"
# alice's older repeat (0.99) is replaced by her newer report, never summed or
# maxed against bob's.
assert_eq "each account keeps its own percentage" "0.05|0.2|0.6|0.4|0.9|0.5|0.1" \
  "$(echo "$out" | jq -r '[.limits[].percent] | join("|")')"
assert_eq "each account keeps its own reset" \
  "$(iso $res_30d)|$(iso $res_5h_a)|$(iso $res_5h_b)|$(iso $res_7d_a)|$(iso $res_7d_b)|$(iso $res_7d_a)|$(iso $res_7d_b)" \
  "$(echo "$out" | jq -r '[.limits[].resetsAt] | join("|")')"
assert_eq "tierLabel" "Codex · Claude" "$(echo "$out" | jq -r .tierLabel)"
assert_eq "all-provider stats kept" "4|3" "$(echo "$out" | jq -r '[.totalPrompts,.totalSessions] | join("|")')"
new_case j2
export OMP_STUB_USAGE_FILE="$fixtures/usage-same-local.json"
out=$("$collector")
assert_eq "colliding names grow until they differ" \
  "Claude · 5-hour (alice@example.com/Personal)|Claude · 5-hour (alice@work.example)|Claude · 5-hour (alice@example.com/Team)" \
  "$(echo "$out" | jq -r '[.limits[].label] | join("|")')"
assert_eq "one account in two organisations stays two rows" "0.1|0.2|0.3" \
  "$(echo "$out" | jq -r '[.limits[].percent] | join("|")')"
row_end

row "(k) --limits-only skips the stats walk and carries the previous numbers"
new_case k
"$collector" --write
assert_eq "stats walked in the full run" 3 "$(jq -r .todayPrompts "$(record_path)")"
: > "$fixtures/calls.log"
"$collector" --limits-only --write; rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "omp stats not called" "" "$(calls | grep '^stats' || true)"
assert_eq "fresh limits cache reused, no omp call at all" "" "$(calls)"
"$collector" --force --limits-only --write; rc=$?
assert_eq "forced limits-only still probes" 1 "$(usage_calls)"
assert_eq "and still skips the stats walk" "" "$(calls | grep '^stats' || true)"
assert_eq "stats carried forward" 3 "$(jq -r .todayPrompts "$(record_path)")"
assert_eq "recentDays carried forward" 7 "$(jq -r '.recentDays | length' "$(record_path)")"
assert_eq "hasLocalStats carried forward" true "$(jq -r .hasLocalStats "$(record_path)")"
# and with nothing to carry: honest zeros plus an explanation
new_case k2
"$collector" --limits-only --write; rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "no stats invented" 0 "$(jq -r .todayTotalTokens "$(record_path)")"
assert_eq "hasLocalStats false" false "$(jq -r .hasLocalStats "$(record_path)")"
assert_contains "status explains" "Local stats unavailable" "$(jq -r .usageStatusText "$(record_path)")"
assert_eq "limits still present" 4 "$(jq -r '.limits | length' "$(record_path)")"
row_end

row "(l) --force bypasses the limits cache"
new_case l
"$collector" --write
: > "$fixtures/calls.log"
OMP_STUB_USAGE=fail "$collector" --write >/dev/null 2>&1
assert_eq "cached probe reused without --force" 4 "$(jq -r '.limits | length' "$(record_path)")"
assert_eq "no usage probe while the cache is fresh" 0 "$(usage_calls)"
OMP_STUB_USAGE=fail "$collector" --force --write >/dev/null 2>&1
assert_eq "forced probe reached omp" 1 "$(usage_calls)"
assert_eq "failed probe keeps the last known rows" 4 "$(jq -r '.limits | length' "$(record_path)")"
assert_contains "and says so" "could not read provider limits" "$(jq -r .authHelpText "$(record_path)")"
row_end

row "(m) --write is atomic and leaves no temp file; --help exits 0"
new_case m
"$collector" --write; rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "only the record is in the usage directory" "omp.json" "$(listing)"
assert_eq "record mode 600" "600" "$(PATH=/usr/bin:/bin stat -c %a "$(record_path)")"
assert_eq "record ends in a newline" "0a" "$(PATH=/usr/bin:/bin tail -c1 "$(record_path)" | od -An -tx1 | tr -d ' ')"
"$collector" --help >/dev/null 2>&1
assert_eq "--help exit code" 0 "$?"
row_end

row "(s) stats database missing: no invented numbers, limits still served"
new_case s
export OMP_STUB_HOME="$work/case-s/home"
out=$("$collector"); rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "hasLocalStats false" false "$(echo "$out" | jq -r .hasLocalStats)"
assert_contains "status explains" "Local stats unavailable" "$(echo "$out" | jq -r .usageStatusText)"
assert_eq "no stat field filled in" "0|0|0|0|0" \
  "$(echo "$out" | jq -r '[.todayPrompts,.todaySessions,.todayTotalTokens,.totalPrompts,.totalSessions] | join("|")')"
assert_eq "no recentDays rows" 0 "$(echo "$out" | jq -r '.recentDays | length')"
assert_eq "no modelUsage buckets" 0 "$(echo "$out" | jq -r '.modelUsage | length')"
assert_eq "limits unaffected" 4 "$(echo "$out" | jq -r '.limits | length')"
row_end

# ------------------------------------------------------ the Claude (OMP) record

row "(t) claude: Anthropic limits per account, Anthropic-only history"
new_case t
export OMP_STUB_USAGE_FILE="$fixtures/usage-accounts.json"
out=$(cd / && "$claude_collector"); rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "contract keys" \
  "$(printf '%s\n' $CONTRACT_KEYS | sort | paste -sd' ')" \
  "$(echo "$out" | jq -r 'keys | join(" ")')"
assert_eq "id" claude "$(echo "$out" | jq -r .id)"
assert_eq "name" "Claude (OMP)" "$(echo "$out" | jq -r .name)"
assert_eq "six rows, one per account and window, no Codex" \
  "Claude · 5-hour (alice)|Claude · 5-hour (bob)|Claude · 7-day (alice)|Claude · 7-day (bob)|Claude · 7-day (Fable) (alice)|Claude · 7-day (Fable) (bob)" \
  "$(echo "$out" | jq -r '[.limits[].label] | join("|")')"
assert_eq "each account keeps its own percentage" "0.2|0.6|0.4|0.9|0.5|0.1" \
  "$(echo "$out" | jq -r '[.limits[].percent] | join("|")')"
assert_eq "each account keeps its own reset" \
  "$(iso $res_5h_a)|$(iso $res_5h_b)|$(iso $res_7d_a)|$(iso $res_7d_b)|$(iso $res_7d_a)|$(iso $res_7d_b)" \
  "$(echo "$out" | jq -r '[.limits[].resetsAt] | join("|")')"
# no plan is invented; the history is labelled as every account combined
assert_eq "tierLabel" "Oh My Pi · 2 accounts · history of all accounts combined" "$(echo "$out" | jq -r .tierLabel)"
assert_true "hasLocalStats" "$(echo "$out" | jq -r .hasLocalStats)"
assert_empty "usageStatusText" "$(echo "$out" | jq -r .usageStatusText)"
# the DeepSeek session s2 (20 tokens, prompt u3) is left out everywhere
assert_eq "today" "2|1|10" "$(echo "$out" | jq -r '[.todayPrompts,.todaySessions,.todayTotalTokens] | join("|")')"
assert_eq "todayTokensByModel" '{"model-a":10}' "$(echo "$out" | jq -c .todayTokensByModel)"
assert_eq "all time" "3|2|3" "$(echo "$out" | jq -r '[.totalPrompts,.totalSessions,.activeDays] | join("|")')"
assert_eq "recentDays" "7|0|0|0|0|5|10" "$(echo "$out" | jq -r '[.recentDays[].messageCount] | join("|")')"
assert_eq "modelUsage is Anthropic's only" "model-a" "$(echo "$out" | jq -r '.modelUsage | keys | join(" ")')"
assert_eq "Claude all-time model history" "16|6|0|0" \
  "$(echo "$out" | jq -r '.modelUsage["model-a"] | [.inputTokens,.outputTokens,.cacheReadInputTokens,.cacheCreationInputTokens] | join("|")')"
row_end

row "(u) claude and omp keep separate limit caches; the merged legacy cache is ignored"
new_case u
export OMP_STUB_USAGE_FILE="$fixtures/usage-accounts.json"
"$collector" --write
"$claude_collector" --write
assert_eq "claude did not reuse the all-provider probe" 2 "$(usage_calls)"
"$collector" --limits-only --write
"$claude_collector" --limits-only --write
assert_eq "each reuses its own fresh probe" 2 "$(usage_calls)"
assert_eq "omp keeps Codex" 7 "$(jq -r '.limits | length' "$(record_path)")"
assert_eq "claude keeps Claude only" 6 "$(jq -r '.limits | length' "$(claude_record)")"
assert_eq "omp stats unchanged by limits-only" 4 "$(jq -r .totalPrompts "$(record_path)")"
assert_eq "claude stats unchanged by limits-only" 3 "$(jq -r .totalPrompts "$(claude_record)")"
new_case u2
export OMP_STUB_USAGE_FILE="$fixtures/usage-accounts.json"
mkdir -p "$XDG_CACHE_HOME/haseen/agents/agent-usage"
printf '%s\n' "{\"fetchedAtMs\":$(date +%s%3N),\"limits\":[
 {\"label\":\"Claude · 7-day\",\"title\":\"Claude · 7-day\",\"percent\":0.9,\"resetsAt\":\"2099-01-01T00:00:00+00:00\"}]}" \
  > "$XDG_CACHE_HOME/haseen/agents/agent-usage/omp-limits.json"
out=$("$collector")
assert_eq "fresh legacy cache still means a probe" 1 "$(usage_calls)"
assert_eq "no merged row survives" 0 "$(echo "$out" | jq '[.limits[] | select(.label == "Claude · 7-day")] | length')"
row_end

row "(v) claude cutover: Claude Code's record is replaced, never carried"
new_case v
export OMP_STUB_USAGE_FILE="$fixtures/usage-accounts.json"
mkdir -p "$(usage_dir)"
printf '%s\n' '{"schemaVersion":1,"id":"claude","name":"Claude Code","tierLabel":"Max 20x","hasLocalStats":true,
 "todayPrompts":55,"totalPrompts":999,"recentDays":[{"date":"2026-01-01","messageCount":1}],
 "limits":[{"label":"Session (5-hour)","percent":0.3,"resetsAt":""}]}' > "$(claude_record)"
"$claude_collector" --limits-only --write; rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "name" "Claude (OMP)" "$(jq -r .name "$(claude_record)")"
assert_eq "Claude Code numbers not carried" "0|0|0" \
  "$(jq -r '[.todayPrompts,.totalPrompts,(.recentDays | length)] | join("|")' "$(claude_record)")"
assert_eq "hasLocalStats false" false "$(jq -r .hasLocalStats "$(claude_record)")"
assert_contains "status explains" "Local stats unavailable" "$(jq -r .usageStatusText "$(claude_record)")"
assert_eq "no plan, no history claimed" "Oh My Pi · 2 accounts" "$(jq -r .tierLabel "$(claude_record)")"
assert_eq "native limits" 6 "$(jq -r '.limits | length' "$(claude_record)")"
"$claude_collector" --write
"$claude_collector" --limits-only --write
assert_eq "own stats carried after a full run" "2|3|true" \
  "$(jq -r '[.todayPrompts,.totalPrompts,.hasLocalStats] | join("|")' "$(claude_record)")"
assert_no_file "omp record untouched" "$(record_path)"
row_end

row "(w) claude failures: no invented numbers"
new_case w
export OMP_STUB_USAGE_FILE="$fixtures/usage-accounts.json"
export OMP_STUB_HOME="$work/case-w/home"   # no stats.db
OMP_STUB_USAGE=fail "$claude_collector" --write 2>/dev/null; rc=$?
assert_eq "no source at all exits 3" 3 "$rc"
assert_no_file "and writes nothing" "$(claude_record)"
mkdir -p "$(usage_dir)"
printf '%s\n' '{"id":"claude","name":"Claude Code","hasLocalStats":true,"totalPrompts":999}' > "$(claude_record)"
OMP_STUB_USAGE=fail "$claude_collector" --write 2>/dev/null; rc=$?
assert_eq "foreign record source failure exits 3" 3 "$rc"
assert_no_file "failed native cutover removes Claude Code stats" "$(claude_record)"
printf '%s\n' '{"id":"claude","name":"Claude (OMP)","hasLocalStats":true,"totalPrompts":23}' > "$(claude_record)"
OMP_STUB_USAGE=fail "$claude_collector" --write 2>/dev/null; rc=$?
assert_eq "native record source failure exits 3" 3 "$rc"
assert_eq "native history preserved on unavailable source" 23 "$(jq -r .totalPrompts "$(claude_record)")"
out=$("$claude_collector"); rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "hasLocalStats false" false "$(echo "$out" | jq -r .hasLocalStats)"
assert_eq "no stat field filled in" "0|0|0|0|0" \
  "$(echo "$out" | jq -r '[.todayPrompts,.todaySessions,.todayTotalTokens,.totalPrompts,.totalSessions] | join("|")')"
assert_eq "no history claimed" "Oh My Pi · 2 accounts" "$(echo "$out" | jq -r .tierLabel)"
new_case w2
export OMP_STUB_USAGE_FILE="$fixtures/usage-accounts.json"
"$claude_collector" --write
OMP_STUB_USAGE=failnet "$claude_collector" --force --write; rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "last per-account rows kept" 6 "$(jq -r '.limits | length' "$(claude_record)")"
assert_true "retryAdvised" "$(jq -r .retryAdvised "$(claude_record)")"
assert_contains "and says so" "could not read provider limits" "$(jq -r .authHelpText "$(claude_record)")"
new_case w3
export OMP_STUB_USAGE_FILE="$fixtures/usage.json"
"$claude_collector" --write
assert_eq "single account: no tag, no Codex" "Claude · 5-hour|Claude · 7-day|Claude · 7-day (Fable)" \
  "$(jq -r '[.limits[].label] | join("|")' "$(claude_record)")"
export OMP_STUB_USAGE_FILE="$fixtures/usage-empty.json"
"$claude_collector" --force --write
assert_contains "Kimi-only sign-in is not Claude's" "No Claude account is signed in" \
  "$(jq -r .authHelpText "$(claude_record)")"
row_end

row "(y) identity edges: providers never share an account, newest repeat wins, no id is never proof"
new_case y
export OMP_STUB_USAGE_FILE="$fixtures/usage-identity.json"
out=$("$collector"); rc=$?
assert_eq "exit code" 0 "$rc"
# the Codex report shares carol's account id but is its own subscription
assert_eq "Codex row kept beside Claude's" 1 "$(echo "$out" | jq '[.limits[] | select(.label | startswith("Codex"))] | length')"
# carol's newer report (0.3) came first; the older repeat (0.8) must not replace it
assert_eq "newest repeat kept, the older one dropped, id-less reports both kept" "0.3|0.1|0.2|0.05" \
  "$(echo "$out" | jq -r '[.limits[].percent] | join("|")')"
assert_eq "each Claude row tells its account apart" 3 \
  "$(echo "$out" | jq '[.limits[] | select(.label | startswith("Claude")) | .label] | unique | length')"
assert_eq "each account keeps its own reset" "$(iso $res_5h_a)|$(iso $res_5h_b)|$(iso $res_5h_b)|$(iso $res_30d)" \
  "$(echo "$out" | jq -r '[.limits[].resetsAt] | join("|")')"
out=$("$claude_collector"); rc=$?
assert_eq "claude exit code" 0 "$rc"
assert_eq "claude: same rows, no Codex" "0.3|0.1|0.2" "$(echo "$out" | jq -r '[.limits[].percent] | join("|")')"
assert_contains "claude: three accounts counted" "Oh My Pi · 3 accounts" "$(echo "$out" | jq -r .tierLabel)"
row_end

row "(z) one model id on two providers; unattributed prompts"
new_case z
export OMP_STUB_HOME="$fixtures/combined-home"
export OMP_STUB_STATS_FILE="$fixtures/stats-combined.txt"
out=$("$claude_collector"); rc=$?
assert_eq "claude exit code" 0 "$rc"
assert_eq "claude today: Anthropic prompt, session, tokens only" "1|1|10" \
  "$(echo "$out" | jq -r '[.todayPrompts,.todaySessions,.todayTotalTokens] | join("|")')"
assert_eq "claude todayTokensByModel: the Anthropic half of the shared id" '{"shared-model":10}' \
  "$(echo "$out" | jq -c .todayTokensByModel)"
assert_eq "claude all time: the unattributed prompt is not Claude's" "1|2|2" \
  "$(echo "$out" | jq -r '[.totalPrompts,.totalSessions,.activeDays] | join("|")')"
assert_eq "claude recentDays: yesterday 5, today 10" "5|10" \
  "$(echo "$out" | jq -r '[.recentDays[-2:][].messageCount] | join("|")')"
assert_eq "Claude shared-model history excludes the other provider" "6|4" \
  "$(echo "$out" | jq -r '.modelUsage["shared-model"] | [.inputTokens,.outputTokens] | join("|")')"
assert_eq "model outside the CLI's recent window remains visible" 3 \
  "$(echo "$out" | jq -r '.modelUsage["claude-only"].inputTokens')"
out=$("$collector"); rc=$?
assert_eq "omp exit code" 0 "$rc"
assert_eq "omp today: every provider, the unattributed prompt included" "3|2|50" \
  "$(echo "$out" | jq -r '[.todayPrompts,.todaySessions,.todayTotalTokens] | join("|")')"
assert_eq "omp todayTokensByModel: both halves of the shared id" '{"shared-model":50}' \
  "$(echo "$out" | jq -c .todayTokensByModel)"
assert_eq "omp all time" "3|3|2" "$(echo "$out" | jq -r '[.totalPrompts,.totalSessions,.activeDays] | join("|")')"
assert_eq "OMP shared-model history includes both actual providers" "36|14" \
  "$(echo "$out" | jq -r '.modelUsage["shared-model"] | [.inputTokens,.outputTokens] | join("|")')"
row_end

row "(aa) a signed-in account with only unmeasured windows is not reported as signed out"
new_case aa
export OMP_STUB_USAGE_FILE="$fixtures/usage-nodata.json"
out=$("$claude_collector"); rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "no invented meter" 0 "$(echo "$out" | jq '.limits | length')"
assert_contains "the account is counted" "Oh My Pi · 1 account" "$(echo "$out" | jq -r .tierLabel)"
assert_not_contains "help does not deny the sign-in" "No Claude account is signed in" \
  "$(echo "$out" | jq -r .authHelpText)"
out=$("$collector")
assert_not_contains "omp help does not deny it either" "No provider is signed in" \
  "$(echo "$out" | jq -r .authHelpText)"
row_end

row "(ab) limits-only provenance: the stats gap is carried, Claude Code's record is dropped with omp"
new_case ab
export OMP_STUB_HOME="$work/case-ab/home"   # no stats.db: the full run records why
"$claude_collector" --write; rc=$?
assert_eq "full run exit code" 0 "$rc"
reason=$(jq -r .usageStatusText "$(claude_record)")
assert_contains "full run names the missing database" "stats.db not found" "$reason"
"$claude_collector" --limits-only --write; rc=$?
assert_eq "limits-only exit code" 0 "$rc"
assert_eq "the real reason is carried, not replaced" "$reason" "$(jq -r .usageStatusText "$(claude_record)")"
assert_eq "still no local stats" false "$(jq -r .hasLocalStats "$(claude_record)")"
new_case ab2
mkdir -p "$(usage_dir)"
printf '%s\n' '{"schemaVersion":1,"id":"claude","name":"Claude Code","totalPrompts":999,
 "limits":[{"label":"Session (5-hour)","percent":0.3,"resetsAt":""}]}' > "$(claude_record)"
PATH="/usr/bin:/bin" "$claude_collector" --write 2>/dev/null; rc=$?
assert_eq "omp missing exits 2" 2 "$rc"
assert_no_file "a leftover Claude Code record is not left frozen" "$(claude_record)"
row_end

# --------------------------------------------------------------- the wrapper

packaged_dir="$work/packaged"
mkdir -p "$packaged_dir/bin"
cat > "$packaged_dir/bin/omarchy-agent-usage-update" <<'PKG'
#!/bin/bash
printf 'argv:[%s]\n' "$*" >> "$PACKAGED_LOG"
exit "${PACKAGED_EXIT:-0}"
PKG
chmod +x "$packaged_dir/bin/omarchy-agent-usage-update"

run_wrapper() { # run_wrapper <args...>
  PACKAGED_LOG="$work/packaged.log" OMARCHY_PATH="$packaged_dir" "$wrapper" "$@"
}

row "(n) wrapper: packaged updater gets the argv minus plugin-owned ids, plugin collector runs too"
new_case n
: > "$work/packaged.log"
run_wrapper --force --limits-only --except fireworks omp 2>"$work/n.err"; rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "packaged argv forwarded" "argv:[--except claude --except omp --force --limits-only --except fireworks omp]" \
  "$(cat "$work/packaged.log")"
assert_contains "our collector ran" "usage --json" "$(calls)"
assert_eq "record written by the wrapper" 4 "$(jq -r '.limits | length' "$(record_path)")"
assert_no_file "claude not asked for" "$(claude_record)"
assert_empty "wrapper stderr" "$(cat "$work/n.err")"
row_end

row "(o) wrapper: --except and agent selection pick the plugin collectors"
new_case o
: > "$work/packaged.log"
run_wrapper --except omp 2>/dev/null
assert_eq "packaged argv forwarded" "argv:[--except claude --except omp --except omp]" "$(cat "$work/packaged.log")"
assert_no_file "no omp record" "$(record_path)"
assert_eq "claude still refreshed" "Claude (OMP)" "$(jq -r .name "$(claude_record)")"
new_case o2
: > "$work/packaged.log"
run_wrapper --limits-only codex 2>/dev/null
assert_eq "packaged argv forwarded" "argv:[--except claude --except omp --limits-only codex]" "$(cat "$work/packaged.log")"
assert_empty "omp never called" "$(calls)"
assert_eq "no plugin record" "" "$(listing)"
new_case o3
: > "$work/packaged.log"
run_wrapper --limits-only claude 2>/dev/null
assert_eq "packaged argv forwarded" "argv:[--except claude --except omp --limits-only claude]" "$(cat "$work/packaged.log")"
assert_eq "only the claude record" "claude.json" "$(listing)"
row_end

row "(p) wrapper: omp missing is silent and drops the stale records"
new_case p
mkdir -p "$(usage_dir)"
printf '%s\n' '{"id":"omp","stale":true}' > "$(record_path)"
printf '%s\n' '{"id":"claude","name":"Claude (OMP)","stale":true}' > "$(claude_record)"
: > "$work/packaged.log"
PACKAGED_LOG="$work/packaged.log" OMARCHY_PATH="$packaged_dir" PATH="/usr/bin:/bin" \
  "$wrapper" 2>"$work/p.err"; rc=$?
assert_eq "exit code" 0 "$rc"
assert_eq "packaged updater still ran" "argv:[--except claude --except omp]" "$(cat "$work/packaged.log")"
assert_empty "no stderr" "$(cat "$work/p.err")"
assert_no_file "stale omp record removed" "$(record_path)"
assert_no_file "stale claude record removed" "$(claude_record)"
row_end

row "(q) wrapper: packaged updater missing, plugin collector still runs"
new_case q
OMARCHY_PATH="$work/nothing" "$wrapper" 2>"$work/q.err"; rc=$?
assert_eq "exit code" 0 "$rc"
assert_contains "warning names the path" "is missing" "$(cat "$work/q.err")"
assert_file "record still written" "$(record_path)"
row_end

row "(r) wrapper: failure isolation in both directions"
# a failing packaged updater does not stop our collector ...
new_case r
: > "$work/packaged.log"
PACKAGED_LOG="$work/packaged.log" PACKAGED_EXIT=1 OMARCHY_PATH="$packaged_dir" \
  "$wrapper" >/dev/null 2>"$work/r.err"; rc=$?
assert_eq "packaged failure is the exit status" 1 "$rc"
assert_file "collector still ran" "$(record_path)"
assert_empty "no collector noise" "$(cat "$work/r.err")"
# ... and a failing collector does not turn a healthy packaged run into a
# failed one: it reports on stderr and leaves the exit status alone.
new_case r2
export OMP_STUB_HOME="$work/case-r2/home"
OMP_STUB_USAGE=garbage OMP_STUB_STATS=garbage PACKAGED_LOG="$work/packaged.log" \
  OMARCHY_PATH="$packaged_dir" "$wrapper" >/dev/null 2>"$work/r2.err"; rc=$?
assert_eq "packaged status kept" 0 "$rc"
assert_contains "collector failure named" "omp collector failed" "$(cat "$work/r2.err")"
assert_no_file "nothing written" "$(record_path)"
assert_no_file "no claude record either" "$(claude_record)"
assert_eq "no temp file left" "" "$(listing)"
row_end

row "(x) wrapper + the real packaged updater: Claude Code's collector never runs"
real_updater="${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-agent-usage-update"
if [[ -x $real_updater ]]; then
  real_dir="$work/real"
  mkdir -p "$real_dir/bin"
  cp "$real_updater" "$real_dir/bin/omarchy-agent-usage-update"
  cat > "$real_dir/bin/omarchy-agent-usage-claude" <<'CODE'
#!/bin/bash
printf 'code %s\n' "$*" >> "$CODE_LOG"
printf '%s\n' '{"id":"claude","name":"Claude Code","totalPrompts":999}'
CODE
  cat > "$real_dir/bin/omarchy-agent-usage-codex" <<'CODEX'
#!/bin/bash
printf '%s\n' '{"id":"codex","name":"Codex"}'
CODEX
  chmod +x "$real_dir/bin/"*
  for argv in "" "--force" "--limits-only" "claude" "--limits-only claude" "--except fireworks"; do
    new_case x
    export OMP_STUB_USAGE_FILE="$fixtures/usage-accounts.json"
    : > "$work/code.log"
    # shellcheck disable=SC2086
    CODE_LOG="$work/code.log" OMARCHY_PATH="$real_dir" "$wrapper" $argv 2>/dev/null
    assert_empty "[$argv] Claude Code collector not run" "$(cat "$work/code.log")"
    assert_eq "[$argv] claude record is the native one" "Claude (OMP)|6" \
      "$(jq -r '[.name, (.limits | length)] | join("|")' "$(claude_record)")"
  done
  assert_eq "other packaged collectors still run" "Codex" "$(jq -r .name "$(usage_dir)/codex.json")"
  new_case x2
  CODE_LOG="$work/code.log" OMARCHY_PATH="$real_dir" "$wrapper" --except claude 2>/dev/null
  assert_no_file "a disabled claude is written by nobody" "$(claude_record)"
  assert_empty "Claude Code collector not run" "$(cat "$work/code.log")"
else
  printf '     (skipped: %s not installed)\n' "$real_updater"
fi
row_end

# ============================================================================
printf '\n%s\n' "----------------------------------------"
if (( TOTAL_FAIL == 0 )); then
  printf 'all rows passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$TOTAL_FAIL"
exit 1
