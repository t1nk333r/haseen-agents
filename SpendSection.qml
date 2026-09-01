import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Spend — what the agents actually cost, folded in from t1nk33r.codeburn when
// the three agent-telemetry plugins merged (plan 090).
//
// Deliberately kept as its own file rather than inlined into Panel.qml: it is a
// different quantity from a different source, and Panel.qml is already 1700
// lines. Usage/limits come from the JSON records omarchy-agent-usage-update
// writes; spend comes from `codeburn`, an npm tool, invoked through
// bin/codeburn-status. The two are never merged into one number — a percentage
// of a rate limit and a dollar figure are not the same thing.
//
// The script emits {"error": ...} when neither codeburn nor npx is installed,
// which is rendered as an inline notice. An absent optional dependency must not
// look like a hung section.
Column {
  id: root

  property string pluginDir: ""
  property string period: "today"
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  // Emitted when the user picks a different period, so the host can persist it
  // onto the plugin's shell.json entry.
  signal periodPicked(string periodId)

  readonly property var periods: [
    { id: "today",    label: "Today"    },
    { id: "week",     label: "7 Days"   },
    { id: "30days",   label: "30 Days"  },
    { id: "month",    label: "Month"    },
    { id: "all",      label: "6 Months" },
    { id: "lifetime", label: "Lifetime" }
  ]

  property var data: null
  property string errorText: ""
  property bool loading: false

  width: parent ? parent.width : 0
  spacing: Style.space(6)

  function refresh() {
    if (loading || root.pluginDir === "") return
    loading = true
    proc.command = [root.pluginDir + "/bin/codeburn-status", root.period]
    proc.running = true
  }

  function money(v) {
    var sym = root.data && root.data.currency ? String(root.data.currency.symbol || "$") : "$"
    var n = Number(v)
    if (!isFinite(n)) return sym + "0.00"
    // Four figures of spend do not need cents, and the bar has no room for them.
    return n >= 1000 ? sym + n.toFixed(0) : sym + n.toFixed(2)
  }

  function compact(n) {
    var v = Number(n)
    if (!isFinite(v)) return "0"
    if (v >= 1e9) return (v / 1e9).toFixed(1) + "B"
    if (v >= 1e6) return (v / 1e6).toFixed(1) + "M"
    if (v >= 1e3) return (v / 1e3).toFixed(1) + "K"
    return String(Math.round(v))
  }

  function periodLabel(id) {
    for (var i = 0; i < periods.length; i++)
      if (periods[i].id === id) return periods[i].label
    return id
  }

  Process {
    id: proc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        var raw = String(text || "").trim()
        if (raw === "") { root.errorText = "codeburn returned nothing"; root.data = null; return }
        try {
          var parsed = JSON.parse(raw)
          if (parsed && parsed.error) { root.errorText = String(parsed.error); root.data = null; return }
          root.data = parsed
          root.errorText = ""
        } catch (e) {
          root.errorText = "Could not parse codeburn output"
          root.data = null
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      root.loading = false
      if (code !== 0 && root.data === null && root.errorText === "")
        root.errorText = "codeburn exited " + code
    }
  }

  PanelSectionHeader {
    foreground: root.foreground
    fontFamily: root.fontFamily
    text: "SPEND"
  }

  // Period selector. Kept as plain buttons rather than a dropdown so the
  // current period is visible without a click, matching the panel's other rows.
  Flow {
    width: root.width
    spacing: Style.space(4)

    Repeater {
      model: root.periods
      delegate: Button {
        required property var modelData
        text: modelData.label
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        focusable: true
        bordered: root.period !== modelData.id
        selected: root.period === modelData.id
        onClicked: {
          if (root.period === modelData.id) return
          root.period = modelData.id
          root.periodPicked(modelData.id)
          root.refresh()
        }
      }
    }
  }

  Text {
    width: root.width
    visible: root.errorText !== ""
    text: root.errorText + "  ·  install codeburn or npx to see spend"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Text {
    width: root.width
    visible: root.loading && root.data === null && root.errorText === ""
    text: "Loading spend…"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // Headline cost for the selected period.
  Row {
    width: root.width
    visible: root.data !== null && root.errorText === ""
    spacing: Style.space(8)

    Text {
      anchors.baseline: sub.baseline
      text: root.data && root.data.current ? root.money(root.data.current.cost) : ""
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
      font.bold: true
    }

    Text {
      id: sub
      text: root.data && root.data.current
        ? root.periodLabel(root.period) + "  ·  "
          + root.compact(root.data.current.calls) + " calls  ·  "
          + root.compact(root.data.current.sessions) + " sessions"
        : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Token mix. Cache hit rate is the interesting number here — it is what makes
  // the difference between the input/output counts and the actual bill.
  Text {
    width: root.width
    visible: root.data !== null && root.errorText === ""
    text: {
      if (!root.data || !root.data.current) return ""
      var c = root.data.current
      return "in " + root.compact(c.inputTokens)
           + "  ·  out " + root.compact(c.outputTokens)
           + "  ·  cache read " + root.compact(c.cacheReadTokens)
           + "  ·  hit " + Number(c.cacheHitPercent || 0).toFixed(1) + "%"
    }
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // Recent daily spend, newest last, as a compact bar list.
  Column {
    id: dailyList
    width: root.width
    spacing: Style.space(2)
    visible: root.data !== null && root.errorText === ""
       && !!root.data.history && (root.data.history.daily || []).length > 0

    readonly property var days: root.data && root.data.history
      ? (root.data.history.daily || []).slice(-7) : []
    readonly property real peak: {
      var m = 0
      for (var i = 0; i < days.length; i++) m = Math.max(m, Number(days[i].cost) || 0)
      return m > 0 ? m : 1
    }

    Repeater {
      model: dailyList.days
      delegate: Row {
        required property var modelData
        width: dailyList.width
        spacing: Style.space(6)

        Text {
          width: Style.space(52)
          text: String(modelData.date || "").slice(5)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(2, (dailyList.width - Style.space(120))
                 * (Number(modelData.cost) || 0) / dailyList.peak)
          height: Style.space(4)
          radius: height / 2
          color: root.accent
          opacity: 0.75
        }

        Text {
          text: root.money(modelData.cost)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
