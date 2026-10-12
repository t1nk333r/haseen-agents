import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "DeepSeekModel.js" as DsModel
import "OpenRouterModel.js" as OrModel

// Limits tab — subscription limits, pace and token history for the agents the
// host's collectors have written records for (Claude, Codex, Fireworks, OMP).
//
// The data half is UsageService.qml (the former Main.qml of t1nk33r.agents,
// unchanged): it discovers ~/.local/state/haseen/agents/usage/*.json, runs
// bin/agents-update, and optionally merges synced snapshots.
//
// Two columns, approved by the owner from the plan-128 mockup:
//   left rail  — which provider, its state, its binding window, and the
//                DeepSeek balance as a glance (bounded)
//   right pane — the meters and the history (scrolls)
//
// Keys: j/k move the rail's provider chips, Ctrl+j/Ctrl+k (or h/l, PgUp/PgDn)
// scroll the pane, Enter or r refresh.
Item {
  id: root

  // The service (UsageService.qml), the DeepSeek half of the panel — the rail
  // carries one line of its balance — and the panel's shared clock.
  property var usage: null
  property var deepseek: null
  property var openrouter: null
  property double nowMs: Date.now()

  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, root.accent)
  property string fontFamily: Style.font.family

  readonly property int railWidth: Style.space(268)
  readonly property int paneGap: Style.space(18)

  readonly property var providers: root.usage ? root.usage.enabledProviders : []
  // The provider every opening lands on (the defaultProvider setting).
  property string defaultProviderId: "omp"
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading. An
  // opening sets it to the default provider; until that provider has a record
  // providerIndex shows providers[0], and when the record lands it takes the
  // pane — unless the user drove the rail in the meantime, which replaced the
  // id with their own choice.
  property string selectedProviderId: root.defaultProviderId
  readonly property int providerIndex: {
    for (var i = 0; i < root.providers.length; i++)
      if (root.providers[i].providerId === root.selectedProviderId) return i
    return 0
  }
  readonly property var provider: root.providers.length > 0 ? root.providers[root.providerIndex] : null

  property bool cursorActive: false

  readonly property var limits: root.limitWindows(root.provider)
  readonly property var models: root.modelRows(root.provider)
  readonly property var headline: root.bindingWindow(root.provider)
  readonly property var balance: root.provider ? (root.provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!root.balance && root.balance.funded > 0
    && root.balance.remaining / root.balance.funded <= 0.1
  readonly property bool alarming: (!!root.headline && root.headline.percent >= 0.9) || root.balanceAlarming

  // ---- DeepSeek balance ----------------------------------------------------
  //
  // One number borrowed from the DeepSeek tab, never re-fetched here: the
  // service owns the poll, the key file and the peak clock. The rail is where
  // this tab keeps money (the prepaid ledger above), and it is the half that
  // never scrolls, so the glance goes there rather than at the top of a pane
  // the user can scroll away from.
  readonly property var deepseekView: root.deepseek && root.deepseek.view
    ? root.deepseek.view : null
  readonly property bool deepseekPeak: !!(root.deepseek && root.deepseek.peak)
  // The service's "degraded": a balance is still on screen, but the check that
  // would refresh it failed. Shown, and named, rather than passed off as live.
  readonly property bool deepseekStale: !!root.deepseekView
    && root.deepseekView.status === "degraded"
  // -1 when the service has never completed a read, so nothing claims an age.
  readonly property double deepseekAgeMs: root.deepseekView
      && Number(root.deepseekView.checkedAt) > 0
    ? root.nowMs - Number(root.deepseekView.checkedAt) : -1
  readonly property string deepseekAgeText: root.deepseekAgeMs < 0 ? ""
    : (root.deepseekAgeMs < 60000
      ? "read just now" : "read " + root.formatDuration(root.deepseekAgeMs) + " ago")
  // "$38.75 · off-peak · read 2m ago". Empty — and so is the row — whenever
  // there is no balance the API actually returned: no key, a broken config, or
  // a failed read with nothing behind it. A failed read over a balance it still
  // has keeps the amount and says "stale" in place of the rate word (the whale
  // beside it still carries the rate in its colour).
  readonly property string deepseekLine: {
    var view = root.deepseekView
    if (!view || !DsModel.hasData(view)) return ""
    var amount = DsModel.formatAmount(view.total, view.currency)
    if (amount === "") return ""
    var sar = DsModel.sarText(view.total, view.currency)
    var parts = [amount]
    if (sar !== "") parts.push(sar)
    parts.push(root.deepseekStale ? "stale" : (root.deepseekPeak ? "peak" : "off-peak"))
    if (root.deepseekAgeText !== "") parts.push(root.deepseekAgeText)
    return parts.join(" \u00b7 ")
  }
  readonly property bool hasDeepSeekBalance: root.deepseekLine !== ""
  // The hover spells out what the one line has no room for, in the DeepSeek
  // tab's own words (its pricing status and its "last check failed").
  readonly property string deepseekTooltip: {
    if (!root.hasDeepSeekBalance) return ""
    var view = root.deepseekView
    var text = "DeepSeek balance " + DsModel.formatAmount(view.total, view.currency)
    var sar = DsModel.sarText(view.total, view.currency)
    if (sar !== "") text += " (" + sar + ")"
    text += " \u00b7 " + (root.deepseek ? root.deepseek.pricingStatus : "")
      + " \u00b7 read " + DsModel.formatDateTime(view.checkedAt)
    if (root.deepseekStale) text += " \u00b7 last check failed"
    else if (view.isAvailable === false) text += " \u00b7 balance too low for API calls"
    return text
  }

  // Read the same view as the OpenRouter tab. A failed check keeps its last
  // good balance marked stale; without one, show offline instead of a figure.
  readonly property var openrouterView: root.openrouter ? root.openrouter.view : null
  readonly property bool openrouterWarn: OrModel.failed(root.openrouterView)
    || OrModel.isLow(root.openrouterView, root.openrouter ? root.openrouter.lowBalance : 5)
  readonly property string openrouterLine: {
    var view = root.openrouterView
    var amount = OrModel.headline(view)
    if (!OrModel.known(amount)) return OrModel.failed(view) ? "OpenRouter \u00b7 offline" : ""
    var parts = ["OpenRouter", OrModel.money(amount)]
    if (view.data.source === "key") parts.push("key cap")
    if (view.status === "stale") parts.push("stale")
    var age = OrModel.relativeAge(view.data.fetchedAt, root.nowMs)
    if (age !== "") parts.push("read " + age)
    return parts.join(" \u00b7 ")
  }
  readonly property string openrouterTooltip: root.openrouterLine === "" ? ""
    : OrModel.tooltipLine(root.openrouterView) + " \u00b7 " + OrModel.statusMeta(root.openrouterView, root.nowMs)

  readonly property var providerOptions: {
    var options = []
    for (var i = 0; i < root.providers.length; i++)
      options.push({ value: root.providers[i].providerId, label: root.providers[i].providerName })
    return options
  }

  // The pane's viewport: the rail's height when the rail is the taller column,
  // otherwise the pane's own content up to the panel's cap.
  readonly property real paneViewport: Math.max(rail.implicitHeight,
    Math.min(paneColumn.implicitHeight, Style.space(560)))
  readonly property real implicitContentHeight: Math.max(rail.implicitHeight, root.paneViewport)

  // ------------------------------------------------------- shared hero face
  readonly property string heroTitle: root.provider ? root.provider.providerName : "No subscriptions"
  readonly property string heroMeta: root.provider ? root.subscriptionLabel(root.provider) : "LIMITS"
  readonly property string heroDetail: ""
  readonly property Component heroIcon: Component {
    Item {
      id: heroMark
      property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
      // Provider objects are rebuilt on every refresh, which churns the
      // array's identity without changing its content. Restart the fallback
      // walk only when the URLs change: re-pointing source at a URL whose
      // load already failed emits no statusChanged, so an identity-only
      // reset would strand the walker on a missing -light twin.
      property string candidatesKey: candidates.join("\n")
      property int candidateIndex: 0
      onCandidatesKeyChanged: candidateIndex = 0

      width: Style.font.display
      height: Style.font.display

      Image {
        id: heroMarkImage
        anchors.fill: parent
        source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
        sourceSize.width: Style.font.display * 2
        sourceSize.height: Style.font.display * 2
        fillMode: Image.PreserveAspectFit
        // Advancing source from inside its own status change trips the
        // binding-loop detector; defer the step one tick.
        onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
          Qt.callLater(function() { heroMark.candidateIndex++ })
      }

      OpticalGlyph {
        text: "󱚣"
        anchors.fill: parent
        visible: heroMarkImage.status !== Image.Ready
        color: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.display
      }
    }
  }

  // ------------------------------------------------------------- actions
  // The tab's refresh covers what the tab shows: the local scan, and the
  // DeepSeek read the rail borrows (its service still owns the poll and the
  // single in-flight request).
  function refresh() {
    if (root.usage) root.usage.refreshAll(true)
    if (root.deepseek) root.deepseek.refreshNow()
    if (root.openrouter) root.openrouter.refreshNow()
  }
  function activate() { root.refresh() }
  // Every opening: back on the default provider, cursor unpainted.
  function resetSelection() {
    root.selectedProviderId = root.defaultProviderId
    root.cursorActive = false
  }
  // j/k: the rail's chips.
  function moveRail(delta) {
    if (delta === 0 || root.providers.length === 0) return
    root.cursorActive = true
    root.selectProvider(root.providerIndex + delta)
  }
  // Ctrl+j/Ctrl+k, h/l, PgUp/PgDn: the pane.
  function movePane(delta) {
    pane.contentY = root.clamp(pane.contentY + delta * Style.space(56), 0,
      Math.max(0, pane.contentHeight - pane.height))
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (root.providers.length === 0) return
    var wrapped = ((index % root.providers.length) + root.providers.length) % root.providers.length
    root.selectedProviderId = root.providers[wrapped].providerId
  }

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    text = String(text || "").toLowerCase()
    if (text.indexOf(" · ") >= 0) text = text.split(" (")[0]
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf(" · ") >= 0) text = text.split(" (")[0]
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (root.windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  // Pace, ported from t1nk33r.agent-usage when the three agent-telemetry
  // plugins merged (plan 090). A percentage says how much of the allowance is
  // gone; pace says whether it is going faster than the window can refill.
  // Burning 60% of a weekly limit is fine on day five and a problem on day two.
  function paceDelta(window) {
    if (!window) return 0
    var label = String(window.label || "").toLowerCase()
    var span = root.windowSpanMs(window.label)
    if (span <= 0 && root.windowIsLong(label))
      span = (label.indexOf("month") >= 0 || label.indexOf("30-day") >= 0)
        ? 30 * 24 * 3600 * 1000
        : 7 * 24 * 3600 * 1000
    var remainingMs = root.resetMsFor(window)
    if (span <= 0 || remainingMs <= 0) return 0
    var expectedRemaining = root.clamp(remainingMs / span, 0, 1)
    var actualRemaining = root.clamp(1 - window.percent, 0, 1)
    return actualRemaining - expectedRemaining
  }

  // A small tolerance, so a window sitting exactly on pace does not flicker
  // between "ahead" and "behind" as the countdown ticks.
  function behindPace(window) { return root.paceDelta(window) < -0.0005 }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (root.windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || root.windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title) {
    return {
      title: String(title || "") !== "" ? String(title) : root.windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || ""),
      // The raw label is kept, not just the display title: paceDelta needs the
      // window's length, and only the label carries it.
      label: String(label || "")
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(root.limitWindow(entry.label, percent, entry.resetsAt, entry.title))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = root.limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // Prepaid agents report a credit ledger instead of rate-limit windows.
  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return root.currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = root.formatMoney(b.spent, b.currency) + " spent of " + root.formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // The plan you pay for, under the name of the tool it pays for.
  function subscriptionLabel(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return root.dayName(date)
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : root.dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + root.usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own.
    if (today && root.provider && root.provider.hasPromptStats !== false)
      text += " · " + Number(root.provider.todayPrompts || 0) + " prompts · "
        + Number(root.provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: root.usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + root.usage.formatTokenCount(row.input)
      + " · out " + root.usage.formatTokenCount(row.output)
      + " · cache read " + root.usage.formatTokenCount(row.cacheRead)
      + " · cache write " + root.usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (root.usage && root.usage.syncStatusText !== "") return root.usage.syncStatusText
    if (root.provider && root.provider.syncEnabled && root.provider.syncDeviceCount > 0)
      return "Merged from " + root.provider.syncDeviceCount + " device"
        + (root.provider.syncDeviceCount === 1 ? "" : "s")
    return "Local records only"
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both ship one file. The luminance check
  // decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * root.colorChannelLuminance(color.r)
      + 0.7152 * root.colorChannelLuminance(color.g)
      + 0.0722 * root.colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing from
  // this panel: assets/<id>.svg if it ships one, the module's bar glyph if not.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (root.colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  onProviderIndexChanged: if (pane) pane.contentY = 0

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

      // ---------- Status: what the provider itself has to say ----------
      BorderSurface {
        visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
        width: parent.width
        implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
        color: root.alpha(root.urgent, 0.10)
        borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
        radius: Style.cornerRadius

        Text {
          id: statusText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(12)
          text: root.provider ? String(root.provider.authHelpText || "") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // ---------- Provider switch ----------
      PanelSectionHeader {
        visible: root.providers.length > 1
        width: parent.width
        text: "PROVIDERS"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      RailList {
        visible: root.providers.length > 0
        width: parent.width
        options: root.providerOptions
        // The chip that paints as selected is the provider the pane is reading.
        // selectedProviderId can name a provider with no record yet (the
        // default, before its collector lands), and providerIndex already
        // resolves that id to providers[0] — so binding the raw id would leave
        // providers[0] unselected while its data was on screen, and make the
        // first `j` (providerIndex + 1) jump to providers[1] and skip it. Same
        // contract as the Spend rail, which binds its period rather than its
        // cursor.
        value: root.providers.length > 0 ? root.providers[root.providerIndex].providerId : ""
        // The selection follows the provider, so the cursor is only painted
        // once the user has actually driven the rail.
        cursorIndex: root.cursorActive ? root.providerIndex : -1
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onChanged: function(value) {
          root.cursorActive = true
          root.selectProvider(root.providerIdIndex(value))
        }
      }

      // ---------- Balance (prepaid providers) ----------
      // The meter shows what is left, not what is used: a prepaid account
      // drains toward empty rather than filling toward a cap.
      Column {
        id: balanceSection
        visible: !!root.balance
        width: parent.width
        spacing: Style.space(6)

        readonly property real ratio: root.balance && root.balance.funded > 0
          ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
          : -1

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          width: parent.width
          text: "BALANCE"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

          Text {
            id: balanceLabel
            textFormat: Text.PlainText
            text: "Prepaid credits"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: balanceValue
            textFormat: Text.PlainText
            text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
            color: root.balanceAlarming ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Meter {
          visible: balanceSection.ratio >= 0
          width: parent.width
          value: balanceSection.ratio
          alarming: root.balanceAlarming
        }

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          width: parent.width
          text: root.balanceDetailText(root.balance)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // ---------- The window that decides how much room is left ----------
      Column {
        id: windowSection
        visible: !root.balance && !!root.headline
        width: parent.width
        spacing: Style.space(6)

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          width: parent.width
          text: "BINDING WINDOW"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(bindingLabel.implicitHeight, bindingValue.implicitHeight)

          Text {
            id: bindingLabel
            textFormat: Text.PlainText
            text: root.headline ? root.headline.title : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            anchors.left: parent.left
            anchors.right: bindingValue.left
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: bindingValue
            textFormat: Text.PlainText
            text: root.headline ? Math.round(root.headline.percent * 100) + "%" : ""
            color: root.headline && root.headline.percent >= 0.9 ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Meter {
          width: parent.width
          value: root.headline ? root.headline.percent : -1
          alarming: !!root.headline && root.headline.percent >= 0.9
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: {
            var remainingMs = root.resetMsFor(root.headline)
            if (remainingMs <= 0) return ""
            var base = "Resets in " + root.formatDuration(remainingMs)
            var delta = root.paceDelta(root.headline)
            if (delta === 0) return base
            return base + " · " + Math.abs(Math.round(delta * 100)) + "% "
                 + (delta < 0 ? "behind pace" : "ahead of pace")
          }
          color: root.behindPace(root.headline) ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // ---------- Sync ----------
      PanelSeparator { visible: root.providers.length > 0; foreground: root.foreground }

      PanelSectionHeader {
        visible: root.providers.length > 0
        width: parent.width
        text: "SYNC"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        textFormat: Text.PlainText
        visible: root.providers.length > 0
        width: parent.width
        text: root.footerText()
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // ---------- DeepSeek balance ----------
      // A glance, not the breakdown: the DeepSeek tab a key away owns the
      // ledger, the clocks and the recovery flow. Two things make this number
      // unlike the prepaid ledger above — it is read from the API rather than
      // measured locally, and its rate depends on the hour — so the whale (the
      // same mark the DeepSeek tab flies) carries the pricing state in its
      // colour, and the line is tinted with it. The row is absent, not
      // blanked, when the service has nothing to show; the hover is where the
      // full wording lives.
      PanelSeparator { visible: root.hasDeepSeekBalance; foreground: root.foreground }

      Item {
        id: deepseekGlance
        visible: root.hasDeepSeekBalance
        width: parent.width
        implicitHeight: Math.max(Style.space(16), deepseekLine.implicitHeight)

        Image {
          id: deepseekWhale
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(16)
          height: width
          source: root.deepseek ? root.deepseek.whaleSource : ""
          sourceSize.width: 64
          sourceSize.height: 64
          fillMode: Image.PreserveAspectFit
          smooth: true
        }

        Text {
          id: deepseekLine
          textFormat: Text.PlainText
          text: root.deepseekLine
          // Peak is the pricing state the line is coloured by, and a check
          // that failed outranks it: the DeepSeek tab lights the same urgent
          // for a stale reading.
          color: root.deepseekPeak || root.deepseekStale ? root.urgent : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          anchors.left: deepseekWhale.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }

        MouseArea {
          id: deepseekHover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }

        PanelToolTip {
          visible: deepseekHover.containsMouse
          text: root.deepseekTooltip
          fontFamily: root.fontFamily
        }
      }

      PanelSeparator { visible: root.openrouterLine !== ""; foreground: root.foreground }

      Item {
        objectName: "openrouterGlance"
        visible: root.openrouterLine !== ""
        width: parent.width
        implicitHeight: openrouterText.implicitHeight

        Text {
          id: openrouterText
          width: parent.width
          textFormat: Text.PlainText
          text: root.openrouterLine
          color: root.openrouterWarn ? root.urgent : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        MouseArea {
          id: openrouterHover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }

        PanelToolTip {
          visible: openrouterHover.containsMouse
          text: root.openrouterTooltip
          fontFamily: root.fontFamily
        }
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

        Text {
          visible: root.providers.length === 0
          width: parent.width
          topPadding: Style.space(24)
          textFormat: Text.PlainText
          text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        Column {
          id: limitsSection
          visible: root.limits.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "LIMITS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.limits

            LimitRow {
              required property var modelData
              width: limitsSection.width
              window: modelData
            }
          }
        }

        PanelSeparator {
          visible: usageSection.visible
          foreground: root.foreground
        }

        Column {
          id: usageSection
          visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
          width: parent.width
          spacing: Style.spacing.md

          readonly property var days: root.provider ? (root.provider.recentDays || []) : []
          readonly property real peak: Math.max(1, root.weekPeak(root.provider))

          PanelSectionHeader {
            width: parent.width
            text: "TOKENS BY DAY"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: usageSection.days

            DayRow {
              required property var modelData
              required property int index

              width: usageSection.width
              day: modelData
              ratio: Number(modelData.messageCount || 0) / usageSection.peak
              // By date, not by position: the Claude stats-cache fallback can
              // hand us a window that stops short of today.
              today: String(modelData.date || "") === root.todayDate()
            }
          }
        }

        PanelSeparator {
          visible: modelSection.visible
          foreground: root.foreground
        }

        Column {
          id: modelSection
          visible: root.models.length > 0
          width: parent.width
          spacing: Style.spacing.md

          PanelSectionHeader {
            width: parent.width
            text: "TOKENS BY MODEL"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.models

            ModelRow {
              required property var modelData
              width: modelSection.width
              row: modelData
              // Scaled to the heaviest model, so the top row is always full.
              share: modelData.total / Math.max(1, root.models[0].total)
            }
          }
        }
      }
    }
  }

  function providerIdIndex(providerId) {
    for (var i = 0; i < root.providers.length; i++)
      if (root.providers[i].providerId === providerId) return i
    return 0
  }

  // A limit window: label and percentage, meter, and reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window && window.percent >= 0.9

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && limitRow.window.percent >= 0
          ? Math.round(limitRow.window.percent * 100) + "%"
          : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      alarming: limitRow.alarming
    }

    Text {
      id: resetText
      textFormat: Text.PlainText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        if (remainingMs <= 0) return ""
        var base = "Resets in " + root.formatDuration(remainingMs)
        var delta = root.paceDelta(limitRow.window)
        if (delta === 0) return base
        return base + "  ·  " + Math.abs(Math.round(delta * 100)) + "% "
             + (delta < 0 ? "behind pace" : "ahead of pace")
      }
      color: root.behindPace(limitRow.window) ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

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
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: height / 2
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: root.usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? root.usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
