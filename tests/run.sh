#!/bin/bash
# Everything the merged plugin can be checked for without a compositor: each
# absorbed plugin's own suite where it lives now, plus the merged panel contract.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
bash tests/agents/omp-collector.test.sh
bash tests/agents/migrate.test.sh
node --test tests/fleet/model.test.mjs tests/agents/usage-sync.test.mjs tests/panel-contract.test.mjs
python3 -m unittest discover -s tests/fleet -p 'test_*.py'
node tests/deepseek/model.test.js
node tests/deepseek/pricing.test.js
node tests/deepseek/usage.test.js
node tests/openrouter/model.test.js
node --test tests/openrouter/credits.test.mjs tests/openrouter/save-key.test.mjs tests/limits-balances.test.mjs
bash tests/spend/auto-price.test.sh
bash tests/spend/omp-exclusion.test.sh
# qmllint, with the missing-import warning made fatal. The kit's own "not found"
# noise for qs.Ui types is expected and not matched; a file that does not exist
# is, and it has to be: a script that fails to load silently takes the whole
# panel component with it (empty bar slot, no IPC target).
for f in *.qml; do
  # `|| true`: grep exits 1 when it finds nothing and this script runs under set -e.
  errors=$(/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell "$f" 2>&1 \
    | grep -E '^Error:|\[syntax\]|does not exist:' || true)
  if [[ -n $errors ]]; then
    printf 'qmllint %s\n%s\n' "$f" "$errors" >&2
    exit 1
  fi
done
printf 'qmllint clean\n'
