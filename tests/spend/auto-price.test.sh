#!/bin/bash
# bin/spend-status auto-pricing.
#
# CodeBurn prices what it knows. A DeepSeek model name it has never seen —
# `deepseek-v4.1-flash`, which is how OpenCode logs the current flash tier —
# arrives with usage and no rate, and the period's money is quietly short by
# everything that model moved (108.6M tokens in the case that prompted this;
# the panel read $9.10 for a day that had cost $13.51).
#
# The panel's own seam is the place that can notice, because it is the only
# thing that reads CodeBurn's `unpricedModels` on every poll, and the plugin
# already carries the published DeepSeek table (DeepSeekModel.js TOKEN_MODELS,
# from api-docs.deepseek.com/pricing). So the helper prices what the table can
# place, and only that.
#
# Contract pinned here, against a stubbed codeburn (no network, no real usage):
#   1. an unpriced model whose family and tier match a table entry is priced
#      from that entry, by price-override, at the published peak rates;
#   2. a model the table cannot place is left alone and stays reported — a
#      price is never invented;
#   3. the poll that notices the gap is also the poll that ends up showing the
#      money it filled in (exactly one extra read, never a loop);
#   4. the JSON records what was priced, so the correction is visible rather
#      than silent.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

CHECKS=0
ok() { printf 'ok   - %s\n' "$1"; CHECKS=$((CHECKS + 1)); }
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1 (expected [$3], got [$2])"; fi }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/calls"

# The stub stands in for the CLI: it answers `status` and `models`, records
# every call, and — like the real tool — stops listing a model as unpriced once
# an override for it exists, which is what makes the extra read observable.
cat > "$TMP/bin/codeburn" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1" in
  status)
    if [[ -f $STUB_PRICED ]]; then
      printf '%s\n' '{"current": {"cost": 13.51, "calls": 2, "unpricedModels": [{"model": "mystery-model", "calls": 7, "tokens": 1000}]}}'
    else
      printf '%s\n' '{"current": {"cost": 9.10, "calls": 2, "unpricedModels": [{"model": "deepseek-v4.1-flash", "calls": 432, "tokens": 108616370}, {"model": "mystery-model", "calls": 7, "tokens": 1000}]}}'
    fi
    ;;
  price-override)
    : > "$STUB_PRICED"
    printf 'Model pricing saved\n'
    ;;
  models)
    printf '%s\n' '[]'
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/codeburn"

# The helper pins the runner with CODEBURN_BIN: its own PATH export puts the
# real npm prefixes first, so a stub cannot win by PATH alone. The stable
# pointer is redirected too, so a test run cannot repoint the operator's real
# ~/.local/bin/codeburn at a stub that is about to be deleted.
export CODEBURN_BIN="$TMP/bin/codeburn"
export STUB_LOG="$TMP/calls/argv.log" STUB_PRICED="$TMP/calls/priced"
export CODEBURN_STABLE_LINK="$TMP/calls/stable-codeburn"
# No OMP sessions directory: the OMP pre-read is skipped, so the status-call
# count below stays about the pricing pass. OMP exclusion has its own test.
export CODEBURN_OMP_SESSIONS_DIR="$TMP/no-omp"
: > "$STUB_LOG"

OUT="$(./bin/spend-status today 2>"$TMP/stderr.log")"
ARGV="$(cat "$STUB_LOG")"

if grep -qF 'price-override deepseek-v4.1-flash --input 0.3 --output 1.2 --cache-read 0.006' <<<"$ARGV"; then
  ok "the unseen DeepSeek model is priced from TOKEN_MODELS"
else
  fail "expected a price-override for deepseek-v4.1-flash at the published rates, got: $ARGV"
fi

if grep -qF 'price-override mystery-model' <<<"$ARGV"; then
  fail "a model the table cannot place was priced anyway"
else
  ok "a model the table cannot place is left unpriced"
fi

expect "the status is read once more after pricing" \
  "$(grep -c '^status ' <<<"$ARGV" || true)" "2"

python3 - "$OUT" <<'PY' || exit 1
import json, sys
status = json.loads(sys.argv[1])
cost = float((status.get("current") or {}).get("cost") or 0)
if round(cost, 2) != 13.51:
    print("FAIL - the panel is handed the priced status (cost %.2f)" % cost, file=sys.stderr)
    sys.exit(1)
priced = status.get("autoPriced") or []
if not priced or priced[0].get("model") != "deepseek-v4.1-flash" or priced[0].get("from") != "deepseek-flash":
    print("FAIL - autoPriced records what was filled in: %r" % priced, file=sys.stderr)
    sys.exit(1)
print("ok   - the panel gets the priced status, and a record of what was filled in")
PY
CHECKS=$((CHECKS + 1))

printf '%s checks passed\n' "$CHECKS"
