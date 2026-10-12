#!/bin/bash
# Tests for bin/agents-migrate, the one-time copy of this plugin's files from
# their Omarchy-era homes to haseen's, and for the entry points that run it.
#
#   bash tests/agents/migrate.test.sh

set -u

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
migrate="$plugin_dir/bin/agents-migrate"
wrapper="$plugin_dir/bin/agents-update"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

FAILS=0
CHECKS=0
check() { # check <label> <command...>
  CHECKS=$((CHECKS + 1))
  if "${@:2}"; then printf 'ok   - %s\n' "$1"; else printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); fi
}
same() { cmp -s -- "$1" "$2"; }
mode_is() { [[ $(stat -c %a -- "$2") == "$1" ]]; }
absent() { [[ ! -e $1 ]]; }

sandbox() {
  root="$work/$1"
  export HOME="$root/home" XDG_CONFIG_HOME="$root/config" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache"
  mkdir -p "$HOME"
  old_key="$XDG_CONFIG_HOME/omarchy/openrouter/key"
  old_usage="$XDG_STATE_HOME/omarchy/agents/usage"
  old_ds="$XDG_STATE_HOME/omarchy/t1nk33r.agents/deepseek"
  old_or="$XDG_STATE_HOME/omarchy/t1nk33r.agents/openrouter"
  old_cache="$XDG_CACHE_HOME/omarchy/agent-usage"
  new_key="$XDG_CONFIG_HOME/haseen/agents/openrouter/key"
  new_usage="$XDG_STATE_HOME/haseen/agents/usage"
  new_ds="$XDG_STATE_HOME/haseen/agents/deepseek"
  new_or="$XDG_STATE_HOME/haseen/agents/openrouter"
  new_cache="$XDG_CACHE_HOME/haseen/agents/agent-usage"
}

plant_old() {
  mkdir -p "${old_key%/*}" "$old_usage" "$old_ds" "$old_or" "$old_cache"
  printf '# key\nsk-or-v1-0123456789abcdef\n' > "$old_key"
  chmod 600 "$old_key"
  printf '{"id":"omp"}\n' > "$old_usage/omp.json"
  printf '{"id":"codex"}\n' > "$old_usage/codex.json"
  printf 'ledger\n' > "$old_ds/usage.state"
  printf 'zone\n' > "$old_ds/alerts.state"
  printf 'gate\n' > "$old_ds/alerts.gate"
  printf '{"date":"2026-10-08"}\n' > "$old_or/today-spend.json"
  printf '{}\n' > "$old_cache/omp-limits-all.json"
  printf '{}\n' > "$old_cache/pi-version.json"
  printf '{}\n' > "$old_cache/claude-scan-1.json"
  printf '{}\n' > "$XDG_CACHE_HOME/omarchy/agents-disabled.json"
}

# ---------------------------------------------------------------------------
sandbox a
plant_old
out=$("$migrate" 2>&1); rc=$?
check "exits 0, silent" [ "$rc" -eq 0 -a -z "$out" ]
check "key copied, byte for byte" same "$old_key" "$new_key"
check "key mode 600" mode_is 600 "$new_key"
check "key dir mode 700" mode_is 700 "${new_key%/*}"
check "agents config dir mode 700" mode_is 700 "$XDG_CONFIG_HOME/haseen/agents"
for f in omp.json codex.json; do check "usage $f copied" same "$old_usage/$f" "$new_usage/$f"; done
check "usage record mode 600" mode_is 600 "$new_usage/omp.json"
check "usage dir mode 700" mode_is 700 "$new_usage"
for f in usage.state alerts.state alerts.gate; do check "deepseek $f copied" same "$old_ds/$f" "$new_ds/$f"; done
check "openrouter baseline copied" same "$old_or/today-spend.json" "$new_or/today-spend.json"
check "omp cache copied" same "$old_cache/omp-limits-all.json" "$new_cache/omp-limits-all.json"
check "pi cache copied" same "$old_cache/pi-version.json" "$new_cache/pi-version.json"
check "packaged collector cache left alone" absent "$new_cache/claude-scan-1.json"
check "disabled snapshot copied" same "$XDG_CACHE_HOME/omarchy/agents-disabled.json" "$XDG_CACHE_HOME/haseen/agents/agents-disabled.json"
check "old key kept" [ -f "$old_key" ]
check "old ledger kept" [ -f "$old_ds/usage.state" ]
check "no temp file left" [ -z "$(find "$XDG_STATE_HOME/haseen" "$XDG_CONFIG_HOME/haseen" "$XDG_CACHE_HOME/haseen" -name '.migrate.??????')" ]
check "stamp written" [ -e "$XDG_STATE_HOME/haseen/agents/.migrated-from-omarchy" ]

