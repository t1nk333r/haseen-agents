import QtQuick
import Quickshell
import Quickshell.Io
import "DeepSeekModel.js" as Model
import "Pricing.js" as Pricing

// DeepSeek tab's data half — DeepSeek API balance, availability, the measured
// usage ledger and the peak/off-peak pricing state (t1nk33r.deepseek until
// plan 128).
//
// The bar face and the popup this file used to carry are gone: the merged
// panel owns the mark and DeepSeekTab.qml paints the tab. What is left is the
// part that has to run whether or not the panel is open — the balance poll,
// the low-balance alert and the ledger — plus the pricing clock the bar badge
// and the tab both read.
//
// Polling lives here (never in the tab). One Timer + one reusable Process
// keeps the shell load minimal: at most one curl request in flight, one per
// poll interval (default 60 s). The API key only ever travels via the
// process environment OBJECT (Quickshell Process.environment is
// { VAR: value }) into curl's stdin config (--config -); it is never a
// command-line argument and DeepSpend never logs it or prints it anywhere.
Item {
  id: root
  // Hidden: this is the panel's always-running data half, not a bar widget.
  visible: false

  // The coordinator injects its shell.json entry here, the same object
  // Panel.setting() reads.
  property var settings: ({})

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // ---- pricing (merged from io.github.caffeinatedtech.qs-plugin-deepseek-pricing)
  // Peak windows are defined in UTC — 01:00-04:00 and 06:00-10:00, Mon-Fri —
  // and the whale carries the state in its colour: red at double rate, green
  // at half. One tick a second keeps the countdown and the icon honest. The
  // clocks it renders are the operator's zone (UTC+3), not UTC's.
  property date nowTick: new Date()
  readonly property bool peak: Pricing.isPeakAt(root.nowTick)
  readonly property url whaleSource: root.peak
    ? Qt.resolvedUrl("assets/deepseek-peak.svg")
    : Qt.resolvedUrl("assets/deepseek-offpeak.svg")
  readonly property string pricingStatus: root.peak
    ? "Peak pricing — double rate" : "Off-peak pricing — half price"
  readonly property double pricingNextChangeMs: Pricing.nextChange(root.nowTick).getTime() - root.nowTick.getTime()
  readonly property string pricingCountdown: Pricing.formatCompact(root.pricingNextChangeMs)
  readonly property string pricingUntil: (root.peak ? "peak ends in " : "peak starts in ") + root.pricingCountdown
  readonly property string pricingFlipLocal: Pricing.formatLocal(Pricing.nextChange(root.nowTick))
  readonly property string peakWindowsLabel: Pricing.peakWindowsLabel()
  // The ticking counter the pricing parent put at the top of its panel:
  // hours:minutes:seconds to the next change, and what it is counting to.
  readonly property string pricingClock: Pricing.formatClock(root.pricingNextChangeMs)
  readonly property string pricingUntilLabel: root.peak ? "until off-peak" : "until peak"
  readonly property string localNow: Pricing.formatLocal(root.nowTick)

  Timer {
    interval: 1000
    // Always on: the badge and the tab read the pricing state, and the
    // service has no bar to attach to.
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowTick = new Date()
  }

  // ---- config -------------------------------------------------------------
  readonly property string configPath: {
    var base = Quickshell.env("XDG_CONFIG_HOME")
    if (!base) base = (Quickshell.env("HOME") || "") + "/.config"
    return base + "/deepspend/config.json"
  }

  property var config: Model.defaults()
  property string configErrorKind: ""
  property var _lastConfigRaw: null
  property bool _configSeen: false
  property bool _configLoadFailed: false

  // Full human-readable problem (with character hint) while the config file
  // is broken. Empty means the config is fine or simply not created yet.
  readonly property string configError: root.view.status === "config_error"
    ? Model.configProblemText(root.view)
    : ""

  // ---- state --------------------------------------------------------------
  property var view: Model.initialView()
  // _dueAt is a millisecond epoch (Date.now() ~1.7e12); `int` would wrap at
  // 2^31 (~2.1e9) and make the dueAt check always pass, so it must be double.
  property double _dueAt: 0
  property string _output: ""
  property string _logKey: ""

  // ---- low-balance alerts (DS-3) -----------------------------------------
  property var alertState: Model.initialAlertState()
  property string _instanceId: ""
  property var _alertQueue: []
  property var _alertPending: null
  property bool _alertGateMode: false
  property string _alertOut: ""
  property bool _alertFileLoaded: false
  property bool _pendingAlertEval: false
  property string alertStateFile: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base) base = (Quickshell.env("HOME") || "") + "/.local/state"
    return base + "/haseen/agents/deepseek/alerts.state"
  }
  // Usage is measured, not reported: DeepSeek's API has no usage endpoint, so
  // every successful poll is a sample and the movement between two samples is
  // what was spent (a drop) or added (a rise). The ledger is one row per local
  // day plus two running totals — see Model.usageRecord.
  property var usage: Model.initialUsage()
  property bool _usageLoaded: false
  property bool _usageDirty: false
  property bool _usageFirstFlush: true
  property string usageFile: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base) base = (Quickshell.env("HOME") || "") + "/.local/state"
    return base + "/haseen/agents/deepseek/usage.state"
  }
  property string alertGateFile: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base) base = (Quickshell.env("HOME") || "") + "/.local/state"
    return base + "/haseen/agents/deepseek/alerts.gate"
  }
  // Wherever the plugin directory is, so bin/ is found without naming it.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    if (url.indexOf("localhost/") === 0) url = url.substring(9)
    try { url = decodeURIComponent(url) } catch (e) { }
    return url.replace(/\/+$/, "")
  }

  readonly property bool alertArmed: Model.alertArmed(root.config)
  readonly property bool balanceLow: Model.isLowBalance(root.view, root.config)

  // ---- config handling ----------------------------------------------------
  function applyConfig(raw) {
    // FileView can report the same content twice for one save (a watch event
    // plus the explicit reload). Reapplying an identical config would reset
    // the poll timer and fire a duplicate balance request, so identical
    // loads are ignored.
    if (raw === root._lastConfigRaw) return
    root._lastConfigRaw = raw
    root._configSeen = true
    root._configLoadFailed = false
    var parsed = Model.parseConfig(raw)
    if (!parsed.ok) {
      // Blank file: the calm first-run state (same as a missing file). The
      // panel offers "Create config file" to write the key-free template.
      if (parsed.kind === "empty") {
        root.configErrorKind = ""
        root.config = Model.defaults()
        root.view = Model.reduce(root.view, {
          type: "config", config: root.config
        })
        console.log("DeepSpend: config file is empty — showing the first-run state")
        return
      }
      // Broken config (invalid JSON / wrong shape / invalid field): keep the
      // widget calm, show the specific problem and let the panel offer
      // recovery. root.config stays the no-key defaults so nothing fetches.
      root.configErrorKind = parsed.kind
      root.config = Model.defaults()
      root.view = Model.reduce(root.view, {
        type: "configError",
        problem: { kind: parsed.kind, error: parsed.error,
          at: parsed.at, hint: parsed.hint }
      })
      console.warn("DeepSpend: " + Model.configProblemText(root.view))
      return
    }
    root.configErrorKind = ""
    root.config = parsed.config
    root.view = Model.reduce(root.view, {
      type: "config", config: root.config
    })
    root._logKey = ""
    root._dueAt = 0
    // A config change can arm/disarm the alert. The in-memory alert zone is
    // kept (the panel mirrors it); notifications only fire on real balance
    // transitions, so re-arming never announces the current balance.
    Qt.callLater(root.tick)
  }

  function refreshConfig() {
    configFile.reload()
  }

  // Manual refresh (middle click / panel button). Forces a fetch when a key
  // is present; otherwise re-checks the config file in case it was created.
  function refreshNow() {
    if (root.config && root.config.hasKey) {
      root._dueAt = 0
      root.tick()
    } else {
      root.refreshConfig()
    }
  }

  // One heartbeat tick. Starts a fetch when a key is configured, the process
  // is idle and the poll interval has elapsed.
  function tick() {
    if (proc.running) return
    if (!root.config || !root.config.hasKey) return
    if (Date.now() < root._dueAt) return
    root.view = Model.reduce(root.view, { type: "fetchStart" })
    var req = Model.buildRequestArgs(root.config)
    if (!req) return
    root._output = ""
    proc.command = req.command
    proc.environment = req.environment
    proc.running = true
  }

  function handleExited(exitCode) {
    var dueIn = (root.config ? root.config.pollIntervalSeconds
      : Model.DEFAULT_POLL_INTERVAL_SECONDS) * 1000
    root._dueAt = Date.now() + dueIn
    // The key may have been removed — or the config file invalidated — while
    // this request was in flight. A stale result must not resurrect an old
    // balance underneath the calm no-key state, so it is dropped.
    if (!Model.acceptFetchResult(root.config)) return
    var output = String(probeStdout.text || root._output || "")
    var result = Model.parseFetchResult(exitCode, output, root.config.currency)
    var next
    if (result.ok) {
      next = Model.reduce(root.view, {
        type: "fetchSuccess", balance: result.balance, at: Date.now()
      })
    } else {
      next = Model.reduce(root.view, {
        type: "fetchFail", kind: result.kind, message: result.message
      })
    }
    var key = next.status + "|" + next.errorKind
    if (key !== root._logKey) {
      root._logKey = key
      console.log("DeepSpend: " + Model.statusLine(next))
    }
    root.view = next
    // Only a *fresh successful* check may move the alert zone; failed checks
    // keep the last known zone instead of flipping to an alert on stale data.
    if (result.ok) {
      root.recordUsage(result.balance)
      root.evaluateAlerts()
    }
  }

  // Evaluate the low-balance alert against the fresh view and queue one
  // Omarchy notification per real transition (ok -> low / low -> ok). The
  // Model reducer guarantees at most one event per transition, never a
  // periodic repeat while the zone stays the same. The last zone is kept in a
  // tiny state file, so a shell restart cannot re-notify an unchanged low
  // balance.
  function evaluateAlerts() {
    if (!root.config) return
    if (!root._alertFileLoaded) {
      // Deterministic start: wait for the persisted zone before judging a
      // transition (otherwise a restart while low could re-announce).
      root._pendingAlertEval = true
      return
    }
    var before = root.alertState
    var res = Model.reduceAlertState(before, {
      total: Model.numericTotal(root.view),
      threshold: root.config.lowBalanceThreshold,
      armed: !!(root.config.lowBalanceThreshold > 0),
      enabled: root.config.notificationsEnabled !== false
    })
    root.alertState = res.state
    if (!Model.sameAlertState(before, res.state)) root.writeAlertState()
    for (var i = 0; i < res.events.length; i++) {
      root.enqueueAlert(res.events[i])
    }
  }

  function writeAlertState() {
    if (alertWriteProc.running) return
    var dir = Model.configDir(root.alertStateFile)
    var text = Model.alertStateToText(root.alertState)
    alertWriteProc.command = [
      "bash", "-c",
      "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$3\"",
      "deepspend-alert-state", dir, text, root.alertStateFile
    ]
    alertWriteProc.running = true
  }

  function enqueueAlert(event) {
    if (!event) return
    var parts = Model.alertParts(event, root.view)
    if (!parts || !parts.summary) return
    // haseen-notification-send when haseen is installed (it has no glyph
    // option, so the glyph rides only with Omarchy's sender), else Omarchy's.
    var omarchyPath = Quickshell.env("OMARCHY_PATH")
    var omarchySend = omarchyPath
      ? omarchyPath + "/bin/omarchy-notification-send"
      : "/usr/bin/omarchy-notification-send"
    var args = ["bash", "-c",
      "if command -v haseen-notification-send >/dev/null 2>&1; then"
        + " exec haseen-notification-send --app-name DeepSpend -u \"$1\" \"$3\" \"$4\"; fi;"
        + " exec \"$5\" --app-name DeepSpend -u \"$1\" -g \"$2\" \"$3\" \"$4\"",
      "deepspend-notify", parts.urgency, parts.glyph, parts.summary, parts.body, omarchySend]
    root._alertQueue = root._alertQueue.concat([{ event: event, args: args }])
    root.runNextAlert()
  }

  // Serialized dispatcher. Each queued event first passes the cross-instance
  // gate (Model.alertGateCommandArgs); "send" fires the real Omarchy
  // notification, "skip" (a twin instance already notified this transition)
  // drops the event silently.
  function runNextAlert() {
    if (alertProc.running) return
    if (root._alertQueue.length === 0) return
    var entry = root._alertQueue[0]
    root._alertQueue = root._alertQueue.slice(1)
    root._alertPending = entry
    root._alertGateMode = true
    root._alertOut = ""
    var pollMs = (root.config ? root.config.pollIntervalSeconds
      : Model.DEFAULT_POLL_INTERVAL_SECONDS) * 1000
    var ttl = Math.max(120, Math.round(pollMs / 1000) * 2)
    alertProc.command = Model.alertGateCommandArgs(root.alertGateFile,
      Model.alertGateKey(entry.event), root._instanceId, ttl)
    alertProc.running = true
  }

  function finishAlert(exitCode, output) {
    if (root._alertGateMode) {
      root._alertGateMode = false
      var gate = String(output == null ? "" : output).trim()
      var entry = root._alertPending
      root._alertPending = null
      if (gate === "send" && entry && entry.args) {
        var parts = Model.alertParts(entry.event, root.view)
        console.log("DeepSpend: melding — " + (parts && parts.summary
          ? parts.summary : "low-balance alert"))
        alertProc.command = entry.args
        alertProc.running = true
        return
      }
      Qt.callLater(root.runNextAlert)
      return
    }
    root._alertPending = null
    Qt.callLater(root.runNextAlert)
  }

  // A sample per successful poll; the write is debounced, and a missed flush
  // costs nothing: the next sample measures the same movement across the
  // longer gap.
  function recordUsage(balance) {
    if (!balance) return
    // usageRecord folds the sample into the ledger it is given and hands it
    // back, so identity says nothing: `lastAt` advances exactly when a sample
    // was actually taken, and a backwards clock leaves it alone.
    var sampledAt = Number(root.usage.lastAt || 0)
    var next = Model.usageRecord(root.usage, {
      currency: balance.currency,
      total: balance.total,
      // The pricing half of this plugin already knows whether the moment is
      // peak; the ledger stores spend per state so the token estimate can
      // convert each bucket at its own rate.
      peak: root.peak
    }, Date.now())
    root.usage = next
    if (Number(next.lastAt) !== sampledAt) {
      root._usageDirty = true
      // The very first sample is written promptly: a fresh install should show
      // its ledger within seconds, not after the debounce, and a crash then
      // costs one baseline rather than five minutes of samples.
      if (root._usageFirstFlush) {
        root._usageFirstFlush = false
        root.flushUsage()
      }
    }
  }

  // Atomic: a same-directory temp file and a rename, so a reader sees either
  // the old ledger or the new one, never half of either.
  function flushUsage() {
    if (!root._usageLoaded || !root._usageDirty) return
    var dir = Model.configDir(root.usageFile)
    usageWriteProc.command = [
      "bash", "-c",
      "umask 077; mkdir -p -- \"$1\" || exit 1; tmp=\"$3.tmp.$$\";"
        + " printf '%s' \"$2\" > \"$tmp\" || exit 1;"
        + " mv -f -- \"$tmp\" \"$3\" || exit 1",
      "deepseek-usage-state", dir, Model.usageToText(root.usage), root.usageFile
    ]
    usageWriteProc.running = true
    root._usageDirty = false
  }

  // " · today ≈ 1.24M tokens" on the tooltip, when the account's currency has
  // a published rate table to estimate from.
  readonly property string usageTodayTooltip: {
    var today = Model.usageToday(root.usage, Date.now())
    var tokens = Model.usageTokens(today.spentPeak, today.spentOffPeak, root.view.currency || Model.DEFAULT_CURRENCY, root.tokenModel)
    return tokens === null || tokens <= 0 ? "" : " \u00b7 today \u2248 " + Model.formatTokens(tokens) + " tokens"
  }

  // ---- display ------------------------------------------------------------
  // The logo says which plugin this is; the label is the amount alone (or "!"
  // when the last answer was a failure), by the same rules as before.
  readonly property string tokenModel: String(setting("deepseekTokenModel", Model.TOKEN_MODEL_DEFAULT))
  readonly property string labelText: Model.barAmount(root.view)
  readonly property bool attention: Model.wantsAttention(root.view) || root.balanceLow
  readonly property bool dimmed: Model.isDimmed(root.view)
  readonly property string tooltip: root.view.status === "config_error"
    ? Model.configTooltip(root.view, root.configPath)
    : (root.balanceLow && root.view.isAvailable !== false
        ? Model.tooltipText(root.view, root.configPath) + " \u00b7 below your alert threshold"
        : Model.tooltipText(root.view, root.configPath))
    + " \u00b7 " + root.pricingStatus + " \u00b7 " + root.pricingUntil
    + root.usageTodayTooltip

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onFileChanged: reload()
    onLoadFailed: {
      // File does not exist (yet). Show the no-key state; the heartbeat
      // below keeps retrying in case the user creates the file later.
      root._lastConfigRaw = null
      root._configSeen = true
      root._configLoadFailed = true
      root.configErrorKind = ""
      root.config = Model.defaults()
      root.view = Model.reduce(root.view, {
        type: "config", config: root.config
      })
    }
  }

  // Heartbeat. Re-checks a missing config file; starts fetches on schedule.
  Timer {
    id: pollTimer
    interval: 2000
    repeat: true
    running: true
    triggeredOnStart: false
    onTriggered: {
      if (!root._alertFileLoaded) {
        alertStateView.reload()
        return
      }
      if (!root._configSeen || root._configLoadFailed) {
        root.refreshConfig()
        return
      }
      root.tick()
    }
  }

  Process {
    id: proc
    command: []
    stdout: StdioCollector {
      id: probeStdout
      waitForEnd: true
      onStreamFinished: root._output = text
    }
    onExited: function(exitCode) {
      root.handleExited(exitCode)
    }
  }

  // Helper used by the panel recovery buttons: writes the template file
  // (mode 600, placeholder key only) — either fresh ("Create config file")
  // or after keeping the broken file as config.json.bak-<ts>
  // ("Back up & create default") — so Shirak only has to paste his key.
  Process {
    id: createProc
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("DeepSpend: could not write the config file")
        return
      }
      root._configLoadFailed = false
      Qt.callLater(root.refreshConfig)
    }
  }

  // Low-balance alert notification dispatcher (DS-3): first the flock gate
  // (cross-instance dedupe), then -- when it answers "send" -- the real
  // notification call (enqueueAlert). See runNextAlert()/finishAlert().
  Process {
    id: alertProc
    command: []
    stdout: StdioCollector {
      id: alertStdout
      waitForEnd: true
      onStreamFinished: root._alertOut = text
    }
    onExited: function(exitCode) {
      var output = String(alertStdout.text || root._alertOut || "")
      root._alertOut = ""
      root.finishAlert(exitCode, output)
    }
  }

  // Per-widget identity for the notification gate: two Omarchy instances
  // (one per monitor) share the gate file; a widget only skips when *another*
  // instance already notified the same transition.
  Component.onCompleted: {
    root._instanceId = String(Math.floor(Math.random() * 0x7fffffff))
      + "-" + String(Date.now())
    // bin/agents-migrate first: the one-time copy of the Omarchy-era ledger
    // and alert files has to land before the ledger is touched here.
    usageInitProc.command = [
      "bash", "-c",
      "\"$3\" >/dev/null 2>&1; umask 077; mkdir -p -- \"$1\" || exit 1; [ -e \"$2\" ] || : > \"$2\"",
      "deepseek-usage-init", Model.configDir(root.usageFile), root.usageFile,
      root.pluginDir + "/bin/agents-migrate"
    ]
    usageInitProc.running = true
  }

  Component.onDestruction: root.flushUsage()

  // The ledger's writer (see flushUsage) and its debounce: one write every few
  // minutes rather than one per poll.
  Process {
    id: usageWriteProc
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("DeepSeek: could not write the usage ledger")
    }
  }

  // The ledger's directory and file, created once at startup. A FileView over
  // a path that does not exist reports neither loaded nor failed, so without
  // this the flush gate would stay shut on a fresh machine and nothing would
  // ever be written. The file is touched, never truncated: whatever history
  // survived is read back below, and the flush only starts once it has been.
  Process {
    id: usageInitProc
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("DeepSeek: could not prepare the usage ledger directory")
        return
      }
      if (!root._usageLoaded) {
        // Re-read deliberately: the FileView was built before the file
        // existed, so point it at the path again to get a real load.
        usageStateView.path = ""
        usageStateView.path = root.usageFile
      }
      // The alert zone may only now exist (migrated above): read it again.
      alertStateView.path = ""
      alertStateView.path = root.alertStateFile
    }
  }

  Timer {
    interval: 300000
    running: root._usageLoaded
    repeat: true
    onTriggered: root.flushUsage()
  }

  // Persisted alert zone (survives shell restarts, so an unchanged low
  // balance is never re-announced). Loaded once at startup; evaluation waits
  // for this so a restart cannot re-notify.
  FileView {
    id: alertStateView
    path: root.alertStateFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.alertState = Model.alertStateFromText(text())
      root._alertFileLoaded = true
      if (root._pendingAlertEval) {
        root._pendingAlertEval = false
        root.evaluateAlerts()
      }
    }
    onLoadFailed: {
      root.alertState = Model.initialAlertState()
      root._alertFileLoaded = true
      if (root._pendingAlertEval) {
        root._pendingAlertEval = false
        root.evaluateAlerts()
      }
    }
  }

  // The usage ledger, read once at startup. A missing or unusable file is a
  // fresh ledger, and the first sample after it becomes the baseline.
  FileView {
    id: usageStateView
    path: root.usageFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.usage = Model.usageFromText(text())
      root._usageLoaded = true
    }
    onLoadFailed: root._usageLoaded = true
  }

  Process {
    id: alertWriteProc
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("DeepSpend: could not persist alert state")
      }
    }
  }

  function createConfigFile() {
    if (createProc.running) return
    var dir = Model.configDir(root.configPath)
    var template = Model.templateConfigText()
    createProc.command = [
      "bash", "-c",
      // umask 077 first: the file is created mode 600 from the first byte
      // (never written wider and chmod'ed afterwards). Write goes to a
      // unique temp name in the same dir, then mv renames atomically.
      "umask 077; mkdir -p -- \"$1\" || exit 1;"
        + " tmp=\"$1/config.json.tmp.$$\";"
        + " printf '%s' \"$2\" > \"$tmp\" || exit 1;"
        + " mv -f -- \"$tmp\" \"$1/config.json\" || exit 1;"
        + " echo created",
      "deepspend-create-config", dir, template
    ]
    createProc.running = true
  }

  // DS-5 recovery action shown while the config file is broken: keep the
  // current file as config.json.bak-<ts>-<pid> and write the key-free
  // template in its place. Nothing the user typed is lost.
  function backupConfigFile() {
    if (createProc.running) return
    var dir = Model.configDir(root.configPath)
    var template = Model.templateConfigText()
    createProc.command = Model.backupAndTemplateCommandArgs(dir, template)
    createProc.running = true
  }

  // DS-5 recovery action: open the config file in the user's editor
  // (haseen config edit, else omarchy launch config-editor) so the broken
  // line can be fixed by hand. The path travels as an argument, never as
  // shell syntax, so it can never inject anything.
  function openConfigFile() {
    var omarchyPath = Quickshell.env("OMARCHY_PATH")
    var launcher = omarchyPath
      ? omarchyPath + "/bin/omarchy-launch-config-editor"
      : "/usr/bin/omarchy-launch-config-editor"
    Quickshell.execDetached(["bash", "-c",
      "if command -v haseen-config-edit >/dev/null 2>&1; then exec haseen-config-edit \"$1\"; fi;"
        + " exec \"$2\" \"$1\"",
      "deepspend-edit-config", root.configPath, launcher])
  }
}
