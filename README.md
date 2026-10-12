# Agents

A [haseen](https://github.com/t1nk333r/haseen) plugin with one bar icon and
a panel for subscription limits, spend, the connector fleet, DeepSeek and
OpenRouter. It also runs on Omarchy.

## Install

```bash
haseen plugin install https://github.com/t1nk333r/haseen-agents
```

## Panel

```
┌──────────────────────────────────────────────────────────────────────┐
│ 󱚣 5     the bar mark: one glyph, one badge (barBadge setting)        │
├──────────────────────────────────────────────────────────────────────┤
│ hero      icon · title · meta · detail pill            [refresh]      │  shared
│ tabs      1 Limits · 2 Spend · 3 Fleet · 4 DeepSeek · 5 OpenRouter    │  shared
├────────────────────┬─────────────────────────────────────────────────┤
│ LEFT RAIL          │ RIGHT PANE                                      │
│ what, and which    │ the data — the only part that scrolls           │
├────────────────────┴─────────────────────────────────────────────────┤
│ legend  1-5 tab · [ ] cycle · j/k rail · Ctrl+j/k scroll · r refresh  │  shared
└──────────────────────────────────────────────────────────────────────┘
```

The left rail holds what is bounded and selectable (a provider, a period, a
sub-view, an account, a clock); the right pane holds what grows with data
(meters, day rows, connector rows, activity rows, recovery forms). That split
is the same on every tab, so the hero, the tab strip and the rail's edge never
move when the tab changes — and a slow `npx codeburn` run can never stall the
other four surfaces, because each one has its own always-running service.

## The five surfaces

| tab | left rail | right pane | data path (unchanged) |
|---|---|---|---|
| **Limits** | provider chips, the provider's own status/auth note, its binding window (or, for a prepaid provider, its credit balance), sync state | `LIMITS` meters (a row per window, with reset countdown and pace), `TOKENS BY DAY`, `TOKENS BY MODEL` | `~/.local/state/haseen/agents/usage/*.json`, written by the packaged updater through `bin/agents-update` |
| **Spend** | period chips (Today · 7 Days · 30 Days · Month · 6 Months · Lifetime), that period's Cost / Calls / Sessions / Cache hit, token totals, "updated …" | `PROVIDERS`, `TOP MODELS` (cost + tokens + bar), `TOP ACTIVITIES` — a "No spend in this period" card when there is nothing to list — or the error card when `codeburn` cannot be reached | `bin/spend-status` → the host's `codeburn` CLI (or `npx codeburn@0.9.24`) → `bin/spend-status-enrich.py`; the tab passes `--include-omp` (OMP counts at API rates) unless `spendExcludeOmp` is on |
| **Fleet** | sub-view chips (**Agents** · Attention · Usage · Overview — Agents is the view the tab opens on, since it is the only one that lists every agent per connector untruncated; Overview is the summary shape, kept last) | the connector list: health dot, per-connector usage, agent rows and per-model rows (Usage view) | `bin/fleet-snapshot --cache-ttl N [--stale-ok\|--refresh]`; connectors from `~/.config/fleet-shepherd/connectors.json` |
| **DeepSeek** | balance headline, granted / topped up / currency / API calls / last checked, and the pricing clock with the peak windows and alert threshold | measured usage (Daily / Total `since …` / Added today) and the action buttons — or the no-key / broken-config recovery flow | `~/.config/deepspend/config.json` for the key, curl for `api.deepseek.com/user/balance`, `Pricing.js` for the schedule |
| **OpenRouter** | the balance headline and its meter (remaining against today's starting balance, else against credit purchased, or against the key's cap), purchased / spent and cap lines, key label, key type, where the key came from, updated (or `last good`) age | the failure card first when a check failed (error, hint, and `Replace API key` — or `Enter API key` when the helper could not name a key source), the low-balance note, `SPEND` (today · this week · this month · all time; the scope is said once in the header — `SPEND · ACCOUNT` / `SPEND · THIS KEY` — and only rows that mix scopes are tagged `account` / `this key`), the key-cap card, the management-key note, the key form, and the actions (Add credits on OpenRouter · Open activity on OpenRouter · Replace API key · Create a management key; the first two are hidden while the key is rejected). There is deliberately no Refresh button: the hero's refresh icon and `r` cover it | `bin/openrouter-credits` → `openrouter.ai/api/v1` `/credits`, `/key`, `/activity` (curl, key on stdin config only); today's baseline in `~/.local/state/haseen/agents/openrouter/today-spend.json` |

The DeepSeek ledger, one row per local day, lives at
`~/.local/state/haseen/agents/deepseek/`. The API key file keeps its
old path, so the existing key keeps working.

The Limits rail shows OpenRouter's balance from the same service as its tab.
Key caps are labelled, retained readings are marked stale, and a failed check
with no balance shows offline. Hover for the failure reason. Press `r` to
refresh both provider balances.

The OpenRouter key is read, first hit wins, from `$OPENROUTER_API_KEY`,
`$OPENROUTER_KEY`, `~/.config/haseen/agents/openrouter/key`, then
`~/.config/openrouter/key` (`$XDG_CONFIG_HOME` moves both files). The tab's
key field writes the third (mode 600, directory 700) through
`bin/openrouter-save-key`, which receives the key on stdin — never argv, never
the environment — so a key saved there is ignored while either environment
variable is set, and the tab says so. Only keys matching
`[A-Za-z0-9._~+/=-]{16,256}` are accepted, and no setting runs a command to
fetch a key. If your home directory is a version-controlled work tree (yadm),
ignore `.config/haseen/agents/openrouter/`: the file is named `key`, which a `*.key`
rule does not match. Use a **management key**
(`openrouter.ai/settings/management-keys`): it is free, it is the only kind
that can read the account balance (`/credits`) and the daily ledger
(`/activity`), and it cannot run chat requests. An inference key still works,
but shows only its own cap and spend (`Left on key cap` / `Spend only`). Today's
account-wide spend is measured against a baseline taken at the first poll of
the UTC day; when that was later than 00:30 UTC the caption names the time
(`Today counts from 00:51 UTC (the panel's first check); earlier spend today
is not included.`). The meter's percentage is floored, so 100% means untouched;
a low or stale balance is drawn in the dim warn colour everywhere. A failed
check keeps the last good figures on screen, marked STALE; with nothing to
keep it is OFFLINE, with the helper's error, its hint and a way to a key. NO
KEY appears only when the helper says explicitly that no key exists in any
source (`noKey`); a helper that could not even report where a key comes from
is a failure, not "no key", and lights the mark like any other failure. After
a key is saved the tab drops every figure of the previous key (same file,
different key) and shows `Saved — checking…` until the new key answers. The
management-key advice appears only when `/credits` answered 403
(`needsManagementKey`); any other reason the ledger is missing is shown as
`Account balance unavailable: …`. The helper never copies server text into its
output: messages come from a fixed vocabulary keyed on the HTTP status,
`keyLimitReset` is one of `daily`/`weekly`/`monthly`, and the key label is
computed locally (`sk-or-v1-...` plus the key's last 4 characters; the
server's own label is ignored), so an echoed or re-encoded key cannot reach
the panel or the baseline file as text; `OpenRouterModel.js` still strips
control and invisible format characters and caps text at 200 characters as a
second line. The helper runs as `bash -p`
under `LC_ALL=C`, unsets every key variable before any child process starts,
and gives the loopback test base `noproxy`; a key supplied through the
environment is still visible in the launching process's own environment, so
the key file is the recommended source.

### Trust boundaries (OpenRouter)

What the OpenRouter part does **not** defend against, as the helpers' headers
state it:

- the launch environment (PATH, proxy variables, the CA bundle, `CURL_*`) is
  trusted for the real HTTPS endpoint; a malicious tool on PATH or an
  interception CA can see the key;
- the key and state directories must have owner-controlled ancestors;
  the save refuses a symlinked key directory or key path and the baseline is
  skipped for a symlinked state path, but reading a key file that is itself a
  symlink is accepted (the owner's choice), and a path swap by something that
  already controls an ancestor is out of scope;
- another process running as the same user can read the key file, an
  environment-supplied key in `/proc/<pid>/environ` (of the helper and of the
  panel that launched it), and the stdin pipe while curl reads it;
- the key is not erased from process memory or core dumps;
- the today baseline's key identity is that local label (public prefix plus the
  last 4 characters): a heuristic for a key switch, not proof of account
  identity; a hand-edited key file changes it and resets the baseline, but the
  displayed figures are only dropped by a save from the panel;
- server-chosen numbers: the API server already holds the key by design, and a
  hostile server can place any number in a balance field, including digits
  copied from the key; nothing here defends against that. What is defended is
  that the helper never writes the key to argv, the environment, stderr,
  scratch files or state, never copies server text into its output, and shows
  the key only as the local label above;
- the tests run against a loopback fixture only; the live happy path needs a
  real management key.

OpenRouter files: `OpenRouterService.qml` (the poll, the watchdog, the stdin
save), `OpenRouterTab.qml` (the tab), `OpenRouterModel.js` (pure logic),
`bin/openrouter-credits` (the fetch) and `bin/openrouter-save-key` (the save).

The Spend tab counts OMP: it is an overview of what the usage would have cost at
API rates, and oh-my-pi's share is most of it (a subscription harness's API-rate
cost is a would-be figure, not money out of pocket). It asks `bin/spend-status
<period> --include-omp` for that; the helper's own default — no argument — leaves
OMP out, because other callers rely on it (the onefile spend producer refuses a
result that still counts OMP), and then reads `codeburn status --provider omp`
first — only when `~/.omp/agent/sessions` exists (`CODEBURN_OMP_SESSIONS_DIR`
moves that check) — and `spend-status-enrich.py` takes it off the totals, cache
tokens, activities and provider rows and rebuilds `TOP MODELS` from `codeburn
models --format json` without it. Set `spendExcludeOmp` to make the tab do that
too; its footer then reads `OMP excluded`. A period with nothing left to show
gets a "No spend in this period" card in place of a column of `$0.00` rows. OMP's
own limits (Limits) and connector usage (Fleet) are untouched either way.

The **Oh My Pi** provider shows OMP's usage across providers. **Claude (OMP)**
shows only Anthropic usage from the same OMP installation, not Claude Code.
Each Claude account keeps separate 5-hour, weekly and model-specific allowance
meters, including its own percentage and reset time. These two views overlap;
their historical totals must not be added together.

Claude's day/model tokens and provider-attributed prompt/session totals combine
all OMP Claude accounts. OMP does not record the credential for historical
requests, so those totals cannot be split by account; prompts without a provider
attribution are excluded from the Claude-only view. Full refreshes synchronise
OMP's statistics database, then read provider-filtered aggregates. Limits-only
refreshes retain those statistics and never carry Claude Code's old record.
Synced Claude history requires the native `omp:anthropic` source marker. Old
Claude Code snapshots and aggregates are excluded; other devices must update
this plugin and publish a new native snapshot before contributing Claude totals.

## Keys

| key | action |
|---|---|
| `1` `2` `3` `4` `5` | Limits · Spend · Fleet · DeepSeek · OpenRouter |
| `[` `]` | previous / next tab |
| `j` `k` / `↑` `↓` | move the left rail's chips (DeepSeek's and OpenRouter's rails have none, so j/k scroll the pane there) |
| `Ctrl+j` `Ctrl+k`, `PgDn` `PgUp`, `h` `l` / `←` `→` | move the right pane — scroll it, or move the Fleet connector cursor |
| `Enter` / `Space` | the active tab's action: refresh (Limits/Spend/DeepSeek/OpenRouter — on OpenRouter: focus the key field when the form is up, open the key form after a failed check), focus the connector under the cursor (Fleet) |
| `r` `R` `Ctrl+r` | refresh the active tab |
| `/` | Fleet tab: start the filter; any other printable on the Fleet tab starts it with that character |
| `Esc` | Fleet tab with a filter: clear it; OpenRouter key field: cancel the edit (the first-run form just hands the keys back); otherwise close the panel |
| `Tab` / `Shift+Tab` | the shell's popout switch |

While the OpenRouter key field has focus every keystroke belongs to it (paste
works; `Enter` or the check icon saves; `Tab` is swallowed so focus cannot
wander off; the legend reads `Enter save · Esc cancel`). The field never takes
the keys on its own: landing on the OpenRouter tab, even with the no-key form
up, leaves every panel key working, and the field is entered with `Enter`, a
click, or the Replace / Enter-API-key buttons.

Clicks on the mark: **left** toggles the panel; every normal opening selects
`defaultTab` and `defaultProvider` (**Limits → Oh My Pi** by default).
**Right** refreshes all five services. **Middle** opens the next tab, stepping
from the current tab while open or from the default while closed. Explicit IPC
tab requests override the opening default; manual rail choices persist until
the panel closes.

The rail is vertical, so `j`/`k` drive it and the pane keeps `Ctrl+j`/`Ctrl+k`
(plus `h`/`l` and `PgUp`/`PgDn`). This replaces the key map the four parents
had: fleet's `1`–`4` view keys and codeburn's `1`–`6` period keys are now the
tab strip, and their old meanings moved to the rail chips.

## IPC

One handler, `t1nk33r.agents`:

```
omarchy-shell t1nk33r.agents open|close|show|hide|toggle
omarchy-shell t1nk33r.agents refresh          # all five services
omarchy-shell t1nk33r.agents next             # next tab
omarchy-shell t1nk33r.agents tab limits|spend|fleet|deepseek|openrouter
omarchy-shell t1nk33r.agents setPeriod today|week|30days|month|all|lifetime
```

`tab` answers `ok` or `unknown tab`. The parents' `nextPeriod`/`prevPeriod`
methods are gone with their plugins — `setPeriod` replaces them.

## Settings

Read through `Panel.setting()` from this plugin's `shell.json` entry; the names
and defaults are declared in `manifest.json`.

| key | default | what it does |
|---|---|---|
| `barBadge` | `fleet` | the figure beside the glyph: `fleet` (working count, `!N` when N connectors are blocked, `—` when the fleet is unavailable), `deepseek` (balance, `!` on failure), `openrouter` (balance, `!` on failure with nothing to show, `—` when unknown), `spend` (current-period cost), `none` |
| `defaultTab` | `limits` | the tab every normal opening lands on |
| `defaultProvider` | `omp` | the Limits provider every opening selects; late data does not override a manual choice |
| `refreshIntervalSec` | 300 | Limits poll interval |
| `providers` | claude, codex, fireworks enabled | which collectors may run |
| `syncMode` / `syncDir` / `syncFileName` / `syncDeviceId` | `Off` / empty | the Limits tab's optional cross-device aggregation |
| `spendRefreshIntervalSec` | 300 | Spend poll interval |
| `spendExcludeOmp` | `false` | Spend counts OMP's usage at API rates (what it would have cost); on leaves it out of the totals instead |
| `fleetRefreshIntervalSec` / `fleetCacheTtl` / `fleetMaxAgentRows` | 30 / 120 / 3 | fleet poll interval, helper cache lifetime, agent rows per connector in Overview |
| `deepseekTokenModel` | `deepseek-flash` | the rate table used for the token estimate |
| `openrouterRefreshIntervalSec` | 300 | OpenRouter poll interval (60–21600) |
| `openrouterLowBalance` | 5 | OpenRouter credits at or below which the mark turns urgent |

The mark turns urgent when any tab alarms: a limit window at ≥ 90 %, a prepaid
balance in its last 10 %, a blocked connector, or a DeepSeek or OpenRouter balance
that is low or whose last check failed (for OpenRouter: any failure except the
explicit no-key state).
It never dims and never collapses — it is the only way into all five surfaces.

## Tests

```
bash tests/run.sh
```

- `tests/agents/omp-collector.test.sh` — the OMP collector contract (from the Limits parent)
- `tests/fleet/model.test.mjs` — snapshot normalisation, merge and filtering
- `tests/panel-contract.test.mjs` — this plugin's source rules: ids, the kit contract, theme tokens, glyphs, keys, the fleet helper's argv and security posture, the DeepSeek state path, the settings keys (declared in the manifest and read by the code)
- `tests/fleet/test_snapshot.py`, `tests/fleet/test_streams.py` — the helper's parser, isolation and documented claims (unittest)
- `tests/deepseek/model.test.js`, `tests/deepseek/pricing.test.js`, `tests/deepseek/usage.test.js` — the DeepSeek model, the pricing schedule (which `~/.local/bin/omp-peak-guard` also requires) and the usage ledger
- `tests/openrouter/model.test.js` — the OpenRouter model: unknown vs zero, negative balances, money/age rounding edges, the spend-row scope fallback and header scope, the late-baseline caption, the no-key/stale/offline rules, the reset after a save, recovery priority, low balance, attention, the bar label and the full Unicode format-character table
- `tests/openrouter/credits.test.mjs`, `tests/openrouter/save-key.test.mjs` — the two OpenRouter helpers against a loopback fixture server: the request flow, the JSON contract, the key allowlist, the key never in argv or env and never in the output beyond its own mask, no server text in the output, file modes and the today baseline
- `tests/spend/auto-price.test.sh` — the unpriced-model pass: a model the DeepSeek table can place is priced by override, a model it cannot is left reported
- `tests/spend/omp-exclusion.test.sh` — the helper's default leaves OMP out (read order, net totals, provider and model rows, the `ompExcluded` / `ompExcludedTotals` fields, the no-OMP no-op, a period of nothing but OMP); with `--include-omp` there is no OMP read and the totals include it

## Upstreams

See `UPSTREAM.md`: this plugin's own clone, the third-party parents it
absorbed and the OpenRouter reference it borrows from, with the deliberate divergences a future rebase would have to carry.
The three merged parents were removed, not disabled: their directories, their
plugin state and their `shell.json` entries are gone, so this plugin is the
only surface any of them has left.
