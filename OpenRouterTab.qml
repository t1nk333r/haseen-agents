import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "OpenRouterModel.js" as Model

// OpenRouter tab — remaining credit, the key's spend cap, and spend today /
// this week / this month / all time, plus the one inline editor this tab has:
// the API key field.
//
// OpenRouterService.qml owns the poll and the view; this tab only mirrors it,
// so the bar badge and the tab never disagree. The layout is the approved
// two-column one:
//   left rail  — the balance, its meter and where the key came from (bounded)
//   right pane — spend, the key cap, the key form, the actions (scrolls)
//
// The rail has no chip list, so j/k fall back to the pane, as on DeepSeek.
// While the key field has focus every keystroke belongs to it: the panel
// blocks its key catcher on `keyFieldFocused`, Esc cancels the edit instead of
// closing the panel, and `releaseKeyFocus` hands the keys back.
//
// Wording and layout borrow from SpoilHeap/Omarchy.OpenRouter @ b443c42 (MIT,
// Panel.qml): the source line under the figure, the management-key note and
// the action set.
Item {
  id: root

  property var openrouter: null
  property double nowMs: Date.now()

  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  // Theme tokens only: a good balance is the accent, a failure is urgent, a
  // low or stale figure is the dim text.
  readonly property color success: root.accent
  readonly property color danger: root.urgent
  readonly property color warn: root.dim
  readonly property color track: Style.selectedFillFor(foreground, root.accent)
  property string fontFamily: Style.font.family

  readonly property int railWidth: Style.space(268)
  readonly property int paneGap: Style.space(18)

  signal releaseKeyFocus()

  readonly property var view: root.openrouter && root.openrouter.view ? root.openrouter.view : Model.initialView()
  readonly property var d: root.view.data
  readonly property bool hasData: Model.hasData(root.view)
  readonly property bool saving: !!(root.openrouter && root.openrouter.saving)
  readonly property string saveError: root.openrouter ? String(root.openrouter.saveError || "") : ""
  readonly property string keySource: String(root.view.keySource || "")
  readonly property bool keyFromEnv: Model.keyFromEnv(root.keySource)
  readonly property string home: root.openrouter ? root.openrouter.home : ""
  readonly property string keyFilePath: root.openrouter ? root.openrouter.keyFilePath : ""
  readonly property bool balanceLow: !!(root.openrouter && root.openrouter.balanceLow)
  readonly property real lowBalance: root.openrouter ? Number(root.openrouter.lowBalance) : 5
  readonly property bool stale: root.view.status === "stale"

  readonly property bool remainingKnown: root.hasData && Model.known(root.d.remaining)
  readonly property var meter: Model.meter(root.d)
  readonly property var spendRows: Model.spendRows(root.d)
  readonly property string spendScope: Model.spendScope(root.spendRows)
  readonly property string spendCaption: root.hasData ? Model.spendCaption(root.d.spendTodaySince) : ""
  readonly property bool hasCap: root.hasData && Model.known(root.d.keyLimit)
  readonly property var accountNote: Model.accountNote(root.d)
  // A key was just saved and its first check is running.
  readonly property bool savedChecking: !!(root.openrouter && root.openrouter.justSaved && root.openrouter.refreshing)
  // A failure with a key source known: the key is the likely fix, so Replace
  // leads the actions; a rejected key also hides the top-up/activity links.
  readonly property bool recoveryFirst: Model.recoveryFirst(root.view)
  readonly property bool keyRejected: Model.keyRejected(root.view)

  readonly property string headlineText: {
    if (!root.hasData) return "\u2014"
    if (root.remainingKnown) return Model.money(root.d.remaining)
    return Model.money(root.d.keyUsage)
  }
  readonly property string headlineCaption: {
    if (!root.hasData) return ""
    var meta = Model.sourceMeta(root.d.source, root.d.freeTier)
    if (!root.remainingKnown) meta += " \u00b7 spent by this key, all time"
    else if (root.balanceLow) meta += " \u00b7 low"
    return root.stale ? meta + " \u00b7 stale" : meta
  }
  // One colour for "look at this": stale and low (an overdrawn balance is
  // low too) are the dim warn, everywhere the balance is drawn.
  readonly property bool balanceWarn: root.stale || root.balanceLow
  readonly property color headlineColor: {
    if (!root.hasData) return root.dim
    if (root.balanceWarn) return root.warn
    return root.remainingKnown ? root.success : root.foreground
  }

  // ---- key form ------------------------------------------------------------
  // With no key the form is the tab; a key that exists is replaced on demand.
  property bool keyEditing: false
  readonly property bool formVisible: root.keyEditing || root.view.status === "nokey"
  readonly property bool keyFieldFocused: keyField.activeFocus
  readonly property string keyFormHint: {
    if (root.saveError !== "") return root.saveError
    if (root.keyFromEnv)
      return "$" + root.keySource + " is set and takes precedence over the key file, so a key saved here is not used until it is unset."
    return "Stored in " + Model.keySourceText(root.keyFilePath, root.home)
      + ", readable only by you. $OPENROUTER_API_KEY or $OPENROUTER_KEY, when set, takes precedence."
  }
  // Only a save failure is an error; the env-var precedence note is
  // information, so it stays dim.
  readonly property bool keyFormHintIsError: root.saveError !== ""

  // A tab with no rail chips still has to scroll: j/k fall back to the pane.
  readonly property real paneViewport: Math.max(rail.implicitHeight,
    Math.min(paneColumn.implicitHeight, Style.space(560)))
  readonly property real implicitContentHeight: Math.max(rail.implicitHeight, root.paneViewport)

  // ------------------------------------------------------- shared hero face
  readonly property string heroTitle: "OpenRouter"
  readonly property string heroMeta: Model.statusMeta(root.view, root.nowMs)
  readonly property string heroDetail: Model.statusPill(root.view)
  readonly property Component heroIcon: Component {
    OpticalGlyph {
      text: "\uf09d"
      width: Style.font.display
      height: Style.font.display
      color: root.view.status === "live" ? (root.balanceLow ? root.warn : root.accent)
        : (Model.failed(root.view) ? root.urgent : root.dim)
      fontFamily: root.fontFamily
      fontSize: Style.font.display
    }
  }

  // ------------------------------------------------------------- actions
  function refresh() { if (root.openrouter) root.openrouter.refreshNow() }
  // Enter: the key form when it is up or when a failure points at the key;
  // otherwise a refresh.
  function activate() {
    if (root.formVisible) root.focusKeyField()
    else if (Model.failed(root.view)) root.startKeyEdit()
    else root.refresh()
  }
  function moveRail(delta) { root.movePane(delta) }
  function movePane(delta) {
    pane.contentY = Math.max(0, Math.min(
      pane.contentY + delta * Style.space(56),
      Math.max(0, pane.contentHeight - pane.height)
    ))
  }

  function focusKeyField() {
    if (!root.formVisible) return
    keyField.forceActiveFocus()
  }

  function startKeyEdit() {
    if (root.openrouter) root.openrouter.clearSaveError()
    keyField.text = ""
    root.keyEditing = true
    Qt.callLater(root.focusKeyField)
  }

  // Esc in the field: an edit is cancelled; the first-run form (which cannot
  // be dismissed) just gives the keys back, so the next Esc closes the panel.
  // Ignored while a save is running: the answer has to land somewhere.
  function cancelKeyEdit() {
    if (root.saving) return
    keyField.text = ""
    if (root.openrouter) root.openrouter.clearSaveError()
    root.keyEditing = false
    root.releaseKeyFocus()
  }

  // Back to the resting state: called by the panel on every opening and
  // closing, and here whenever the tab is switched away from, so a
  // half-typed key (or an old save error) never outlives the view it was
  // typed in, and an edit is only ever open on the tab that shows it.
  function resetForm() {
    keyField.text = ""
    root.keyEditing = false
    if (root.openrouter && !root.saving) root.openrouter.clearSaveError()
  }

  onVisibleChanged: if (!visible) root.resetForm()

  // The field is cleared the moment its text is handed over; the service
  // checks it, writes it to the save helper's stdin and keeps no copy.
  function commitKey() {
    if (root.saving) return
    var typed = keyField.text
    keyField.text = ""
    if (Model.cleanKey(typed) === "") return
    if (root.openrouter) root.openrouter.saveKey(typed)
    typed = ""
  }

  function openUrl(url) {
    Qt.openUrlExternally(url)
  }

  Connections {
    target: root.openrouter
    function onKeySaved() { root.keyEditing = false }
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
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.headlineText
          color: root.headlineColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          font.bold: true
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.hasData ? root.headlineCaption
            : (root.view.status === "nokey" ? "no API key yet"
              : (root.view.status === "offline" ? "no figures \u2014 the last check failed" : "checking OpenRouter\u2026"))
          color: root.view.status === "offline" ? root.danger : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }

      // Remaining, drained toward empty.
      Column {
        visible: root.meter.ratio >= 0
        width: parent.width
        spacing: Style.space(4)

        Item {
          width: parent.width
          implicitHeight: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

          Rectangle {
            id: meterTrack
            anchors.fill: parent
            radius: height / 2
            color: root.track
          }

          Rectangle {
            anchors.left: meterTrack.left
            anchors.verticalCenter: meterTrack.verticalCenter
            height: meterTrack.height
            radius: height / 2
            width: meterTrack.width * Math.max(0, Math.min(1, root.meter.ratio))
            color: root.balanceWarn ? root.warn : root.accent
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: Model.meterPercent(root.meter.ratio) + " " + root.meter.basis
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }

      DetailLine {
        visible: text !== ""
        text: root.hasData ? Model.balanceDetail(root.d.funded, root.d.spent) : ""
      }
      DetailLine {
        visible: text !== ""
        text: root.hasCap ? Model.capDetail(root.d.keyLimit, root.d.keyLimitRemaining, root.d.keyLimitReset) : ""
      }

      PanelSeparator { foreground: root.foreground }

      InfoPair {
        visible: root.hasData
        label: "Key"
        value: root.hasData && root.d.keyLabel !== "" ? root.d.keyLabel : "\u2014"
      }
      InfoPair {
        visible: root.hasData
        label: "Key type"
        value: root.hasData ? Model.keyKindText(root.d.keyKind) : ""
      }
      InfoPair {
        label: "Key from"
        value: Model.keySourceText(root.keySource, root.home)
        valueElide: Text.ElideMiddle
      }
      InfoPair {
        visible: root.hasData
        label: root.stale ? "Last good" : "Updated"
        value: root.hasData ? (Model.relativeAge(root.d.fetchedAt, root.nowMs) || "\u2014") : ""
        valueColor: root.stale ? root.warn : root.foreground
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

        // ---- failure: the reason, the next step, and a way to a new key ----
        Column {
          visible: Model.failed(root.view)
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: (root.view.status === "stale" ? "Last check failed: " : "") + root.view.error
            color: root.view.status === "stale" ? root.warn : root.danger
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: root.view.status !== "stale"
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: root.view.hint
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          // The key is the likely fix, so the way to a new one comes first:
          // Replace when a key source is known, Enter when the helper could
          // not even say where a key comes from.
          Button {
            visible: !root.keyEditing
            width: parent.width
            text: root.keySource === "" ? "Enter API key" : "Replace API key"
            iconText: "\uf084"
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: true
            onClicked: root.startKeyEdit()
          }
        }

        // ---- loading ----------------------------------------------------
        Text {
          textFormat: Text.PlainText
          visible: root.view.status === "loading"
          width: parent.width
          text: root.savedChecking ? "Saved \u2014 checking\u2026" : "Asking OpenRouter for the balance\u2026"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          visible: root.hasData && root.balanceLow
          width: parent.width
          text: "Balance is at or below the alert threshold of " + Model.money(root.lowBalance)
            + " ($5 by default; setting openrouterLowBalance)."
          color: root.warn
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }

        // ---- spend --------------------------------------------------------
        // One scope is said once, in the header; only mixed rows carry a
        // tag each.
        Column {
          visible: root.hasData
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            width: parent.width
            text: root.spendScope === "account" ? "SPEND \u00b7 ACCOUNT"
              : (root.spendScope === "key" ? "SPEND \u00b7 THIS KEY" : "SPEND")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.spendRows

            InfoPair {
              required property var modelData
              label: modelData.label
              value: root.spendScope === "mixed" ? modelData.value + "  \u00b7  " + modelData.tag : modelData.value
              valueColor: root.spendScope === "mixed" && modelData.scope === "key" ? root.dim : root.foreground
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.spendRows.length === 0
            width: parent.width
            text: "OpenRouter reported no spend figures for this key."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            visible: root.spendCaption !== ""
            width: parent.width
            text: root.spendCaption
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }

        // ---- key cap -------------------------------------------------------
        Column {
          visible: root.hasCap
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            width: parent.width
            text: "KEY SPEND CAP"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          InfoPair {
            label: "Cap"
            value: root.hasCap ? Model.money(root.d.keyLimit) : ""
          }
          InfoPair {
            label: "Left"
            value: root.hasCap ? Model.money(root.d.keyLimitRemaining) : ""
            valueColor: root.hasCap && Model.known(root.d.keyLimitRemaining) && root.d.keyLimitRemaining <= 0
              ? root.danger : root.foreground
          }
          InfoPair {
            label: "Resets"
            value: root.hasCap && root.d.keyLimitReset !== "" ? root.d.keyLimitReset : "never"
          }
        }

        // ---- the ledger is unavailable for a reason other than the key kind --
        Text {
          textFormat: Text.PlainText
          visible: root.accountNote.kind === "other"
          width: parent.width
          text: root.accountNote.text
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          textFormat: Text.PlainText
          visible: root.hasData && root.d.freeTier
          width: parent.width
          text: "This key is on the free tier."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }

        // ---- the key form ---------------------------------------------------
        Column {
          id: keyForm
          visible: root.formVisible
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            width: parent.width
            text: root.keySource === "" ? "API KEY" : "REPLACE API KEY"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: keyField
              Layout.fillWidth: true
              // readOnly, not disabled: disabling drops activeFocus, which
              // unblocks the key catcher mid-save.
              readOnly: root.saving
              password: true
              inputMethodHints: Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
              placeholderText: "Enter to type or paste a key"
              foreground: root.foreground
              accent: root.accent
              verticalPadding: Style.spacing.controlPaddingY
              onAccepted: root.commitKey()
              Keys.onEscapePressed: function(event) {
                event.accepted = true
                root.cancelKeyEdit()
              }
              // Tab must not walk Qt focus to another control: the field
              // would lose the keys while the catcher still waits for them.
              Keys.onTabPressed: function(event) { event.accepted = true }
              Keys.onBacktabPressed: function(event) { event.accepted = true }
            }

            PanelActionButton {
              iconText: "\uf00c"
              tooltipText: "Save the key (Enter)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.saving && keyField.text.length > 0
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.commitKey()
            }

            PanelActionButton {
              visible: root.keySource !== ""
              enabled: !root.saving
              iconText: "\uf00d"
              tooltipText: "Cancel (Esc)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.cancelKeyEdit()
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.saving ? "Saving\u2026" : root.keyFormHint
            color: !root.saving && root.keyFormHintIsError ? root.danger : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---- actions ------------------------------------------------------
        Button {
          visible: root.keySource !== "" && !root.keyRejected
          width: parent.width
          text: "Add credits on OpenRouter"
          iconText: "\uf08e"
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: true
          onClicked: root.openUrl("https://openrouter.ai/credits")
        }

        Button {
          visible: root.keySource !== "" && !root.keyRejected
          width: parent.width
          text: "Open activity on OpenRouter"
          iconText: "\uf08e"
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: true
          onClicked: root.openUrl("https://openrouter.ai/activity")
        }

        // During a failure the failure card already leads with this.
        Button {
          visible: root.keySource !== "" && !root.keyEditing && !Model.failed(root.view)
          width: parent.width
          text: "Replace API key"
          iconText: "\uf084"
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: true
          onClicked: root.startKeyEdit()
        }

        Button {
          width: parent.width
          text: "Create a management key"
          iconText: "\uf08e"
          foreground: root.foreground
          fontFamily: root.fontFamily
          focusable: true
          onClicked: root.openUrl("https://openrouter.ai/settings/management-keys")
        }

        // The one management-key note: the advice when this key cannot read
        // the ledger, the plain description otherwise.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.accountNote.kind === "management"
            ? "The account balance and account-wide spend need a management key. It is free to create, cannot run chat requests, and is the safe key to keep here."
            : "A management key is free, reads the balance and the activity, and cannot run chat requests."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // A rail caption line.
  component DetailLine: Text {
    textFormat: Text.PlainText
    width: parent ? parent.width : implicitWidth
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    horizontalAlignment: Text.AlignHCenter
  }

  // Row helper: small label on the left, value on the right.
  component InfoPair: RowLayout {
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground
    property int valueElide: Text.ElideRight

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
      elide: parent.valueElide
    }
  }
}
