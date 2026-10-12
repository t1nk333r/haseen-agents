#!/bin/bash
# bin/spend-status OMP handling.
#
# The helper leaves OMP out of the Spend figure unless the caller passes
# --include-omp: oh-my-pi is a subscription harness whose API-rate cost is a
# would-be figure, not money out of pocket, and on this host it dominates every
# period. Other callers rely on that default (the onefile spend producer refuses
# a result that still counts OMP). The Spend tab passes --include-omp, by
# default, as an overview of what the usage would have cost at API rates.
# CodeBurn cannot filter a provider out of the status payload (and 0.9.24
# forbids --provider together with --scope combined), so the wrapper reads
# `codeburn status --provider omp` FIRST and the helper subtracts it;
# `codeburn models --format json` is the provider-attributed listing that
# rebuilds the rows that remain.
#
# Contract pinned here, against a stubbed codeburn (no network, no real usage):
#   1. by default the OMP-only read happens before the main one, and only when
#      an OMP sessions directory exists;
#   2. totals, cache tokens and activities come back net of OMP, with the
#      cache-hit ratio recomputed;
#   3. the provider row is gone and the model list is the non-OMP rows, merged
#      by display name (a name both providers carry keeps the non-OMP share);
#   4. the payload says it happened (`ompExcluded`, `ompExcludedTotals`);
#   5. with --include-omp there is no OMP-only read and the totals include OMP.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

CHECKS=0
ok() { printf 'ok   - %s\n' "$1"; CHECKS=$((CHECKS + 1)); }
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/calls" "$TMP/omp-sessions"

cat > "$TMP/main.json" <<'JSON'
{"generated":"2026-09-20T17:00:00.000Z","currency":{"symbol":"$","code":"USD"},
 "current":{"label":"Today (2026-09-20)","cost":100.0,"calls":10,"sessions":4,
  "inputTokens":1000000,"outputTokens":200000,"cacheReadTokens":5000000,"cacheWriteTokens":100000,
  "cacheHitPercent":83.33,"providers":{"omp":60.0,"claude":40.0},
  "providerDetails":[
    {"id":"omp","label":"OMP","cost":60.0,"calls":6,"sessions":2,"hasUsage":true,"inputTokens":600000,"outputTokens":120000},
    {"id":"claude","label":"Claude","cost":40.0,"calls":4,"sessions":2,"hasUsage":true,"inputTokens":400000,"outputTokens":80000}],
  "topModels":[{"name":"Opus 5","cost":90.0,"calls":8},{"name":"deepseek-flash","cost":5.0,"calls":1},{"name":"grok-4.6","cost":5.0,"calls":1}],
  "topActivities":[{"name":"Coding","cost":80.0,"turns":7},{"name":"Exploration","cost":20.0,"turns":3}]}}
JSON

cat > "$TMP/omp.json" <<'JSON'
{"generated":"2026-09-20T17:00:00.000Z","currency":{"symbol":"$","code":"USD"},
 "current":{"label":"Today (2026-09-20)","cost":60.0,"calls":6,"sessions":2,
  "inputTokens":600000,"outputTokens":120000,"cacheReadTokens":3000000,"cacheWriteTokens":60000,
  "cacheHitPercent":83.33,
  "providerDetails":[{"id":"omp","label":"OMP","cost":60.0,"calls":6,"sessions":2,"hasUsage":true,"inputTokens":600000,"outputTokens":120000}],
  "topModels":[{"name":"Opus 5","cost":55.0,"calls":5},{"name":"deepseek-flash","cost":5.0,"calls":1}],
  "topActivities":[{"name":"Coding","cost":50.0,"turns":5},{"name":"Exploration","cost":10.0,"turns":1}]}}
JSON

cat > "$TMP/models.json" <<'JSON'
[{"provider":"omp","model":"anthropic/claude-opus-5","modelDisplayName":"Opus 5","costUSD":55.0,"calls":5,"inputTokens":500000,"outputTokens":100000,"cacheReadTokens":2500000,"cacheWriteTokens":50000},
 {"provider":"claude","model":"claude-opus-5","modelDisplayName":"Opus 5","costUSD":35.0,"calls":4,"inputTokens":400000,"outputTokens":80000,"cacheReadTokens":2000000,"cacheWriteTokens":40000},
 {"provider":"hermes","model":"grok-4.6","modelDisplayName":"grok-4.6","costUSD":5.0,"calls":1,"inputTokens":50000,"outputTokens":10000,"cacheReadTokens":100000,"cacheWriteTokens":1000},
 {"provider":"omp","model":"deepseek/deepseek-flash","modelDisplayName":"deepseek-flash","costUSD":5.0,"calls":1,"inputTokens":10000,"outputTokens":2000,"cacheReadTokens":5000,"cacheWriteTokens":100}]
