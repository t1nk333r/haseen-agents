import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "FleetModel.js" as Model

// Fleet tab's data half: the read-only Herdr/OMP connector snapshot that used
// to live inside t1nk33r.fleet-shepherd's Panel.qml (plan 128).
//
// One helper, one argv, one poll: bin/fleet-snapshot owns timeouts, process
// groups, output ceilings, normalization and connector isolation, and QML never
// starts SSH, Herdr or OMP directly. The snapshot's cache and lock live under
// $XDG_RUNTIME_DIR/t1nk33r.agents (CACHE_DIRNAME in the helper); connectors are
// still read from ~/.config/fleet-shepherd/connectors.json, which is where the
// owner's config has always lived.
//
// This is a service, not a popup: it polls whether or not the panel is open,
// because the bar badge and tooltip have to stay honest.
Item {
  id: root
  visible: false

  property var settings: ({})

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // The tab's rows paint their health dots and the badge its alarm through
  // these; the coordinator binds them to the bar's own palette.
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)

  // --------------------------------------------------------------- settings
  function intSetting(name, fallback, lo, hi) {
    var n = Number(root.setting(name, fallback))
    if (!isFinite(n)) n = fallback
    return Math.max(lo, Math.min(hi, Math.round(n)))
  }
  readonly property int refreshInterval: root.intSetting("fleetRefreshIntervalSec", 30, 5, 3600)
  // CACHE_TTL_MIN/MAX in bin/fleet-snapshot; out-of-range values make the
  // helper exit non-zero, so clamp here rather than surface a failed sweep.
  readonly property int cacheTtl: root.intSetting("fleetCacheTtl", 120, 1, 300)

  // ---------------------------------------------------------------- helpers
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    if (url.indexOf("localhost/") === 0) url = url.substring(9)
    try { url = decodeURIComponent(url) } catch (e) { }
    return url.replace(/\/+$/, "")
  }
  readonly property string helper: root.pluginDir + "/bin/fleet-snapshot"
  readonly property string focusHelper: root.pluginDir + "/bin/fleet-focus"

  // ------------------------------------------------------------------ state
  property bool loading: false
  property string errorText: ""
  property string focusNote: ""
  property var snapshot: ({ connectors: [], summary: { connectors: 0, online: 0, stale: 0, offline: 0, working: 0, blocked: 0, requests: 0, cost: 0 } })

  // Raised when a connector's terminal was successfully focused: the panel is
  // painted above it, so it has to get out of the way for the raise to be
  // visible at all.
  signal connectorRaised()

  readonly property var connectors: root.snapshot.connectors || []
  readonly property var summary: root.snapshot.summary
  readonly property bool unavailable: root.errorText !== "" && root.connectors.length === 0
  readonly property bool allOffline: root.summary.connectors > 0 && root.summary.online === 0

  function ageText(value) {
    var ms = Date.now() - Date.parse(String(value || ""))
    if (!isFinite(ms) || ms < 0) return "unknown"
    var sec = Math.floor(ms / 1000)
    if (sec < 60) return "just now"
    var min = Math.floor(sec / 60)
    if (min < 60) return min + "m ago"
    return Math.floor(min / 60) + "h ago"
  }

  // Only real trouble gets the urgent colour and only live work gets the
  // accent; a healthy connector reads as ordinary foreground, so a fleet at
  // rest does not look like a fleet on fire.
  function stateColor(state) {
    if (state === "blocked" || state === "offline") return root.urgent
    if (state === "working") return root.accent
    if (state === "online") return root.foreground
    return root.dim
  }

  // ------------------------------------------------------------- bar label
  // Compact by design: the bar carries the glyph, the working count, a blocked
  // alarm. Spend stays in the tooltip and the panel.
  readonly property string barLabel: {
    if (root.unavailable) return "—"
    var parts = [String(root.summary.working)]
    if (root.summary.blocked > 0) parts.push("!" + root.summary.blocked)
    return parts.join(" ")
  }
  readonly property string barTooltip: {
    if (root.unavailable) return "Fleet\n" + root.errorText
    return "Fleet\n"
      + root.summary.online + "/" + root.summary.connectors + " connectors online"
      + (root.summary.stale > 0 ? " · " + root.summary.stale + " stale" : "")
      + "\n" + root.summary.working + " working · " + root.summary.blocked + " blocked"
      + "\n" + Model.compact(root.summary.requests) + " requests · " + Model.money(root.summary.cost)
      + "\nupdated " + root.ageText(root.snapshot.generatedAt)
  }

  readonly property string heroDetail: {
    if (root.summary.blocked > 0) return "!" + root.summary.blocked + " blocked"
    if (root.summary.working > 0) return root.summary.working + " working"
    return root.summary.connectors === 0 ? "no fleet" : "idle"
  }
  readonly property string heroMeta: {
    if (root.loading && root.connectors.length === 0) return "contacting fleet…"
    return root.summary.online + "/" + root.summary.connectors + " online · "
      + root.ageText(root.snapshot.generatedAt) + (root.loading ? " · refreshing" : "")
  }

  // --------------------------------------------------------------- actions
  function refresh(force) {
    if (snapshotProcess.running) return
    root.loading = true
    root.errorText = ""
    var argv = ["python3", root.helper, "--cache-ttl", String(root.cacheTtl)]
    // First paint shows whatever is cached, however old, instead of blocking
    // the bar on a full fleet sweep.
    if (force !== true && root.connectors.length === 0) argv.push("--stale-ok")
    if (force === true) argv.push("--refresh")
    snapshotProcess.command = argv
    snapshotProcess.running = true
  }

  function focusConnector(connector) {
    if (!connector) return
    root.focusNote = ""
    focusProcess.label = connector.label
    focusProcess.command = ["python3", root.focusHelper, connector.focusTarget]
    focusProcess.running = true
  }

  Process {
    id: snapshotProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        var raw = String(text || "")
        if (raw.length > 4194304) {
          root.errorText = "Fleet snapshot exceeded 4 MiB — rejected"
          root.snapshot = Model.markAllStale(root.snapshot, root.errorText)
          return
        }
        try {
          var next = Model.normalizeSnapshot(JSON.parse(raw))
          root.snapshot = Model.mergeSnapshot(root.snapshot, next)
          root.errorText = ""
        } catch (e) {
          root.errorText = "Fleet snapshot was malformed"
          root.snapshot = Model.markAllStale(root.snapshot, root.errorText)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") console.warn("agents/fleet", String(text).trim())
    }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0) {
        root.errorText = "Fleet snapshot failed (exit " + exitCode + ")"
        root.snapshot = Model.markAllStale(root.snapshot, root.errorText)
      }
    }
  }

  Process {
    id: focusProcess
    running: false
    property string label: ""
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.focusNote = ""
        root.connectorRaised()
        return
      }
      root.focusNote = exitCode === 2 ? "could not raise window for " + focusProcess.label
        : exitCode === 3 ? "invalid focus target for " + focusProcess.label
        : "no local herdr window for " + focusProcess.label
    }
  }

  Component.onCompleted: refresh(false)

  // The bar badge has to stay honest whether or not the panel is open; the
  // helper's own cache keeps this to a file read most of the time.
  Timer {
    interval: root.refreshInterval * 1000
    repeat: true
    running: true
    onTriggered: root.refresh(false)
  }
}
