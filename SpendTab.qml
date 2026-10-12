import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Spend tab — what the AI CLIs have cost, per period, from the `codeburn` npm
// tool (t1nk33r.codeburn until plan 128). The numbers, the period set, the
// enrichment join and the local-currency conversion are its parent's; the
// layout is the approved two-column one:
//   left rail  — which period, and that period's totals (bounded)
//   right pane — providers, models and activities, or the error card (scrolls)
//
// Keys: j/k move the rail's period chips, Ctrl+j/Ctrl+k (or h/l, PgUp/PgDn)
// scroll the pane, Enter or r refreshes.
Item {
  id: root

  property var spend: null

  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color subtleText: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.60)
  property string fontFamily: Style.font.family

  readonly property int railWidth: Style.space(268)
  readonly property int paneGap: Style.space(18)

  readonly property bool online: root.spend ? root.spend.isOnline : false

  readonly property real paneViewport: Math.max(rail.implicitHeight,
    Math.min(paneColumn.implicitHeight, Style.space(560)))
  readonly property real implicitContentHeight: Math.max(rail.implicitHeight, root.paneViewport)

  readonly property string periodLabel: root.spend
    ? (root.spend.current && root.spend.current.label
      ? String(root.spend.current.label).toUpperCase()
      : String(root.spend.selectedPeriodLabel).toUpperCase())
    : ""

  // What the empty-period card says: how much was used without being billed,
  // and what the OMP exclusion took off when it did.
  readonly property string emptyNote: {
    if (!root.spend) return ""
    var s = root.spend
    var lead = s.calls > 0
      ? s.formatNumber(s.calls) + " calls, none of them billed."
      : (s.ompExcluded ? "Nothing outside OMP was used." : "Nothing was recorded.")
    if (!s.ompExcluded || !s.ompExcludedTotals) return lead
    return lead + "\nOMP is left out (Spend: leave OMP out is on): "
      + s.formatCost(s.ompExcludedTotals.cost) + " at API rates over "
      + s.formatNumber(s.ompExcludedTotals.calls) + " calls."
  }

  // -------------------------------------------------------- shared hero face
  readonly property string heroTitle: "Spend"
  readonly property string heroMeta: root.online ? root.periodLabel : "STATUS"
  readonly property string heroDetail: root.online ? root.spend.formatCost(root.spend.cost) : "Offline"
  readonly property Component heroIcon: Component {
    OpticalGlyph {
      text: "󰈸"
      width: Style.font.display
      height: Style.font.display
      color: root.online ? root.accent : root.dim
      fontFamily: root.fontFamily
      fontSize: Style.font.display
    }
  }

  // ------------------------------------------------------------- actions
  function refresh() { if (root.spend) root.spend.refresh() }
  function activate() { root.refresh() }
  // j/k: the rail's period chips.
  function moveRail(delta) { if (root.spend && delta !== 0) root.spend.cyclePeriod(delta > 0 ? 1 : -1) }
  // Ctrl+j/Ctrl+k, h/l, PgUp/PgDn: the pane.
  function movePane(delta) {
    pane.contentY = Math.max(0, Math.min(
      pane.contentY + delta * Style.space(60),
      Math.max(0, pane.contentHeight - pane.height)
    ))
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
        text: "PERIOD"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      RailList {
        width: parent.width
        options: root.spend ? root.spend.periods : []
        value: root.spend ? root.spend.selectedPeriod : ""
        cursorIndex: -1
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onChanged: function(value) { if (root.spend) root.spend.selectPeriod(value) }
      }

      PanelSeparator { foreground: root.foreground }

      PanelSectionHeader {
        width: parent.width
        text: root.periodLabel + " OVERVIEW"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Repeater {
        model: root.online ? [
          { label: "Cost", value: root.spend.formatCost(root.spend.cost) },
          { label: "Calls", value: root.spend.formatNumber(root.spend.calls) },
          { label: "Sessions", value: root.spend.formatNumber(root.spend.sessions) },
          { label: "Cache hit", value: root.spend.periodEmpty ? "\u2014"
            : (root.spend.cacheHitPercent > 0
              ? (root.spend.cacheHitPercent.toFixed(1) + "%") : "0%") }
        ] : []

        delegate: Item {
          required property var modelData
          width: rail.width
          implicitHeight: Math.max(cellValue.implicitHeight, cellLabel.implicitHeight)

          Text {
            id: cellValue
            textFormat: Text.PlainText
            text: modelData.value
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: cellLabel
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

      // Secondary token-counts strip: in / out / cache for the period.
      Text {
        textFormat: Text.PlainText
        visible: root.online
        width: parent.width
        text: "In " + (root.spend ? root.spend.formatTokens(root.spend.inputTokens) : "")
          + " · Out " + (root.spend ? root.spend.formatTokens(root.spend.outputTokens) : "")
          + "\nCache " + (root.spend ? root.spend.formatTokens(root.spend.cacheReadTokens) : "")
        color: root.subtleText
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        lineHeight: 1.2
      }

      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        width: parent.width
        text: root.spend && root.spend.lastUpdatedMs > 0
          ? "Updated " + root.spend.timeAgo(root.spend.lastUpdatedMs) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // =============================================== RIGHT PANE (scrolls)
    Flickable {
      id: pane
      width: columns.width - root.railWidth - root.paneGap
      height: root.paneViewport
      contentWidth: width
      contentHeight: paneColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: paneColumn
        width: pane.width
        spacing: Style.space(12)

        // ------------------------------------------------------- ERROR CARD
        BorderSurface {
          id: errorCard
          visible: !root.online
          width: parent.width
          implicitHeight: errorColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Style.selectedFillFor(root.urgent, root.urgent)
          borderSpec: Border.controlSpec("normal", root.urgent, root.urgent)

          Column {
            id: errorColumn
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            spacing: Style.space(8)

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(8)

              Item {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.font.subtitle
                height: Style.font.subtitle

                OpticalGlyph {
                  text: "󰅙"
                  anchors.fill: parent
                  color: root.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.subtitle
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "CodeBurn status unavailable"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.spend && root.spend.errorMessage !== ""
                ? root.spend.errorMessage
                : "Unable to query CodeBurn via local CLI, npx, or bunx."
              color: root.subtleText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            BorderSurface {
              anchors.horizontalCenter: parent.horizontalCenter
              implicitWidth: codeHint.implicitWidth + Style.space(16)
              implicitHeight: codeHint.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
              borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

              Text {
                id: codeHint
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "Pinned CodeBurn fallback"
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
        }

        // ----------------------------------------------------- EMPTY PERIOD
        //
        // Nothing was spent outside OMP in this period. Say so, and say what the
        // exclusion took off, so a quiet period does not read as a broken tab.
        BorderSurface {
          id: emptyCard
          visible: root.online && !!root.spend && root.spend.periodEmpty
          width: parent.width
          implicitHeight: emptyColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

          Column {
            id: emptyColumn
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            spacing: Style.space(8)

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(8)

              Item {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.font.subtitle
                height: Style.font.subtitle

                OpticalGlyph {
                  text: "\uf05a"  // nf-fa-info_circle
                  anchors.fill: parent
                  color: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.subtitle
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "No spend in this period"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.emptyNote
              color: root.subtleText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }
        }

        // ---------------------------------------------------------- PROVIDERS
        Column {
          visible: root.online && !!root.spend && !root.spend.periodEmpty && root.spend.providerDetails.length > 0
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "PROVIDERS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.spend ? root.spend.providerDetails : []

            Item {
              required property var modelData
              required property int index
              width: parent ? parent.width : 0
              implicitHeight: Style.space(32)

              BorderSurface {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
                borderSpec: Border.none()

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.font.body
                    height: Style.font.body

                    OpticalGlyph {
                      text: "󰌹"
                      anchors.fill: parent
                      color: root.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.body
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(modelData.label || modelData.id || "Provider")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.spend.formatCost(modelData.cost)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
            }
          }
        }

        // --------------------------------------------------------- TOP MODELS
        PanelSeparator {
          visible: root.online && !!root.spend && (!root.spend.periodEmpty || root.spend.calls > 0) && root.spend.topModels.length > 0
          foreground: root.foreground
        }

        Column {
          visible: root.online && !!root.spend && (!root.spend.periodEmpty || root.spend.calls > 0) && root.spend.topModels.length > 0
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "TOP MODELS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.spend ? root.spend.topModelRows : []

            ModelRow {
              width: parent ? parent.width : 0
              modelItem: modelData
              totalCost: root.spend ? root.spend.cost : 0
              tokenRow: root.spend ? root.spend.tokenRowFor(modelData.name) : null
              maxTokens: root.spend ? root.spend.topModelMaxTokens : 0
            }
          }
        }

        // ------------------------------------------------- TOP ACTIVITIES
        PanelSeparator {
          visible: root.online && !!root.spend && !root.spend.periodEmpty && root.spend.topActivities.length > 0
          foreground: root.foreground
        }

        Column {
          visible: root.online && !!root.spend && !root.spend.periodEmpty && root.spend.topActivities.length > 0
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "TOP ACTIVITIES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.spend ? root.spend.topActivities.slice(0, 4) : []

            Item {
              required property var modelData
              required property int index
              width: parent ? parent.width : 0
              implicitHeight: Style.space(26)

              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: String(modelData.name || "Activity")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  textFormat: Text.PlainText
                  visible: modelData.turns !== undefined && modelData.turns !== null
                  text: "(" + modelData.turns + " turns)"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                text: root.spend.formatCost(modelData.cost)
                color: Number(modelData.cost) > 0 ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: Number(modelData.cost) > 0
              }
            }
          }
        }

        // ------------------------------------------------------------- FOOTER
        PanelSeparator {
          visible: root.online
          foreground: root.foreground
        }

        Text {
          textFormat: Text.PlainText
          visible: root.online
          width: parent.width
          text: "[j/k] Period  ·  [r] Refresh"
            + (root.spend && root.spend.ompExcluded && !root.spend.periodEmpty ? "  ·  OMP excluded" : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component ModelRow: Column {
    id: mRow
    property var modelItem: ({})
    property real totalCost: 1.0
    property var tokenRow: null
    property real maxTokens: 0

    readonly property real itemCost: Number(modelItem.cost || 0)
    readonly property real ratio: totalCost > 0 ? Math.min(1.0, Math.max(0.0, itemCost / totalCost)) : 0
    readonly property real tokenCount: tokenRow ? Number(tokenRow.totalTokens || 0) : 0
    // Tokens first, spend second: over a period where cache reads dominate, the
    // two disagree about which model actually did the work.
    readonly property real barRatio: (tokenRow && maxTokens > 0)
      ? Math.min(1.0, Math.max(0.0, tokenCount / maxTokens)) : ratio

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: modelLines.implicitHeight

      Column {
        id: modelLines
        width: parent.width
        spacing: Style.space(1)

        Item {
          width: parent.width
          implicitHeight: Style.space(18)

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: String(modelItem.name || "Model")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: itemCost > 0
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.spend.formatCost(itemCost)
            color: itemCost > 0 ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        // calls · tokens, and the same price again in the local currency.
        Item {
          width: parent.width
          implicitHeight: Style.space(14)

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: (modelItem.calls !== undefined && modelItem.calls !== null
                ? root.spend.formatNumber(modelItem.calls) + " calls" : "")
              + (mRow.tokenRow ? " · " + root.spend.formatTokens(mRow.tokenCount) + " tokens" : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: root.spend.formatLocalCost(itemCost)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // Distribution across the models on screen, by tokens moved: the busiest
    // model fills its bar and the rest are read against it.
    Rectangle {
      width: parent.width
      height: Style.space(4)
      radius: Style.cornerRadius
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

      Rectangle {
        width: Math.max(0, parent.width * mRow.barRatio)
        height: parent.height
        radius: Style.cornerRadius
        color: root.accent
        opacity: 0.85
      }
    }
  }
}