# Once stamped, a record a collector dropped stays dropped.
rm "$new_usage/codex.json"
"$migrate"
check "after the stamp nothing is copied again" absent "$new_usage/codex.json"

# ---------------------------------------------------------------------------
sandbox b
plant_old
mkdir -p "${new_key%/*}" "$new_ds"
printf 'newer\n' > "$new_key"
printf 'newer ledger\n' > "$new_ds/usage.state"
"$migrate"
check "an existing key is never overwritten" [ "$(cat "$new_key")" = newer ]
check "an existing ledger is never overwritten" [ "$(cat "$new_ds/usage.state")" = "newer ledger" ]
check "the missing files still arrive" same "$old_ds/alerts.state" "$new_ds/alerts.state"

# ---------------------------------------------------------------------------
sandbox c
plant_old
ln -s "$old_key" "$root/elsewhere-key"
rm "$old_ds/alerts.gate"
ln -s "$root/elsewhere-key" "$old_ds/alerts.gate"
"$migrate"
check "a symlinked old file is not followed" absent "$new_ds/alerts.gate"

# ---------------------------------------------------------------------------
sandbox d
plant_old
out=$(cd "$work" && HOME=relative XDG_CONFIG_HOME='' XDG_STATE_HOME='' XDG_CACHE_HOME='' "$migrate" 2>&1); rc=$?
check "no absolute base: exits 0, silent" [ "$rc" -eq 0 -a -z "$out" ]
check "no absolute base: nothing created" absent "$work/relative"

# ---------------------------------------------------------------------------
sandbox e
plant_old
OMARCHY_PATH="$work/nothing" PATH="$work/no-cli:/usr/bin:/bin" "$wrapper" >/dev/null 2>&1
check "agents-update migrates before it collects" same "$old_usage/codex.json" "$new_usage/codex.json"
check "agents-update leaves no scratch directory" [ -z "$(find "$XDG_STATE_HOME/haseen/agents" -maxdepth 1 -name '.packaged.*')" ]

# ---------------------------------------------------------------------------
sandbox f
mkdir -p "$work/pkg/bin"
cat > "$work/pkg/bin/omarchy-agent-usage-update" <<'PKG'
#!/bin/bash
dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage"
mkdir -p "$dir" && printf '{"id":"codex"}\n' > "$dir/codex.json"
PKG
chmod +x "$work/pkg/bin/omarchy-agent-usage-update"
OMARCHY_PATH="$work/pkg" PATH="$work/no-cli:/usr/bin:/bin" "$wrapper" >/dev/null 2>&1
check "the packaged updater's record lands in the haseen usage dir" [ -f "$new_usage/codex.json" ]
check "nothing is written to the Omarchy usage dir" absent "$old_usage"
check "the scratch directory is gone" [ -z "$(find "$XDG_STATE_HOME/haseen/agents" -maxdepth 1 -name '.packaged.*')" ]

printf '%d checks, %d failed\n' "$CHECKS" "$FAILS"
(( FAILS == 0 ))
