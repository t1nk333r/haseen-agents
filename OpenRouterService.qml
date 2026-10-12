import QtQuick
import Quickshell
import Quickshell.Io
import "OpenRouterModel.js" as Model

// OpenRouter tab's data half — the account balance, the key's spend cap and
// the spend windows, polled through bin/openrouter-credits.
//
// Same shape as DeepSeekService: a hidden Item the panel instantiates once,
// so the poll runs whether or not the panel is open and the bar badge, the
// alarm and the tab all read one view. One Timer, one reusable Process, at
// most one helper run in flight, and a watchdog that stops a run the helper's
// own curl timeouts somehow did not.
//
// The API key never passes through here on a poll: the helper resolves it
// itself (environment, then the key file) and only reports where it came
// from. The one time the key does pass through is a save from the tab's
// field, and then it goes to bin/openrouter-save-key over the Process's
// stdin — never argv, never the environment — and the only reference to it
// is a one-shot closure that is dropped as soon as the bytes are written.
// Nothing here logs it.
//
// Adapted from SpoilHeap/Omarchy.OpenRouter @ b443c42 (MIT, Service.qml):
// the timer + helper loop and the stdin save. Its `keyCommand` setting (a
// command run to produce the key) is deliberately not carried over.
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

  function numberSetting(name, fallback, lo, hi) {
    var value = Number(root.setting(name, fallback))
    if (!isFinite(value)) value = fallback
    return Math.max(lo, Math.min(hi, value))
  }

  // Derived from where Omarchy installs a plugin, so the helper is found
  // whatever the plugin directory is called (as SpendService does).
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    if (url.indexOf("localhost/") === 0) url = url.substring(9)
    try { url = decodeURIComponent(url) } catch (e) { }
    return url.replace(/\/+$/, "")
  }
  readonly property string creditsCommand: root.pluginDir + "/bin/openrouter-credits"
  readonly property string saveCommand: root.pluginDir + "/bin/openrouter-save-key"

  readonly property int refreshIntervalSec: Math.round(root.numberSetting("openrouterRefreshIntervalSec", 300, 60, 21600))
  readonly property real lowBalance: root.numberSetting("openrouterLowBalance", 5, 0, 100000)

  // Where a key saved from the panel lands; the tab shows it (with ~). Same
  // rule as the helpers: a relative XDG_CONFIG_HOME is ignored.
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string keyFilePath: {
    var base = String(Quickshell.env("XDG_CONFIG_HOME") || "")
    if (base.charAt(0) !== "/") base = root.home + "/.config"
    return base + "/haseen/agents/openrouter/key"
  }

  // ---- state --------------------------------------------------------------
  property var view: Model.initialView()
  // A helper run is in flight (the tab's "Saved — checking…" reads it).
  readonly property bool refreshing: root._runOpen
  property bool saving: false
  property string saveError: ""
  // A key was saved and its first answer has not landed yet.
  property bool justSaved: false

  readonly property string labelText: Model.barLabel(root.view)
  readonly property string tooltipLine: Model.tooltipLine(root.view)
  readonly property bool balanceLow: Model.isLow(root.view, root.lowBalance)
  readonly property bool attention: Model.attention(root.view, root.lowBalance)

  signal keySaved()

  // ---- one helper run -------------------------------------------------------
  // A run is finished when both the process has exited and its stdout has
  // been collected; Quickshell does not promise which of the two comes first,
  // so each records its half and the second one settles the run. `settle`
  // covers a half that never reports (including a run the watchdog stopped).
  // Signals that arrive while no run is open belong to a run already settled
  // and are ignored.
  property bool _runOpen: false
  property int _runExit: -1
  property bool _runStreamDone: false
  property string _runText: ""
  property bool _timedOut: false
  property bool _rerun: false
  // Bumped when the view is reset after a save: a run started before the
  // reset answers for the old key, so its result is dropped.
  property int _viewGen: 0
  property int _runViewGen: 0

  function refreshNow() {
    if (root._runOpen || proc.running) {
      // A save (or a click) during a run: run once more when it ends, so the
      // view never settles on a result from before the change.
      root._rerun = true
      return
    }
    root._timedOut = false
    root._runOpen = true
    root._runExit = -1
    root._runStreamDone = false
    root._runText = ""
    root._runViewGen = root._viewGen
    proc.command = [root.creditsCommand]
    proc.running = true
    watchdog.restart()
  }

  function finishRun() {
    if (!root._runOpen) return
    root._runOpen = false
    watchdog.stop()
    settle.stop()
    var raw = root._runStreamDone ? root._runText : String(out.text || "")
    root._runText = ""
    var result
    if (root._timedOut) result = Model.failedResult("The OpenRouter check took too long and was stopped")
    else if (root._runExit !== 0) result = Model.failedResult("The OpenRouter helper could not run")
    else if (raw.length > 1048576) result = Model.failedResult("The OpenRouter helper reply was too large")
    else result = Model.normalize(raw)
    root._timedOut = false
    if (root._runViewGen === root._viewGen) {
      root.view = Model.reduce(root.view, result, Date.now())
      root.justSaved = false
    }
    if (root._rerun) {
      root._rerun = false
      root.startQueued()
    }
  }

  // The queued run starts only once the previous process is really gone.
  function startQueued() {
    if (proc.running) {
      root._rerun = true
      rerunTimer.restart()
    } else root.refreshNow()
  }

  // ---- saving a key ---------------------------------------------------------
  property bool _saveOpen: false
  property int _saveExit: -1
  property bool _saveStreamDone: false
  property string _saveText: ""
  property bool _saveTimedOut: false
  // The one-shot writer for a pending save (see saveKey). A function, not the
  // key: it is disconnected and dropped the moment it runs or the save ends.
  property var _saveWriter: null

  // Hand a key to the save helper. The text is checked against the helpers'
  // own allowlist first, so a stray paste never reaches a process at all.
  function saveKey(input) {
    if (root.saving) return
    var key = Model.cleanKey(input)
    input = ""
    if (key === "") return
    if (!Model.validKey(key)) {
      key = ""
      root.saveError = "That is not a valid OpenRouter key"
      return
    }
    root.saveError = ""
    root.saving = true
    root._saveTimedOut = false
    root._saveOpen = true
    root._saveExit = -1
    root._saveStreamDone = false
    root._saveText = ""
    var writer = function() {
      saveProc.started.disconnect(writer)
      if (root._saveWriter === writer) root._saveWriter = null
      saveProc.write(key + "\n")
      key = ""
    }
    root._saveWriter = writer
    saveProc.started.connect(writer)
    saveProc.command = [root.saveCommand]
    saveProc.running = true
    saveWatchdog.restart()
  }

  function dropSaveWriter() {
    if (root._saveWriter === null) return
    saveProc.started.disconnect(root._saveWriter)
    root._saveWriter = null
  }

  function finishSave() {
    if (!root._saveOpen) return
    root._saveOpen = false
    saveWatchdog.stop()
    saveSettle.stop()
    root.dropSaveWriter()
    root.saving = false
    var raw = root._saveStreamDone ? root._saveText : String(saveOut.text || "")
    root._saveText = ""
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
    var timedOut = root._saveTimedOut
    root._saveTimedOut = false
    if (!timedOut && root._saveExit === 0 && parsed && typeof parsed === "object" && parsed.ok === true) {
      root.saveError = ""
      // Same key path, different key: nothing on screen is the new key's, so
      // the view goes back to loading (and a run already in flight for the
      // old key is dropped) until the next run answers.
      root._viewGen++
      root.view = Model.afterSave()
      root.justSaved = true
      root.keySaved()
      root.refreshNow()
      return
    }
    var message = parsed && typeof parsed === "object" ? Model.cleanText(parsed.error) : ""
    if (timedOut) message = "Saving the key took too long and was stopped"
    root.saveError = message !== "" ? message : "Could not save the key"
  }

  function clearSaveError() { root.saveError = "" }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  // The helper's curl calls are capped at 8 s each and it makes at most
  // three, sequentially (~24 s worst case); a run still going at 30 s is
  // hung, not slow.
  Timer {
    id: watchdog
    interval: 30000
    repeat: false
    onTriggered: {
      if (!root._runOpen) return
      if (proc.running) {
        root._timedOut = true
        proc.running = false
      }
      // Whatever the stopped process does or does not report, the run ends.
      settle.restart()
    }
  }

  // The save helper's own stdin read gives up at 15 s.
  Timer {
    id: saveWatchdog
    interval: 20000
    repeat: false
    onTriggered: {
      if (!root._saveOpen) return
      if (saveProc.running) {
        root._saveTimedOut = true
        saveProc.running = false
      }
      saveSettle.restart()
    }
  }

  Timer {
    id: settle
    interval: 1000
    repeat: false
    onTriggered: root.finishRun()
  }

  Timer {
    id: saveSettle
    interval: 1000
    repeat: false
    onTriggered: root.finishSave()
  }

  Timer {
    id: rerunTimer
    interval: 250
    repeat: false
    onTriggered: {
      if (!root._rerun) return
      root._rerun = false
      root.startQueued()
    }
  }

  Process {
    id: proc
    command: []
    stdout: StdioCollector {
      id: out
      waitForEnd: true
      onStreamFinished: {
        if (!root._runOpen) return
        root._runText = String(text || "")
        root._runStreamDone = true
        if (root._runExit !== -1) root.finishRun()
      }
    }
    onExited: function(exitCode) {
      if (!root._runOpen) return
      root._runExit = exitCode
      if (root._runStreamDone) root.finishRun()
      else settle.restart()
    }
  }

  Process {
    id: saveProc
    command: []
    stdinEnabled: true
    stdout: StdioCollector {
      id: saveOut
      waitForEnd: true
      onStreamFinished: {
        if (!root._saveOpen) return
        root._saveText = String(text || "")
        root._saveStreamDone = true
        if (root._saveExit !== -1) root.finishSave()
      }
    }
    onExited: function(exitCode) {
      if (!root._saveOpen) return
      root._saveExit = exitCode
      if (root._saveStreamDone) root.finishSave()
      else saveSettle.restart()
    }
  }
}
