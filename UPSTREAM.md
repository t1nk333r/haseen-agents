# UPSTREAM — `t1nk33r.agents`

One bar widget and one tabbed panel over five surfaces — the subscription-limit
fork this plugin has always been, the spend, fleet and DeepSeek plugins it
absorbed in plan 128, and an OpenRouter tab that borrows from a third-party
plugin that was never installed here.

- **plugin id**: `t1nk33r.agents`
- **plugin version**: `3.0.0`
- **declared `omarchy.clonedFrom`**: `omarchy.agents` — kept. It names an installed packaged plugin (the stock Agents widget), so plan 119's rule allows it, and disabling this plugin hands the bar slot back to the stock widget rather than leaving a hole. **Consequence to know**: that handover restores only the subscription-limits surface; spend, fleet and DeepSeek leave the bar with it until it is re-enabled. Dropping the key is a one-line follow-up if an empty slot is preferred.
- **repository**: https://github.com/t1nk333r/haseen-agents
- **publication baseline**: `dfe6166`, with the merged panel source from `08dc960` and the OpenRouter source from `0cc20c7`. Only plugin source files are imported; no runtime configuration or credentials are included.

## The five parents

| surface | parent | upstream | licence |
|---|---|---|---|
| Limits | `t1nk33r.agents` (plan 090 fold-in) | the first-party `omarchy.agents` package, via the owner's clone | MIT |
| Spend | `t1nk33r.codeburn` | https://github.com/erzz/omarchy-codeburn @ `47d56a2` (`status.sh`, `status-enrich.py`, the panel) | MIT © erzz |
| Fleet | `t1nk33r.fleet-shepherd` | https://github.com/joshuaswarren/omarchy-fleet-shepherd (`bin/fleet-snapshot`, `bin/fleet-focus`, `Model.js`) | MIT © Joshua Warren |
| DeepSeek | `t1nk33r.deepseek` | two: https://github.com/Shirak-Semonian/deepspend-omarchy-plugin @ `e910ded` (balance fetch, panel, low-balance alert) and https://github.com/CaffeinatedTech/qs-plugin-deepseek-pricing @ `dcc6564` (`Pricing.js`, the whale marks, the peak/off-peak schedule) | MIT © Shirak Semonian; MIT © CaffeinatedTech |
| OpenRouter | none — written into this plugin, never installed as a plugin of its own | upstream plugin id `io.github.spoilheap.openrouter` (SpoilHeap's `Omarchy.OpenRouter`, v1.0.0): https://github.com/SpoilHeap/Omarchy.OpenRouter @ `b443c4268c1946beefca480a6f9fc141620c5dcf` (`credits.sh`, `save-key.sh`, `Model.js`, `Service.qml`, `Panel.qml`), read as untrusted input and rewritten, not copied | MIT © 2026 SpoilHeap |

The three merged parents — `t1nk33r.codeburn`, `t1nk33r.fleet-shepherd`,
`t1nk33r.deepseek` — were **removed** after the merge: their directories, their
`~/.gitignore` negations and their plugin state are gone, nothing is left in
`shell.json`, and no backup was kept under
`~/.local/state/omarchy/plugin-backups/`. This plugin is the only surface they
have left. Limits is not in that list: it is this plugin's own lineage.

- **upstream watching**: the codeburn and deepseek parents are no longer
  installed, so the clone directories their rows in
  `~/.config/claudes-eyes/forks.tsv` point at no longer exist. The four
  upstreams are also recorded here, which is what
  `tools/plugin-upstream-report.sh` reads; it has no per-id row for this plugin,
  so a move in a parent repo is not flagged automatically.
- **config compatibility**: `~/.config/deepspend/config.json` (the DeepSeek API
  key) and `~/.config/fleet-shepherd/connectors.json` are read unchanged, and
  `codeburn` is still the host's own npm tool. Nothing external moved.
- **the one path that moved**: the DeepSeek usage ledger and alert state —
  `~/.local/state/t1nk33r.deepseek/{usage.state,alerts.state,alerts.gate}` →
  `~/.local/state/haseen/agents/deepseek/`. The ledger is measured
  history (its first sample is 2026-09-11) and had to be carried, not
  recreated. `Pricing.js` also moved, and
  `~/.local/bin/omp-peak-guard` was re-pointed at this plugin's copy (it
  `node -e require()`s that file on every `omp` launch and once a minute).

## OpenRouter: borrowed and changed

Borrowed from SpoilHeap/Omarchy.OpenRouter @ `b443c42`:

- the endpoint logic — `/credits` for the account ledger, `/key` for any key's
  cap and usage, `/activity` for the week/month sums — and the source ladder
  (account → key cap → spend only);
- the key-save approach — the panel pipes the key to a save helper over stdin,
  which writes `~/.config/haseen/agents/openrouter/key` mode 600;
- `Model.js`'s `known`, `money`, `compactMoney`, `sourceMeta`,
  `balanceDetail`, `capDetail`, `relativeAge` and the skip-unreported-window
  rule (in `OpenRouterModel.js`);
- the today-baseline idea (spend today = total usage now − total usage at the
  first poll of the UTC day).

Deliberately changed:

- **no `keyCommand`** setting, nor any setting that runs a command;
- a **key allowlist** (`^[A-Za-z0-9._~+/=-]{16,256}$`) in both helpers and the
  panel, so a quote, backslash or newline can never reach curl's config (the
  reference built that config with `printf` from the key);
- the `OPENROUTER_API_BASE` override is honoured **only for a loopback URL**
  (a test hook), and curl is pinned to `https`, no redirects, size and time caps;
- state lives under `~/.local/state/haseen/agents/openrouter/`
  (dir 700, file 600, atomic write), not beside the plugin;
- spend rows fall back per window to **the key's own** daily/weekly/monthly
  usage, tagged `this key`, when the account ledger is unavailable;
- the today baseline is **guarded by the key label**, so switching accounts
  mid-day starts a new baseline instead of reporting a nonsense delta;
- "no key" is only the helper's explicit `noKey` answer; any other failure
  (including one that cannot name a key source) is a failure that lights the
  mark; a saved key resets the view so the previous key's figures never show
  under the new one (`Saved — checking…`); the management-key advice needs an
  actual 403 (`needsManagementKey`);
- a failed check keeps the **last good snapshot**, marked STALE, instead of
  blanking the panel; the service has a watchdog and never overlaps runs;
- the key field never takes focus on its own (no keyboard trap on the no-key
  form); a failed check leads with Replace API key; `Left on key cap` replaces
  `Key spend cap`; the model strips the full Unicode format (Cf) table from any text;
- the panel is a tab of this plugin (rail + pane, the shared hero and key
  catcher), not its own bar widget and IPC target.

## The fork's own changes (yadm history for this path, newest first)

- plan 128: the four surfaces merged into one bar widget and one two-column
  tabbed panel; the panel rewritten on the kit's `KeyboardPanel` with a shared
  hero, a tab strip and a rail + pane per tab.
- plan 090 (2026-09-01): the previous agents fold-in (later backed out).

## Patch records

- See `plans/001-openrouter-limits-balance.md` for the publication and balance-row fix.
