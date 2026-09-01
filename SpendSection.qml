import QtQuick

// Spend — what the agents actually cost, folded in from t1nk33r.codeburn when
// the three agent-telemetry plugins merged (plan 090).
//
// IMPORTANT: this file imports QtQuick and NOTHING else. A plugin's entry point
// (Panel.qml) gets the qs.* import path injected; its sibling files do not.
// Adding `import qs.Commons` or `import qs.Ui` here makes the whole component
// fail to instantiate SILENTLY — no QML error, no section, and even a plain
// debug rectangle inside it never draws. Verified by bisection: an identical
// probe rendered with only `import QtQuick`, and vanished the moment the qs.*
// imports were added. Keep this file dependency-free; colours, fonts, spacing,
// the header and the buttons all arrive as properties from Panel.qml.
//
// Fetching lives in Panel.qml too — it owns the Process and writes `data` and
// `errorText` here. The script emits {"error": ...} when neither codeburn nor
// npx is installed, rendered as an inline notice: a missing optional dependency
// must not look like a hung section.
Column {
  id: root

  property color foreground: "#ffffff"
  property color dim: "#888888"
  property color accent: "#a6da95"
  property color urgent: "#ed8796"
  property string fontFamily: "monospace"
  property int captionSize: 10
  property int displaySize: 24
  property int gap: 6
  property real cornerRadius: 4

  property string period: "today"
  // NOT named `data`: that is Item's default property, the list that holds an
  // item's children. Declaring `property var data` shadows it, every visual
  // child is assigned into the override instead of the item, and the whole
  // component renders nothing — with no QML error of any kind.
  property var report: null
  property string errorText: ""
  property bool loading: false

  signal periodPicked(string periodId)
  signal refreshRequested()
  function refresh() { root.refreshRequested() }

  readonly property var periods: [
    { id: "today",    label: "Today"    },
    { id: "week",     label: "7 Days"   },
    { id: "30days",   label: "30 Days"  },
    { id: "month",    label: "Month"    },
    { id: "all",      label: "6 Months" },
    { id: "lifetime", label: "Lifetime" }
  ]

  readonly property bool hasData: root.report !== null && root.errorText === ""

  spacing: root.gap

  function money(v) {
    var sym = root.report && root.report.currency ? String(root.report.currency.symbol || "$") : "$"
    var n = Number(v)
    if (!isFinite(n)) return sym + "0.00"
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

  // Section header, matching the panel's others without PanelSectionHeader.
  Text {
    width: root.width
    text: "SPEND"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: root.captionSize
    font.bold: true
    font.letterSpacing: 1
  }

  // Period selector: plain buttons, so the current period reads without a click.
  Flow {
    width: root.width
    spacing: 4

    Repeater {
      model: root.periods
      delegate: Rectangle {
        id: chip
        required property var modelData
        readonly property bool current: root.period === modelData.id
        width: chipLabel.implicitWidth + 14
        height: chipLabel.implicitHeight + 8
        radius: root.cornerRadius
        color: chip.current ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                            : "transparent"
        border.color: chip.current ? root.accent
                     : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
        border.width: 1

        Text {
          id: chipLabel
          anchors.centerIn: parent
          text: chip.modelData.label
          color: chip.current ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: root.captionSize
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.period === chip.modelData.id) return
            root.period = chip.modelData.id
            root.periodPicked(chip.modelData.id)
          }
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
    font.pixelSize: root.captionSize
    wrapMode: Text.WordWrap
  }

  Text {
    width: root.width
    visible: root.loading && !root.hasData && root.errorText === ""
    text: "Loading spend…"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: root.captionSize
  }

  Row {
    width: root.width
    visible: root.hasData
    spacing: 8

    Text {
      anchors.baseline: costSub.baseline
      text: root.report && root.report.current ? root.money(root.report.current.cost) : ""
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: root.displaySize
      font.bold: true
    }

    Text {
      id: costSub
      text: root.report && root.report.current
        ? root.periodLabel(root.period) + "  ·  "
          + root.compact(root.report.current.calls) + " calls  ·  "
          + root.compact(root.report.current.sessions) + " sessions"
        : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: root.captionSize
    }
  }

  // Cache hit rate is the interesting number here: it is what separates the raw
  // token counts from the actual bill.
  Text {
    width: root.width
    visible: root.hasData
    text: {
      if (!root.report || !root.report.current) return ""
      var c = root.report.current
      return "in " + root.compact(c.inputTokens)
           + "  ·  out " + root.compact(c.outputTokens)
           + "  ·  cache read " + root.compact(c.cacheReadTokens)
           + "  ·  hit " + Number(c.cacheHitPercent || 0).toFixed(1) + "%"
    }
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: root.captionSize
    wrapMode: Text.WordWrap
  }

  // Recent daily spend, scaled to the heaviest day — the same scale-to-peak the
  // panel's other charts use.
  Column {
    id: dailyList
    width: root.width
    spacing: 2
    visible: root.hasData && !!root.report.history
             && (root.report.history.daily || []).length > 0

    readonly property var days: root.report && root.report.history
      ? (root.report.history.daily || []).slice(-7) : []
    readonly property real peak: {
      var m = 0
      for (var i = 0; i < days.length; i++) m = Math.max(m, Number(days[i].cost) || 0)
      return m > 0 ? m : 1
    }

    Repeater {
      model: dailyList.days
      delegate: Row {
        id: dayRow
        required property var modelData
        width: dailyList.width
        spacing: 6

        Text {
          width: 44
          text: String(dayRow.modelData.date || "").slice(5)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.captionSize
        }

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(2, (dailyList.width - 110)
                 * (Number(dayRow.modelData.cost) || 0) / dailyList.peak)
          height: 4
          radius: 2
          color: root.accent
          opacity: 0.75
        }

        Text {
          text: root.money(dayRow.modelData.cost)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: root.captionSize
        }
      }
    }
  }
}
