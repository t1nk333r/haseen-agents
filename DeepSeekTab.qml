import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "DeepSeekModel.js" as Model

// DeepSeek tab — the API balance, its availability, the measured usage ledger
// and the peak/off-peak pricing schedule (t1nk33r.deepseek until plan 128).
//
// One calm source of truth: DeepSeekService.qml owns config and polling and this
// tab only mirrors its view, so the bar badge and the tab never disagree. The
// layout is the approved two-column one:
//   left rail  — the balance and the pricing state (bounded)
//   right pane — the measured usage, the recovery flow and the actions (scrolls)
//
// The rail has no chip list (there is nothing to select), so j/k fall back to
// the pane; Ctrl+j/Ctrl+k (or h/l, PgUp/PgDn) scroll it, r refreshes.
Item {
  id: root

  property var deepseek: null

  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  // The panel's own palette, in theme tokens: a good balance is the accent, a
  // failed one is urgent, and an alarm is the dim text rather than a hue the
  // theme never chose.
  readonly property color success: root.accent
  readonly property color danger: root.urgent
  readonly property color warn: root.dim
  property string fontFamily: Style.font.family

  readonly property int railWidth: Style.space(268)
  readonly property int paneGap: Style.space(18)

  readonly property var view: root.deepseek && root.deepseek.view ? root.deepseek.view : Model.initialView()
  readonly property var config: root.deepseek && root.deepseek.config ? root.deepseek.config : Model.defaults()
  readonly property var usage: root.deepseek && root.deepseek.usage
    ? root.deepseek.usage : Model.initialUsage()
  readonly property var usageTodayRow: Model.usageToday(root.usage, Date.now())
  readonly property string usageCurrency: root.deepseek && root.deepseek.view && root.deepseek.view.currency
    ? root.deepseek.view.currency : Model.DEFAULT_CURRENCY
  readonly property string tokenModel: root.deepseek && root.deepseek.tokenModel
    ? root.deepseek.tokenModel : Model.TOKEN_MODEL_DEFAULT
  // Tokens are what the operator asked to see; the money the ledger actually
  // measured stays in the caption, and stands alone when no rate table exists
  // for the account's currency.
  readonly property var usageTodayTokens: Model.usageTokens(
    root.usageTodayRow.spentPeak, root.usageTodayRow.spentOffPeak, root.usageCurrency, root.tokenModel)
  readonly property var usageTotalTokens: Model.usageTokens(
    root.usage.spentPeak, root.usage.spentOffPeak, root.usageCurrency, root.tokenModel)
  readonly property string usageTodayText: root.usageTodayTokens === null
    ? Model.formatAmount(root.usageTodayRow.spent, root.usageCurrency)
    : "\u2248 " + Model.formatTokens(root.usageTodayTokens) + " tokens"
  readonly property string usageTotalText: root.usageTotalTokens === null
    ? Model.formatAmount(root.usage.spent, root.usageCurrency)
    : "\u2248 " + Model.formatTokens(root.usageTotalTokens) + " tokens"
  readonly property bool usageTodayAdded: root.usageTodayRow.added > 0
  readonly property string usageSince: Model.usageSinceText(root.usage)
  readonly property string configPath: deepseek ? (deepseek.configPath || "") : ""
  readonly property string configError: deepseek ? (deepseek.configError || "") : ""
  readonly property url whaleSource: deepseek && deepseek.whaleSource
    ? deepseek.whaleSource : Qt.resolvedUrl("assets/deepseek-offpeak.svg")
  readonly property bool peak: !!(deepseek && deepseek.peak)
  readonly property string pricingStatus: deepseek && deepseek.pricingStatus
    ? deepseek.pricingStatus : ""
  readonly property string pricingCountdown: deepseek && deepseek.pricingCountdown
    ? deepseek.pricingCountdown : ""
  readonly property string pricingFlipLocal: deepseek && deepseek.pricingFlipLocal
    ? deepseek.pricingFlipLocal : ""
  readonly property string pricingClock: deepseek && deepseek.pricingClock
    ? deepseek.pricingClock : "00:00:00"
  readonly property string pricingUntilLabel: deepseek && deepseek.pricingUntilLabel
    ? deepseek.pricingUntilLabel : ""
  readonly property string peakWindowsLabel: deepseek && deepseek.peakWindowsLabel
    ? deepseek.peakWindowsLabel : ""
  readonly property string localNow: deepseek && deepseek.localNow
    ? deepseek.localNow : ""
  readonly property bool hasBalance: Model.hasData(root.view)
  readonly property bool isAvailable: !hasBalance || root.view.isAvailable !== false

  readonly property string statusMeta: root.configError !== ""
    ? "config file needs attention"
    : Model.statusLine(root.view)
  readonly property string statusPill: root.configError !== ""
    ? "CONFIG ERROR"
    : (root.view.status === "ok" ? "LIVE"
      : (root.view.status === "degraded" ? "STALE"
        : (root.view.status === "error" ? "OFFLINE"
          : (root.view.status === "loading" ? "CHECKING"
            : "NO KEY"))))
  readonly property bool alertArmed: Model.alertArmed(root.config)
  readonly property bool balanceLow: Model.isLowBalance(root.view, root.config)

  // A tab with no rail chips still has to scroll: j/k fall back to the pane.
  readonly property bool railHasChips: false

  readonly property real paneViewport: Math.max(rail.implicitHeight,
    Math.min(paneColumn.implicitHeight, Style.space(560)))
  readonly property real implicitContentHeight: Math.max(rail.implicitHeight, root.paneViewport)

  // ------------------------------------------------------- shared hero face
  readonly property string heroTitle: "DeepSeek"
  readonly property string heroMeta: root.statusMeta
  readonly property string heroDetail: root.statusPill
  readonly property Component heroIcon: Component {
    Image {
      width: Style.font.display
      height: width
      source: root.whaleSource
      sourceSize.width: 96
      sourceSize.height: 96
      fillMode: Image.PreserveAspectFit
      smooth: true
    }
  }

  // ------------------------------------------------------------- actions
  function refresh() { if (root.deepseek) root.deepseek.refreshNow() }
  function activate() { root.refresh() }
  function moveRail(delta) { root.movePane(delta) }
  function movePane(delta) {
    pane.contentY = Math.max(0, Math.min(
      pane.contentY + delta * Style.space(56),
      Math.max(0, pane.contentHeight - pane.height)
    ))
  }

  function createConfigFile() {
    if (root.deepseek) root.deepseek.createConfigFile()
  }

  function backupConfigFile() {
    if (root.deepseek) root.deepseek.backupConfigFile()
  }

  function openConfigFile() {
    if (root.deepseek) root.deepseek.openConfigFile()
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
      spacing: Style.space(8)

      Column {
        visible: root.hasBalance
        width: parent.width
        spacing: Style.space(6)

        Column {
          width: parent.width
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: Model.formatAmount(root.view.total, root.view.currency)
            color: root.balanceLow ? root.warn
              : (root.isAvailable ? root.success : root.warn)
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.balanceLow
              ? "below your alert threshold"
              : (root.isAvailable
                ? "current DeepSeek API balance"
                : "balance too low for API calls")
            color: root.balanceLow ? root.warn
              : (root.isAvailable ? root.dim : root.warn)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }

        InfoPair { label: "Granted"; value: Model.formatAmount(root.view.granted, root.view.currency) }
        InfoPair { label: "Topped up"; value: Model.formatAmount(root.view.toppedUp, root.view.currency) }
        InfoPair { label: "Currency"; value: root.view.currency }
        InfoPair {
          label: "API calls"
          value: root.isAvailable ? "available" : "blocked"
          valueColor: root.isAvailable ? root.success : root.warn
        }
        InfoPair { label: "Last checked"; value: Model.formatDateTime(root.view.checkedAt) }
      }

      PanelSeparator { foreground: root.foreground }

      // ---- pricing (merged from the DeepSeek Pricing plugin) --------------
      // Peak windows are defined in UTC; the countdown is the service's own
      // one-second tick, so the tab needs no timer of its own. The clocks are
      // the operator's zone (UTC+3), which is where the badge renders them too.
      PanelSectionHeader {
        width: parent.width
        text: "PRICING"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Item {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.bar.iconCanvas
          height: Style.bar.iconCanvas

          Image {
            anchors.centerIn: parent
            width: Style.space(16)
            height: width
            source: root.whaleSource
            sourceSize.width: 64
            sourceSize.height: 64
            fillMode: Image.PreserveAspectFit
            smooth: true
          }
        }

        Column {
          width: parent.width - Style.bar.iconCanvas - Style.space(8)
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.pricingStatus
            color: root.peak ? root.danger : root.success
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "next change " + root.pricingFlipLocal
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.pricingClock
          color: root.peak ? root.danger : root.success
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          font.bold: true
          font.letterSpacing: 2
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.pricingUntilLabel
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.5
          horizontalAlignment: Text.AlignHCenter
        }
      }

      InfoPair { label: "Next change"; value: root.pricingFlipLocal }
      InfoPair { label: "Now (UTC+3)"; value: root.localNow }
      InfoPair {
        label: "Peak windows"
        value: root.peakWindowsLabel
      }
      InfoPair {
        label: "Alert threshold"
        value: Model.alertStatusText(root.config, root.view)
        valueColor: root.balanceLow ? root.warn
          : (Model.alertArmed(root.config) ? root.success : root.dim)
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
        spacing: Style.space(10)

        // ---- usage (measured, not reported) --------------------------------
        // The API has no usage endpoint, so these figures come from the
        // balance moving between polls: a drop is usage, a rise is money
        // added. The caption says so, because a "total" that starts when
        // the widget did is not the platform's lifetime figure.
        Column {
          visible: root.hasBalance
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            width: parent.width
            text: "USAGE (MEASURED, NOT REPORTED)"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          InfoPair { label: "Daily usage"; value: root.usageTodayText }
          InfoPair {
            label: "Total usage"
            value: root.usageSince === ""
              ? root.usageTotalText
              : root.usageTotalText + "  \u00b7  since " + root.usageSince
          }
          InfoPair {
            label: "Added today"
            value: Model.formatAmount(root.usageTodayRow.added, root.usageCurrency)
            valueColor: root.usageTodayAdded ? root.success : root.dim
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.balanceLow
          width: parent.width
          text: "Balance is below the alert threshold \u2014 top up or lower the threshold in the config."
          color: root.warn
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }

        // loading (no data yet)
        Column {
          visible: !root.hasBalance && root.view.status === "loading"
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Checking balance\u2026"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "DeepSpend asks DeepSeek for your current balance."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }

        // no key configured
        Column {
          visible: !root.hasBalance && root.view.status === "nokey" && root.configError === ""
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "DeepSpend needs your DeepSeek API key."
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "1. Put your key in"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.configPath
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "as \u201capiKey\u201d:  { \u201capiKey\u201d: \u201csk-\u2026\u201d }"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "2. Save the file (mode 600) \u2014 the widget updates automatically."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Button {
            width: parent.width
            text: "Create config file"
            iconText: "\uf044"
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: true
            onClicked: root.createConfigFile()
          }
        }

        // config file invalid (DS-5): clear problem + safe repair actions.
        Column {
          visible: root.configError !== ""
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Config file needs attention"
            color: root.warn
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.configError
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.configPath
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Nothing is lost \u2014 DeepSpend keeps your current file as a backup before it creates a fresh one."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Button {
            width: parent.width
            text: "Back up & create default"
            iconText: "\uf0c5"
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: true
            onClicked: root.backupConfigFile()
          }

          Button {
            width: parent.width
            text: "Open config file"
            iconText: "\uf044"
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: true
            onClicked: root.openConfigFile()
          }
        }

        // error without usable data
        Column {
          visible: !root.hasBalance && root.view.status === "error" && root.configError === ""
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.view.errorMessage
            color: root.danger
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Check the key in " + root.configPath + " or try again."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }

        // warning when the latest check failed (stale data shown)
        Column {
          visible: root.hasBalance && root.view.status === "degraded"
          width: parent.width
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Last check failed: " + root.view.errorMessage
            color: root.warn
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- actions ------------------------------------------------------
        Button {
          width: parent.width
          text: "Refresh now"
          iconText: "\uf021"
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: true
          onClicked: root.refresh()
        }

        Button {
          width: parent.width
          text: "Open DeepSeek platform"
          iconText: "\uf08e"
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: true
          onClicked: Qt.openUrlExternally("https://platform.deepseek.com")
        }

        // The exact figures the estimate approximates live here and nowhere a
        // key can reach, so the one honest answer to "how many tokens really?"
        // is one click away.
        Button {
          width: parent.width
          text: "Open usage on the platform"
          iconText: "\uf201"
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: true
          onClicked: Qt.openUrlExternally("https://platform.deepseek.com/usage")
        }
      }
    }
  }

  // Row helper: small label on the left, value on the right.
  component InfoPair: RowLayout {
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Layout.alignment: Qt.AlignVCenter
    }

    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
  }
}