JSON

cat > "$TMP/bin/codeburn" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "\$STUB_LOG"
case "\$1" in
  status)
    if [[ "\$*" == *"--provider omp"* ]]; then cat "$TMP/omp.json"
    else cat "$TMP/main.json"; fi
    ;;
  models)
    cat "$TMP/models.json"
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/codeburn"

export CODEBURN_BIN="$TMP/bin/codeburn"
export CODEBURN_STABLE_LINK="$TMP/calls/stable-codeburn"
export STUB_LOG="$TMP/calls/argv.log"
export CODEBURN_OMP_SESSIONS_DIR="$TMP/omp-sessions"
: > "$STUB_LOG"

OUT="$(./bin/spend-status today 2>"$TMP/stderr.log")"
ARGV="$(cat "$STUB_LOG")"

FIRST="$(head -n 1 <<<"$ARGV")"
if [[ "$FIRST" == *"status"* && "$FIRST" == *"--provider omp"* ]]; then
  ok "the OMP-only status is read before the main one"
else
  fail "expected the OMP read first, got: $ARGV"
fi

python3 - "$OUT" <<'PY' || exit 1
import json, sys
status = json.loads(sys.argv[1])
current = status.get("current") or {}
def check(label, got, want):
    if got != want:
        print("FAIL - %s (expected %r, got %r)" % (label, want, got), file=sys.stderr)
        sys.exit(1)
    print("ok   - " + label)

check("cost is net of OMP", round(current.get("cost"), 2), 40.0)
check("calls, sessions and tokens are net of OMP",
      (current.get("calls"), current.get("sessions"),
       current.get("inputTokens"), current.get("outputTokens")),
      (4, 2, 400000, 80000))
check("cache tokens are net of OMP",
      (current.get("cacheReadTokens"), current.get("cacheWriteTokens")), (2000000, 40000))
if abs(float(current.get("cacheHitPercent") or 0) - 100 * 2000000 / (2000000 + 400000)) > 1e-6:
    print("FAIL - cacheHitPercent was not recomputed", file=sys.stderr)
    sys.exit(1)
print("ok   - cacheHitPercent is recomputed from what is left")
check("the OMP provider row is gone",
      [d.get("id") for d in current.get("providerDetails") or []], ["claude"])
check("the providers map has no OMP", sorted((current.get("providers") or {}).keys()), ["claude"])
check("top models are the non-OMP rows, merged by name",
      [(m.get("name"), round(m.get("cost"), 2)) for m in current.get("topModels") or []],
      [("Opus 5", 35.0), ("grok-4.6", 5.0)])
check("token rows follow the same model list",
      [(m.get("name"), m.get("totalTokens")) for m in status.get("modelTokens") or []],
      [("Opus 5", 2520000), ("grok-4.6", 161000)])
check("activities are net of OMP",
      [(a.get("name"), round(a.get("cost"), 2)) for a in current.get("topActivities") or []],
      [("Coding", 30.0), ("Exploration", 10.0)])
check("the payload says OMP was excluded", status.get("ompExcluded"), True)
check("the payload records what was excluded", status.get("ompExcludedTotals"),
      {"cost": 60.0, "calls": 6, "sessions": 2})
PY
CHECKS=$((CHECKS + 1))

# Without an OMP sessions directory there is nothing to exclude, the OMP read
# is skipped, and the payload is CodeBurn's own.
: > "$STUB_LOG"
OUT2="$(CODEBURN_OMP_SESSIONS_DIR="$TMP/no-omp" ./bin/spend-status today 2>/dev/null)"
ARGV2="$(cat "$STUB_LOG")"
if grep -q -- '--provider omp' <<<"$ARGV2"; then
  fail "the OMP read ran with no OMP on disk"
else
  ok "no OMP sessions, no OMP read"
