import QtQuick
import Quickshell
import Quickshell.Io

// Spend tab's data half: the period state and the `codeburn` status poll that
// used to live inside t1nk33r.codeburn's Panel.qml (plan 128). Everything the
// collector produces — the status JSON, status-enrich.py's model tokens and
// local-currency rate — is unchanged; only the shell around it is new, and it
// is a hidden always-running service so a slow `npx codeburn` run can never
// stall the Limits, Fleet or DeepSeek tabs.
//
// The host's own codeburn CLI (or `npx codeburn@0.9.24`) stays where it is:
// bin/spend-status is the same wrapper the standalone plugin shipped.
Item {
  id: root
  visible: false

  property var settings: ({})

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Derived from where Omarchy installs a plugin, so the helper is found
  // whatever the plugin directory is called.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    if (url.indexOf("localhost/") === 0) url = url.substring(9)
    try { url = decodeURIComponent(url) } catch (e) { }
    return url.replace(/\/+$/, "")
  }
  readonly property string statusCommand: root.pluginDir + "/bin/spend-status"
  readonly property int refreshIntervalSec: Math.max(60, Number(root.setting("spendRefreshIntervalSec", 300)) || 300)
  // OMP's usage is in the totals unless the owner asks for it to come off (the
  // spendExcludeOmp setting): this tab is an overview of what the usage would
  // have cost at API rates. bin/spend-status leaves OMP out by default, which is
  // its contract for its other callers, so this service asks for it with
  // --include-omp unless the setting is on.
  readonly property bool excludeOmp: root.setting("spendExcludeOmp", false) === true

  // --------------------------------------------------- reporting periods
  readonly property var periods: [
    { value: "today", label: "Today" },
    { value: "week", label: "7 Days" },
    { value: "30days", label: "30 Days" },
    { value: "month", label: "Month" },
    { value: "all", label: "6 Months" },
    { value: "lifetime", label: "Lifetime" }
  ]

  property string selectedPeriod: "today"

  function periodLabel(id) {
    for (var i = 0; i < root.periods.length; i++) {
      if (root.periods[i].value === id) return root.periods[i].label
    }
    return "Today"
  }

  readonly property string selectedPeriodLabel: root.periodLabel(root.selectedPeriod)

  function selectPeriod(periodId) {
    if (root.selectedPeriod === periodId) return
    root.selectedPeriod = periodId
    root.refresh()
  }

  function cyclePeriod(direction) {
    var currentIndex = 0
    for (var i = 0; i < root.periods.length; i++) {
      if (root.periods[i].value === root.selectedPeriod) {
        currentIndex = i
        break
      }
    }
    var nextIndex = (currentIndex + direction + root.periods.length) % root.periods.length
    root.selectPeriod(root.periods[nextIndex].value)
  }

  // -------------------------------------------------------------- state
  property var statusData: null
  property bool refreshing: false
  property bool hasError: false
  property string errorMessage: ""
  property double lastUpdatedMs: 0
  property double nowMs: Date.now()

  // --- Data accessors ---
  readonly property var current: root.statusData ? root.statusData.current : null
  readonly property real cost: root.current && root.current.cost !== undefined ? Number(root.current.cost) : 0
  readonly property int calls: root.current && root.current.calls !== undefined ? Number(root.current.calls) : 0
  readonly property int sessions: root.current && root.current.sessions !== undefined ? Number(root.current.sessions) : 0
  readonly property real inputTokens: root.current && root.current.inputTokens !== undefined ? Number(root.current.inputTokens) : 0
  readonly property real outputTokens: root.current && root.current.outputTokens !== undefined ? Number(root.current.outputTokens) : 0
  readonly property real cacheReadTokens: root.current && root.current.cacheReadTokens !== undefined ? Number(root.current.cacheReadTokens) : 0
  readonly property real cacheHitPercent: root.current && root.current.cacheHitPercent !== undefined ? Number(root.current.cacheHitPercent) : 0
  readonly property var topModels: root.current && Array.isArray(root.current.topModels) ? root.current.topModels : []
  // status-enrich.py's two additions: CodeBurn's own per-model token rows for
  // this period, and the local-currency rate the prices are also shown in.
  readonly property var modelTokens: root.statusData && Array.isArray(root.statusData.modelTokens) ? root.statusData.modelTokens : []
  readonly property var localCurrency: root.statusData && root.statusData.localCurrency ? root.statusData.localCurrency : null
  readonly property var providerDetails: root.current && Array.isArray(root.current.providerDetails) ? root.current.providerDetails : []
  readonly property var topActivities: root.current && Array.isArray(root.current.topActivities) ? root.current.topActivities : []
  // True when status-enrich.py took OMP's contribution off the payload (the
  // helper's default; the Spend tab asks for it only with spendExcludeOmp on,
  // see bin/spend-status). By default OMP stays in the totals; when it is out,
  // the footer says so.
  readonly property bool ompExcluded: !!(root.statusData && root.statusData.ompExcluded)
  // What status-enrich.py took off: OMP's own cost, calls and sessions for the
  // period. Null when nothing was excluded or the payload predates the field.
  readonly property var ompExcludedTotals: root.statusData && root.statusData.ompExcludedTotals
    ? root.statusData.ompExcludedTotals : null
  // A period with no spend left once OMP is out. The rail still shows its
  // zeros; the pane says why, with the excluded figure, instead of a column of
  // $0.00 rows that reads as a broken tab.
  // Only float dust counts as zero: a real bill under half a cent still reads as
  // <$0.01 (formatCost) and is not "no spend".
  readonly property bool periodEmpty: root.isOnline && root.cost < 1e-9
  readonly property var optimize: root.statusData && root.statusData.optimize ? root.statusData.optimize : null
  readonly property var currency: root.statusData && root.statusData.currency ? root.statusData.currency : ({ symbol: "$", code: "USD" })
  readonly property string currencySymbol: root.currency && root.currency.symbol ? String(root.currency.symbol) : "$"

  readonly property bool isOnline: !root.hasError && root.statusData !== null

  function formatCost(val) {
    var num = Number(val || 0)
    if (num === 0) return root.currencySymbol + "0.00"
    if (num < 0.01) return "<" + root.currencySymbol + "0.01"
    return root.currencySymbol + root.grouped(num.toFixed(2))
  }

  // The token counts come from CodeBurn's report for the same period, whose
  // model rows carry the same names the status rows do, so the join is exact.
  // A model with no row (the report ran a moment after the status, or its
  // export was skipped) simply shows no token count and keeps a cost bar.
  function tokenRowFor(name) {
    for (var i = 0; i < root.modelTokens.length; i++) {
      if (root.modelTokens[i].name === name) return root.modelTokens[i]
    }
    return null
  }

  readonly property real localRate: (root.localCurrency && String(root.localCurrency.code || "USD") !== "USD" && Number(root.localCurrency.rate) > 0)
    ? Number(root.localCurrency.rate) : 0
  readonly property var topModelRows: root.topModels.slice(0, 5)

  // The longest token count among the rows on screen, so the bars are read
  // against the busiest model rather than a total that dwarfs every one of them.
  function maxTokensIn(rows) {
    var max = 0
    for (var i = 0; i < rows.length; i++) {
      var row = root.tokenRowFor(rows[i].name)
      if (row && Number(row.totalTokens) > max) max = Number(row.totalTokens)
    }
    return max
  }

  readonly property real topModelMaxTokens: root.maxTokensIn(root.topModelRows)

  function grouped(fixed) {
    var parts = String(fixed).split(".")
    var whole = parts[0]
    var out = ""
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 === 0) out += ","
      out += whole.charAt(i)
    }
    return parts.length > 1 ? out + "." + parts[1] : out
  }

  // "$4,479.17" in USD, "SAR 16,796.87" in the operator's own currency -- the
  // conversion and its fixed rate come from status-enrich.py.
  function formatLocalCost(val) {
    if (root.localRate <= 0) return ""
    var symbol = root.localCurrency.symbol ? String(root.localCurrency.symbol) : String(root.localCurrency.code || "")
    return symbol + " " + root.grouped((Number(val || 0) * root.localRate).toFixed(2))
  }

  function formatTokens(n) {
    var num = Number(n || 0)
    if (num >= 1000000000) return (num / 1000000000).toFixed(1) + "B"
    if (num >= 1000000) return (num / 1000000).toFixed(1) + "M"
    if (num >= 1000) return (num / 1000).toFixed(1) + "k"
    return String(Math.round(num))
  }

  function formatNumber(n) {
    var num = Number(n || 0)
    return num.toLocaleString()
  }

  function timeAgo(ms) {
    if (!ms || ms <= 0) return ""
    var diffSec = Math.max(0, Math.floor((root.nowMs - ms) / 1000))
    if (diffSec < 10) return "just now"
    if (diffSec < 60) return diffSec + "s ago"
    var diffMin = Math.floor(diffSec / 60)
    if (diffMin < 60) return diffMin + "m ago"
    var diffHr = Math.floor(diffMin / 60)
    return diffHr + "h ago"
  }

  function parseStatus(raw) {
    try {
      var trimmed = String(raw || "").trim()
      if (!trimmed) {
        root.hasError = true
        root.errorMessage = "Empty output from CodeBurn"
        return
      }
      var parsed = JSON.parse(trimmed)
      if (parsed && typeof parsed === "object") {
        if (parsed.error) {
          root.hasError = true
          root.errorMessage = String(parsed.error)
        } else {
          root.statusData = parsed
          root.hasError = false
          root.errorMessage = ""
          root.lastUpdatedMs = Date.now()
          root.nowMs = Date.now()
        }
      } else {
        root.hasError = true
        root.errorMessage = "Invalid JSON structure"
      }
    } catch (e) {
      console.warn("agents/spend: JSON parse error", e)
      root.hasError = true
      root.errorMessage = "Unable to parse CodeBurn JSON output"
    }
  }

  function refresh() {
    if (statusProcess.running) return
    root.refreshing = true
    statusProcess.running = true
  }

  // Opening the Spend tab shows whatever the last poll found; a status older
  // than a minute is refreshed on the spot.
  function refreshIfStale() {
    if (Date.now() - root.lastUpdatedMs > 60000) root.refresh()
  }

  Process {
    id: statusProcess
    command: root.excludeOmp
      ? [root.statusCommand, root.selectedPeriod]
      : [root.statusCommand, root.selectedPeriod, "--include-omp"]
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseStatus(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim().length > 0) {
          console.warn("agents/spend stderr:", text.trim())
        }
      }
    }

    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0) {
        root.hasError = true
        if (root.errorMessage === "") {
          root.errorMessage = "CodeBurn command exited with code " + exitCode
        }
      }
    }
  }

  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Cheap enough to run always: it only re-evaluates the "Updated …" binding.
  Timer {
    id: tickTimer
    interval: 15000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }
}
