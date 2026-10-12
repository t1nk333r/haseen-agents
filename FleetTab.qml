import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "FleetModel.js" as Model

// Fleet tab — read-only Herdr agent state and OMP usage across the connector
// fleet (t1nk33r.fleet-shepherd until plan 128). The snapshot, its cache and the
// focus helper are its parent's, unchanged; the layout is the approved
// two-column one:
//   left rail  — which sub-view, the fleet totals, the filter (bounded)
//   right pane — the connector list, which owns its own scroll
//
// Keys: j/k move the rail's sub-view chips, Ctrl+j/Ctrl+k (or h/l, PgUp/PgDn)
// move the connector cursor, Enter focuses the connector under the cursor,
// `/` or any printable starts the filter, Esc clears it.
Item {
  id: root

  property var fleet: null

  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  readonly property int railWidth: Style.space(268)
  readonly property int paneGap: Style.space(18)

  // ---------------------------------------------------------------- state
  // Agents is the view the owner opens this tab for: it is the only one that
  // lists every agent per connector untruncated. Overview is still there, last
  // in the chip strip, for the summary shape.
  property string view: "agents"
  property string filterText: ""
  // One cursor model for keyboard and mouse alike: rows paint from
  // `hasCursor`, never from containsMouse, so exactly one row is highlighted
  // however the user is driving the panel (CursorSurface contract).
  property int cursorIndex: -1
  property bool cursorActive: false

  readonly property int maxAgentRows: root.fleet ? root.fleet.intSetting("fleetMaxAgentRows", 3, 1, 12) : 3

  readonly property var visibleConnectors: Model.filterConnectors(
    root.fleet ? root.fleet.connectors : [], filterText, view)
  readonly property bool filterHasFocus: filterField.activeFocus
  readonly property real implicitContentHeight: Math.max(rail.implicitHeight, paneColumn.implicitHeight)

  readonly property var views: [
    { value: "agents", label: "Agents" },
    { value: "attention", label: "Attention" },
    { value: "usage", label: "Usage" },
    { value: "overview", label: "Overview" }
  ]

  // Agents listed per connector. Attention and Agents are the views you open
  // *to* read agents, so they are not truncated; Overview keeps its summary
  // shape at the user's row budget.
  readonly property int agentLimit: (view === "attention" || view === "agents") ? 12 : root.maxAgentRows

  readonly property var summaryCells: root.fleet ? [
    { value: root.fleet.summary.online + "/" + root.fleet.summary.connectors, label: "connectors", alarm: root.fleet.allOffline },
    { value: String(root.fleet.summary.working), label: "working", alarm: false },
    { value: String(root.fleet.summary.blocked), label: "blocked", alarm: root.fleet.summary.blocked > 0 },
    { value: Model.compact(root.fleet.summary.requests), label: "requests", alarm: false },
    { value: Model.money(root.fleet.summary.cost), label: "cost", alarm: false }
  ] : []

  readonly property string emptyText: {
    if (filterText !== "") return "No fleet result matches this filter"
    if (view === "attention") return "Nothing needs attention"
    if (view === "agents") return "No agents visible"
    if (view === "usage") return "No usage data"
    return root.fleet && root.fleet.summary.connectors === 0 ? "No connectors configured" : "No connectors reporting"
  }

  // -------------------------------------------------------- shared hero face
  readonly property string heroTitle: "Fleet"
  readonly property string heroMeta: root.fleet ? root.fleet.heroMeta : ""
  readonly property string heroDetail: root.fleet ? root.fleet.heroDetail : ""
  readonly property Component heroIcon: Component {
    OpticalGlyph {
      text: "󰳆"
      width: Style.font.display
      height: Style.font.display
      color: root.fleet && root.fleet.summary.blocked > 0 ? root.urgent : root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.display
    }
  }

  // ------------------------------------------------------------- actions
  function refresh() { if (root.fleet) root.fleet.refresh(true) }
  function activate() {
    var connector = root.currentConnector()
    if (connector) root.fleet.focusConnector(connector)
    else root.refresh()
  }
  // j/k: the rail's sub-view chips.
  function moveRail(delta) { if (delta !== 0) root.cycleView(delta) }
  // Ctrl+j/Ctrl+k, h/l, PgUp/PgDn: the connector cursor.
  function movePane(delta) { if (delta !== 0) root.moveCursor(delta) }

  function currentConnector() {
    var list = root.visibleConnectors
    return root.cursorIndex >= 0 && root.cursorIndex < list.length ? list[root.cursorIndex] : null
  }

  function setView(next) {
    if (root.view === next) return
    root.view = next
    root.cursorIndex = -1
  }

  function cycleView(delta) {
    var i = 0
    for (var v = 0; v < root.views.length; v++) if (root.views[v].value === root.view) i = v
    root.setView(root.views[((i + delta) % root.views.length + root.views.length) % root.views.length].value)
  }

  function moveCursor(delta) {
    var n = root.visibleConnectors.length
    if (n === 0) return
    if (!root.cursorActive) { root.cursorActive = true; if (root.cursorIndex >= 0) return }
    var i = root.cursorIndex
    if (i < 0) i = delta > 0 ? 0 : n - 1
    else i = ((i + delta) % n + n) % n
    root.cursorIndex = i
  }

  // The filter is this panel's one inline editor, so it is also the one place
  // PanelKeyCatcher hands keys straight to a descendant (`blocked`). Until
  // then the catcher owns every key, which is why j/k are the rail and any
  // *other* printable character starts filtering with that character typed.
  function beginFilter(seed) {
    if (seed !== undefined && seed !== "") filterField.text = filterField.text + seed
    filterField.forceActiveFocus()
    filterField.cursorPosition = filterField.text.length
  }

  function clearFilter() {
    filterField.text = ""
    root.filterText = ""
    root.cursorIndex = -1
  }

  Row {
    id: columns
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: root.paneGap

    // ====================================================== LEFT RAIL (fixed)
    Column {
      id: rail
      width: root.railWidth
      spacing: Style.space(10)

      PanelSeparator { foreground: root.foreground }

      PanelSectionHeader {
        width: parent.width
        text: "VIEW"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      RailList {
        width: parent.width
        options: root.views
        value: root.view
        cursorIndex: -1
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onChanged: function(value) { root.setView(value) }
      }

      PanelSeparator { foreground: root.foreground }

      PanelSectionHeader {
        width: parent.width
        text: "FLEET"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Repeater {
        model: root.summaryCells

        delegate: Item {
          required property var modelData
          width: rail.width
          implicitHeight: Math.max(fleetValue.implicitHeight, fleetLabel.implicitHeight)

          Text {
            id: fleetValue
            textFormat: Text.PlainText
            text: modelData.value
            color: modelData.alarm ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: fleetLabel
            textFormat: Text.PlainText
            text: modelData.label.toUpperCase()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      TextField {
        id: filterField
        width: parent.width
        foreground: root.foreground
        accent: root.accent
        verticalPadding: Style.spacing.controlPaddingY
        // Shown whenever the field is empty, focused or not.
        placeholderText: "/ to filter…"
        onTextChanged: {
          root.filterText = text
          root.cursorIndex = -1
        }
        onAccepted: root.activate()
        Keys.onEscapePressed: function(event) {
          event.accepted = true
          if (filterField.text !== "") root.clearFilter()
        }
        Keys.onUpPressed: function(event) { event.accepted = true; root.moveCursor(-1) }
        Keys.onDownPressed: function(event) { event.accepted = true; root.moveCursor(1) }
        // PanelKeyCatcher is `blocked` while this field has focus, so its Ctrl+R
        // never fires here. Modifier chords have to keep working inside a text
        // box, so this one key is forwarded back out. Bare "r" belongs to the text.
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
            event.accepted = true
            root.refresh()
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.fleet && root.fleet.focusNote !== ""
        width: parent.width
        text: root.fleet ? root.fleet.focusNote : ""
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        visible: root.fleet && root.fleet.errorText !== "" && root.visibleConnectors.length === 0
        width: parent.width
        text: root.fleet ? root.fleet.errorText : ""
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    // =============================================== RIGHT PANE (owns scroll)
    Column {
      id: paneColumn
      width: columns.width - root.railWidth - root.paneGap
      spacing: Style.spacing.lg

      // ListView, not a Column in a Flickable: it owns the scroll position, so
      // it keeps the cursor row visible on j/k, re-clamps itself when a filter
      // shortens the list, and — because Contain only moves when a row is
      // actually clipped — never lurches under a hovering mouse.
      ListView {
        id: connectorList
        visible: root.visibleConnectors.length > 0
        width: parent.width
        height: Math.min(contentHeight, Style.space(430))
        spacing: Style.spacing.lg
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        model: root.visibleConnectors
        currentIndex: root.cursorIndex
        // Deferred a turn: the model is rebuilt on every snapshot and every
        // filter keystroke, and swapping the model resets the view out from
        // under an immediate call.
        onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
        function keepCurrentVisible() {
          if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
        }

        delegate: CursorSurface {
          id: connectorRow
          required property var modelData
          required property int index

          readonly property int shownAgents: root.view === "usage"
            ? 0 : Math.min(modelData.agents.length, root.agentLimit)
          readonly property int shownModels: root.view === "usage"
            ? Math.min(modelData.models.length, 3) : 0
          readonly property int hiddenCount: root.view === "usage"
            ? Math.max(0, modelData.models.length - shownModels)
            : Math.max(0, modelData.agents.length - shownAgents)

          width: ListView.view.width
          implicitHeight: rowColumn.implicitHeight + Style.spacing.xl
          height: implicitHeight
          hasCursor: root.cursorActive && root.cursorIndex === connectorRow.index
          foreground: root.foreground
          accent: root.accent

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) {
              root.cursorActive = true
              root.cursorIndex = connectorRow.index
            }
            onClicked: root.fleet.focusConnector(connectorRow.modelData)
          }

          Column {
            id: rowColumn
            x: Style.spacing.xl
            y: Style.spacing.xl / 2
            width: parent.width - Style.spacing.xl * 2
            spacing: Style.spacing.xs

            // Connector headline: health dot · label ........ usage
            Item {
              width: parent.width
              implicitHeight: Math.max(connectorName.implicitHeight, connectorUsage.implicitHeight)

              Rectangle {
                id: healthDot
                width: Style.space(8)
                height: width
                radius: width / 2
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                color: root.fleet.stateColor(connectorRow.modelData.health)
              }

              Text {
                id: connectorName
                textFormat: Text.PlainText
                anchors.left: healthDot.right
                anchors.leftMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - healthDot.width - Style.spacing.lg
                  - connectorUsage.implicitWidth - Style.spacing.xxl)
                text: connectorRow.modelData.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                id: connectorUsage
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: Model.compact(connectorRow.modelData.overall.requests) + " req · "
                  + Model.money(connectorRow.modelData.overall.cost)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              textFormat: Text.PlainText
              x: healthDot.width + Style.spacing.lg
              width: parent.width - x
              text: (connectorRow.modelData.herdrIdle ? "herdr idle" : connectorRow.modelData.health)
                + (connectorRow.modelData.health === "offline"
                  ? "" : " · " + Math.round(connectorRow.modelData.latencyMs) + "ms")
                + (root.view === "usage"
                  ? "" : " · " + connectorRow.modelData.agents.length + " agents")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            // Agent rows. Each is an Item, not a bare Row: Qt rejects fill
            // anchors on a direct child of a positioner, so a MouseArea anchored
            // inside the Row would lose its size and the click target would be
            // dead.
            Repeater {
              model: connectorRow.modelData.agents.slice(0, connectorRow.shownAgents)

              delegate: Item {
                required property var modelData
                width: rowColumn.width
                implicitHeight: agentLabels.implicitHeight + Style.spacing.sm
                height: implicitHeight

                Rectangle {
                  id: agentTick
                  width: Style.space(3)
                  height: agentLabels.implicitHeight
                  radius: width / 2
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.fleet.stateColor(modelData.status)
                }

                Column {
                  id: agentLabels
                  anchors.left: agentTick.right
                  anchors.leftMargin: Style.spacing.lg
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xxs

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: modelData.agent + " · " + modelData.status
                    color: modelData.status === "blocked" ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: text !== ""
                    width: parent.width
                    text: modelData.activity || modelData.cwd
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.fleet.focusConnector(connectorRow.modelData)
                }
              }
            }

            // Per-model usage rows (Usage view only).
            Repeater {
              model: connectorRow.modelData.models.slice(0, connectorRow.shownModels)

              delegate: Item {
                required property var modelData
                width: rowColumn.width
                implicitHeight: Math.max(modelName.implicitHeight, modelUsage.implicitHeight) + Style.spacing.sm
                height: implicitHeight

                Text {
                  id: modelName
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(0, parent.width - modelUsage.implicitWidth - Style.spacing.xxl)
                  text: modelData.model + (modelData.provider ? " · " + modelData.provider : "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Text {
                  id: modelUsage
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.compact(modelData.requests) + " req · " + Model.money(modelData.cost)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: connectorRow.hiddenCount > 0
              width: parent.width
              text: "+" + connectorRow.hiddenCount + " more "
                + (root.view === "usage" ? "models" : "agents")
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              visible: connectorRow.modelData.error !== ""
              width: parent.width
              text: connectorRow.modelData.error
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }

      // ---------- Loading / empty ----------
      Text {
        textFormat: Text.PlainText
        visible: root.fleet && root.fleet.loading && root.visibleConnectors.length === 0 && root.fleet.errorText === ""
        width: parent.width
        text: "Contacting fleet…"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall

        SequentialAnimation on opacity {
          running: parent.visible
          loops: Animation.Infinite
          NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
          NumberAnimation { to: 0.9; duration: 700; easing.type: Easing.InOutSine }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: root.fleet && !root.fleet.loading && root.fleet.errorText === ""
          && root.visibleConnectors.length === 0
        width: parent.width
        text: root.emptyText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }
  }
}