fi
python3 - "$OUT2" <<'PY' || exit 1
import json, sys
status = json.loads(sys.argv[1])
current = status.get("current") or {}
if current.get("cost") != 100.0 or "ompExcluded" in status or "ompExcludedTotals" in status:
    print("FAIL - the payload changed with no OMP to exclude", file=sys.stderr)
    sys.exit(1)
print("ok   - the payload is untouched when no OMP is installed")
PY
CHECKS=$((CHECKS + 1))

# With --include-omp OMP stays in the totals: with an OMP sessions directory
# present, no OMP-only read happens and the payload is CodeBurn's own.
: > "$STUB_LOG"
OUT_DEFAULT="$(./bin/spend-status today --include-omp 2>/dev/null)"
ARGV_DEFAULT="$(cat "$STUB_LOG")"
if grep -q -- '--provider omp' <<<"$ARGV_DEFAULT"; then
  fail "the OMP read ran although --include-omp was given"
else
  ok "OMP is not read when it is to be included"
fi
python3 - "$OUT_DEFAULT" <<'PY' || exit 1
import json, sys
status = json.loads(sys.argv[1])
current = status.get("current") or {}
if (current.get("cost") != 100.0 or current.get("calls") != 10
        or "ompExcluded" in status or "ompExcludedTotals" in status):
    print("FAIL - the --include-omp payload is not CodeBurn's own, OMP included", file=sys.stderr)
    sys.exit(1)
print("ok   - with --include-omp the totals include OMP")
PY
CHECKS=$((CHECKS + 1))

# A period in which OMP did everything leaves nothing standing: zero totals, no
# cache tokens or ratio, no activities, with the exclusion still recorded. This
# is the ordinary day on an OMP-only desktop. The main read is taken a moment
# after the OMP-only one and OMP keeps working in between, so it carries slightly
# more cache tokens and activity than the OMP-only read does; none of that is
# anyone else's usage.
cat > "$TMP/main-all-omp.json" <<'JSON'
{"generated":"2026-09-20T17:00:00.000Z","currency":{"symbol":"$","code":"USD"},
 "current":{"label":"Today (2026-09-20)","cost":60.0,"calls":6,"sessions":2,
  "inputTokens":600000,"outputTokens":120000,"cacheReadTokens":3500000,"cacheWriteTokens":60000,
  "cacheHitPercent":83.33,"providers":{"omp":60.0},
  "providerDetails":[
    {"id":"omp","label":"OMP","cost":60.0,"calls":6,"sessions":2,"hasUsage":true,"inputTokens":600000,"outputTokens":120000}],
  "topModels":[{"name":"Opus 5","cost":55.0,"calls":5},{"name":"deepseek-flash","cost":5.0,"calls":1}],
  "topActivities":[{"name":"Coding","cost":52.0,"turns":6},{"name":"Exploration","cost":10.0,"turns":1}]}}
JSON
cat > "$TMP/bin/codeburn-all-omp" <<STUB
#!/bin/bash
case "\$1" in
  status)
    if [[ "\$*" == *"--provider omp"* ]]; then cat "$TMP/omp.json"
    else cat "$TMP/main-all-omp.json"; fi
    ;;
  models)
    echo '[]'
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/codeburn-all-omp"
OUT3="$(CODEBURN_BIN="$TMP/bin/codeburn-all-omp" ./bin/spend-status today 2>/dev/null)"
python3 - "$OUT3" <<'PY' || exit 1
import json, sys
status = json.loads(sys.argv[1])
current = status.get("current") or {}
def check(label, got, want):
    if got != want:
        print("FAIL - %s (expected %r, got %r)" % (label, want, got), file=sys.stderr)
        sys.exit(1)
    print("ok   - " + label)
check("a period of nothing but OMP leaves no totals",
      (current.get("cost"), current.get("calls"), current.get("sessions"),
       current.get("inputTokens"), current.get("outputTokens")), (0, 0, 0, 0, 0))
check("the between-reads growth is not reported as cache usage",
      (current.get("cacheReadTokens"), current.get("cacheWriteTokens"),
       current.get("cacheHitPercent")), (0, 0, 0.0))
check("nor as activity", current.get("topActivities"), [])
check("the exclusion is still recorded",
      status.get("ompExcludedTotals"), {"cost": 60.0, "calls": 6, "sessions": 2})
PY
CHECKS=$((CHECKS + 1))

printf '%s checks passed\n' "$CHECKS"
