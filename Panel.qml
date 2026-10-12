import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Every AI surface in one bar mark and one tabbed panel (plan 128).
//
//   Limits    subscription limits and pace — Claude, Codex, Fireworks, OMP
//             (UsageService.qml + LimitsTab.qml, formerly t1nk33r.agents)
//   Spend     spend and token analytics from the `codeburn` npm tool
//             (SpendService.qml + SpendTab.qml, formerly t1nk33r.codeburn)
//   Fleet     read-only Herdr/OMP connector fleet state
//             (FleetService.qml + FleetTab.qml, formerly t1nk33r.fleet-shepherd)
//   DeepSeek  balance, availability, usage ledger and peak/off-peak pricing
//             (DeepSeekService.qml + DeepSeekTab.qml, formerly t1nk33r.deepseek)
//   OpenRouter  remaining credit, the key's spend cap and spend windows
//             (OpenRouterService.qml + OpenRouterTab.qml, bin/openrouter-*)
//
// Each tab is two columns — a bounded left rail (which one, and its totals) and
// a scrolling right pane (the data) — as approved from the plan-128 mockup.
// Keys: j/k move the rail's chips, Ctrl+j/Ctrl+k (or h/l, PgUp/PgDn) move the
// pane, 1-5 / [ ] switch tabs, r refreshes the active tab, Esc closes.
//
// The five data halves are hidden Items instantiated once, each with its own
// poll loop, so a slow `npx codeburn` run cannot stall the other tabs. Every
// collector, model and external config path is the one its parent plugin used;
// what is new here is the mark, the shared hero, the tab strip and this
// coordinator.
//
// This file is the plugin's only entry point (manifest entryPoints.barWidget)
// and the manifest kinds are ["bar-widget"] alone, so there is no BarWidget.qml
// wrapper and no Loader: the panel IS the bar widget. Per-widget settings
// arrive inline on the widget's shell.json entry and are read through
// Panel.setting(); their names and defaults are declared in manifest.json
// under barWidget.defaults/barWidget.schema.
Panel {
  id: root
  // The agents fork carried the built-in's id; keep it, so a setting
  // written back lands on this plugin's own shell.json entry.
  moduleName: "t1nk33r.agents"
  ipcTarget: "t1nk33r.agents"
  // manageIpc: false so this panel owns the single IpcHandler the target
  // permits — needed for the tab/refresh/setPeriod methods below.
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------------- tabs
  //
  // Every normal opening lands on the defaultTab setting (and, on Limits, the
  // defaultProvider setting); clicks and keystrokes move `tab` only while the
  // panel is open. An explicit request — IPC `tab`, IPC `next`, a middle-click
  // — parks its tab in `requestedTab`, and the opening that follows lands
  // there instead of on the default.
  readonly property var tabs: [
    { value: "limits", label: "1 Limits" },
    { value: "spend", label: "2 Spend" },
    { value: "fleet", label: "3 Fleet" },
    { value: "deepseek", label: "4 DeepSeek" },
    { value: "openrouter", label: "5 OpenRouter" }
  ]
  readonly property string defaultTab: root.tabIndex(String(setting("defaultTab", "limits"))) >= 0
    ? String(setting("defaultTab", "limits")) : "limits"
  readonly property string defaultProvider: String(setting("defaultProvider", "omp"))
  property string tab: root.defaultTab
  property string requestedTab: ""
  readonly property var active: root.tab === "limits" ? limitsTab
    : (root.tab === "spend" ? spendTab
      : (root.tab === "fleet" ? fleetTab
        : (root.tab === "openrouter" ? openrouterTab : deepseekTab)))

  // The key catcher owns the keys on every tab, the OpenRouter tab included:
  // its key field takes focus only on an explicit action (Enter, a click, the
  // Replace/Enter-key buttons), never just by being landed on, so a no-key
  // form can never trap the tab keys. A tab change hands the keys back.
  function focusCatcher() {
    if (root.opened) keyCatcher.forceActiveFocus()
  }

  onTabChanged: if (root.opened) Qt.callLater(root.focusCatcher)

  // Countdowns and "updated" ages read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  function tabIndex(name) {
    for (var i = 0; i < root.tabs.length; i++) if (root.tabs[i].value === name) return i
    return -1
  }

  function setTab(name) {
    var wanted = String(name || "")
    if (root.tabIndex(wanted) < 0) return false
    root.tab = wanted
    return true
  }

  // The tab `delta` steps from `from`, wrapping.
  function tabAfter(from, delta) {
    var index = Math.max(0, root.tabIndex(from))
    var next = ((index + delta) % root.tabs.length + root.tabs.length) % root.tabs.length
    return root.tabs[next].value
  }

  // Open: step from the tab on screen. Closed: step from the tab the next
  // opening would land on, and park the result for that opening.
  function cycleTab(delta) {
    if (root.opened) root.tab = root.tabAfter(root.tab, delta)
    else root.requestedTab = root.tabAfter(root.requestedTab !== "" ? root.requestedTab : root.defaultTab, delta)
  }

  // Open on a named tab; false (and nothing opens) for an unknown name.
  function openOnTab(name) {
    var wanted = String(name || "")
    if (root.tabIndex(wanted) < 0) return false
    if (root.opened) root.tab = wanted
    else {
      root.requestedTab = wanted
      root.open()
    }
    return true
  }

  // ---------------------------------------------------------------- services
  UsageService {
    id: usage
    settings: root.settings
  }

  SpendService {
    id: spend
    settings: root.settings
  }

  FleetService {
    id: fleet
    settings: root.settings
    // A successful raise focuses the connector's terminal, and this panel is a
    // KeyboardPanel — an Overlay layer surface painted *above* every window,
    // so leaving it up would hide the very window the raise just brought
    // forward. The fleet-shepherd panel closed itself on the same signal;
    // nothing else can do it, because only the service knows the focus helper
    // exited 0.
    onConnectorRaised: root.close()
  }

  DeepSeekService {
    id: deepseek
    settings: root.settings
  }

  OpenRouterService {
    id: openrouter
    settings: root.settings
  }

  // --------------------------------------------------------------- bar state
  //
  // A limit window past 90 %, a prepaid balance in its last 10 % (Limits), a
  // blocked connector (Fleet), or a DeepSeek or OpenRouter balance that is low
  // or failed all light the same mark. Spend never alarms: a bill is not an
  // alarm.
  readonly property bool alarming: limitsTab.alarming
    || fleet.summary.blocked > 0
    || deepseek.attention
    || openrouter.attention

  // The badge is a setting, not a policy: the owner's call for the bar is the
  // fleet's working count, and the alternatives are a balance or the period's
  // spend for anyone who would rather read the money.
  readonly property string barBadge: String(setting("barBadge", "fleet"))
  readonly property string badgeText: {
    if (root.barBadge === "none") return ""
    if (root.barBadge === "deepseek") return deepseek.labelText
    if (root.barBadge === "openrouter") return openrouter.labelText
    if (root.barBadge === "spend") return spend.isOnline ? spend.formatCost(spend.cost) : "—"
    return fleet.barLabel
  }

  // Five lines, one per tab: the bar carries one number, the tooltip carries
  // the whole panel.
  readonly property string barTooltip: {
    var lines = []
    var window = limitsTab.headline
    lines.push("Limits: " + (window
      ? window.title + " " + Math.round(Number(window.percent) * 100) + "%"
      : "no subscriptions"))
    lines.push("Spend (" + spend.selectedPeriodLabel + "): "
      + (spend.isOnline ? spend.formatCost(spend.cost) : "unavailable"))
    lines.push("Fleet: " + fleet.summary.online + "/" + fleet.summary.connectors
      + " online · " + fleet.summary.working + " working · " + fleet.summary.blocked + " blocked")
    lines.push("DeepSeek: " + deepseek.labelText + " · " + (deepseek.peak ? "peak" : "off-peak")
      + " · " + deepseek.pricingFlipLocal)
    lines.push(openrouter.tooltipLine)
    return lines.join("\n")
  }

  function refreshAll() {
    usage.refreshAll(true)
    spend.refresh()
    fleet.refresh(true)
    deepseek.refreshNow()
    openrouter.refreshNow()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    // The key form starts clean on every opening and is cleared on every
    // closing, so a half-typed key never outlives the panel.
    openrouterTab.resetForm()
    if (!opened) return
    root.nowMs = Date.now()
    // A fresh opening: the requested tab if something asked for one, the
    // default otherwise, and the Limits rail back on the default provider.
    root.tab = root.requestedTab !== "" ? root.requestedTab : root.defaultTab
    root.requestedTab = ""
    limitsTab.resetSelection()
    // Limits is the cheapest useful refresh; the other four poll on their own
    // and are refreshed when their tab is read or when the mark is right-clicked.
    usage.refreshLimits()
    if (root.tab === "spend") spend.refreshIfStale()
    if (root.tab === "fleet") fleet.refresh(false)
  }

  // PgUp/PgDn never reach PanelKeyCatcher (it emits no signal for them), so
  // the pane's other two keys are bound as window shortcuts while the panel is
  // open.
  Shortcut {
    sequence: "PgDown"
    enabled: root.opened
    context: Qt.WindowShortcut
    onActivated: root.active.movePane(1)
  }

  Shortcut {
    sequence: "PgUp"
    enabled: root.opened
    context: Qt.WindowShortcut
    onActivated: root.active.movePane(-1)
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshAll(); return "ok" }
    function next(): string { root.cycleTab(1); return "ok" }
    function tab(name: string): string {
      if (!root.openOnTab(name)) return "unknown tab"
      return "ok"
    }
    function setPeriod(period: string): string { spend.selectPeriod(String(period)); return "ok" }
  }

  // -------------------------------------------------------------- bar mark
  //
  // OpticalGlyph inside a bar icon canvas, never a raw Text glyph, so the mark
  // sits on the same optical baseline as every other bar icon. The mark never
  // dims and never collapses: it is the only way into the five surfaces.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    active: root.alarming
    tooltipText: root.barTooltip
    fixedWidth: button.vertical ? -1 : barContent.implicitWidth + Style.space(12)
    fixedHeight: button.vertical ? barContent.implicitHeight + Style.space(12) : -1

    onPressed: function(code) {
      if (code === Qt.RightButton) root.refreshAll()
      else if (code === Qt.MiddleButton) {
        root.cycleTab(1)
        root.open()
      } else root.toggle()
    }

    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.space(4)

      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas

        OpticalGlyph {
          text: "󱚣"
          anchors.fill: parent
          color: button.active ? button.activeColor : button.foreground
          fontFamily: button.fontFamily
          fontSize: Style.bar.iconFont
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        // A vertical bar has no room for a badge; the glyph and the tooltip
        // carry the state there.
        visible: !button.vertical && root.badgeText !== ""
        textFormat: Text.PlainText
        text: root.badgeText
        color: button.active ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }
    }
  }

  // ------------------------------------------------------------------ panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Two columns (rail + pane): wider than any single column this one
    // replaces, and about half as tall. fittedContentWidth/Height still clamp
    // both to the screen.
    contentWidth: panel.fittedContentWidth(Style.space(950))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(740))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The fleet filter and the OpenRouter key field are this panel's inline
      // editors: while one has focus every keystroke belongs to it, which is
      // what makes `/` and first-letter filtering work, and what keeps j, k,
      // r and digits inside a pasted or typed key.
      blocked: fleetTab.filterHasFocus || openrouterTab.keyFieldFocused

      // The rail is a vertical list, so vertical motion (j/k, Up/Down) drives
      // its chips and horizontal motion (h/l, Left/Right) drives the pane.
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.active.moveRail(dy)
        else if (dx !== 0) root.active.movePane(dx)
      }
      onActivateRequested: root.active.activate()
      onCloseRequested: {
        if (root.tab === "fleet" && (fleetTab.filterHasFocus || fleetTab.filterText !== "")) fleetTab.clearFilter()
        else if (openrouterTab.keyEditing) openrouterTab.cancelKeyEdit()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "1") root.setTab("limits")
        else if (text === "2") root.setTab("spend")
        else if (text === "3") root.setTab("fleet")
        else if (text === "4") root.setTab("deepseek")
        else if (text === "5") root.setTab("openrouter")
        else if (text === "[") root.cycleTab(-1)
        else if (text === "]") root.cycleTab(1)
        // Ctrl+j / Ctrl+k arrive as the ASCII control characters on Wayland,
        // exactly like Ctrl+R above; they are the pane's scroll keys.
        else if (text === "\n") root.active.movePane(1)
        else if (text === "\u000b") root.active.movePane(-1)
        // Ctrl+R arrives as the ASCII control character on Wayland; bare r
        // refreshes too, matching the panels this one replaces.
        else if (text === "r" || text === "R" || text === "\u0012") root.active.refresh()
        // Fleet's own 1-4 view keys belong to the tab strip now, so its filter
        // keeps the two entry points it still has: `/`, and any other printable.
        else if (root.tab === "fleet" && text === "/") fleetTab.beginFilter("")
        else if (root.tab === "fleet" && text >= " " && text !== "\u007f") fleetTab.beginFilter(text)
      }
      // PanelKeyCatcher claims x/X for deleteRequested before its printable
      // branch, so that one character never reached the filter above — the
      // README promises any printable on the Fleet tab starts the filter, and
      // x was the single exception. Start it here instead. While the filter
      // already has focus the catcher is `blocked`, so x still types straight
      // into the field.
      onDeleteRequested: if (root.tab === "fleet") fleetTab.beginFilter("x")

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- Hero: the active tab's mark, title, meta, pill ----------
        PanelHero {
          id: hero
          width: parent.width
          title: root.active.heroTitle
          meta: root.active.heroMeta
          detail: root.active.heroDetail
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: root.active.heroIcon

          trailingControl: Component {
            PanelActionButton {
              iconText: "󰑐"  // nf-md-refresh
              tooltipText: "Refresh " + root.tab + " (r)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.active.refresh()
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        // ---------- Tab strip ----------
        ButtonGroup {
          id: tabStrip
          width: parent.width
          options: root.tabs
          value: root.tab
          // Keys belong to PanelKeyCatcher; a Tab stop here would steal them.
          focusable: false
          cursorIndex: -1
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onChanged: function(value) { root.tab = value }
        }

        // ---------- Tab host ----------
        // All five tabs exist at once (no Loader): switching is instant, and a
        // hot reload can never leave one on a stale version. Each tab owns its
        // own scrolling, and only the active one is visible.
        Item {
          id: tabHost
          width: column.width
          // The taller of the tab's two columns, capped so the panel stays on
          // screen. Only the pane inside the tab scrolls.
          height: Math.min(Number(root.active.implicitContentHeight) || 0, Style.space(560))
          clip: true

          LimitsTab {
            id: limitsTab
            anchors.fill: parent
            visible: root.tab === "limits"
            usage: usage
            // The rail's DeepSeek glance reads the service's own view; the
            // poll and the key file stay in one place.
            deepseek: deepseek
            openrouter: openrouter
            nowMs: root.nowMs
            defaultProviderId: root.defaultProvider
            foreground: root.foreground
            urgent: root.urgent
            accent: root.accent
            fontFamily: root.fontFamily
          }

          SpendTab {
            id: spendTab
            anchors.fill: parent
            visible: root.tab === "spend"
            spend: spend
            foreground: root.foreground
            urgent: root.urgent
            accent: root.accent
            fontFamily: root.fontFamily
          }

          FleetTab {
            id: fleetTab
            anchors.fill: parent
            visible: root.tab === "fleet"
            fleet: fleet
            foreground: root.foreground
            urgent: root.urgent
            accent: root.accent
            fontFamily: root.fontFamily
          }

          DeepSeekTab {
            id: deepseekTab
            anchors.fill: parent
            visible: root.tab === "deepseek"
            deepseek: deepseek
            foreground: root.foreground
            urgent: root.urgent
            accent: root.accent
            fontFamily: root.fontFamily
          }

          OpenRouterTab {
            id: openrouterTab
            anchors.fill: parent
            visible: root.tab === "openrouter"
            openrouter: openrouter
            nowMs: root.nowMs
            foreground: root.foreground
            urgent: root.urgent
            accent: root.accent
            fontFamily: root.fontFamily
            // The form going away (key saved, edit cancelled) hands the keys
            // back to the catcher.
            onFormVisibleChanged: if (!openrouterTab.formVisible) Qt.callLater(root.focusCatcher)
            onReleaseKeyFocus: keyCatcher.forceActiveFocus()
          }
        }

        // ---------- Keyboard legend ----------
        Text {
          textFormat: Text.PlainText
          width: parent.width
          // While the OpenRouter key field has the keys, the legend says the
          // only two that do anything there.
          text: openrouterTab.keyFieldFocused
            ? "Enter save · Esc cancel"
            : "1-5 tab · [ ] cycle · j/k rail · Ctrl+j/k scroll · r refresh · Esc close"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
