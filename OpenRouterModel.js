.pragma library

// OpenRouter tab — pure logic, no QML imports.
//
// Plain ECMAScript shared by two runtimes: OpenRouterService.qml and
// OpenRouterTab.qml import it as a QML JS module, and
// tests/openrouter/model.test.js requires it from Node (see the
// module.exports guard at the end).
//
// Borrowed, and reworked, from SpoilHeap/Omarchy.OpenRouter @ b443c42 (MIT,
// Model.js): known(), money(), compactMoney(), sourceMeta(), balanceDetail(),
// capDetail(), relativeAge() and the idea of skipping a spend window
// OpenRouter did not report. What changed: "unknown" is null (never a -1
// sentinel), so an overspent negative balance is a figure like any other; the
// spend rows carry a scope and fall back to this key's own windows; and the
// view/state rules (live, stale snapshot, offline, no key) live here instead
// of in the service.

// The helper's reply, after normalisation, never carries anything but these
// keys. The helper copies no server text into it (fixed messages, a three-word
// reset enum, a label that must be the mask of the key in use), but this file
// is the one place the QML side accepts the helper's output, so text is still
// capped and stripped of control and invisible format characters here.
var TEXT_CAP = 200
var SOURCES = ["account", "key", "usage", "none"]
var KEY_KINDS = ["management", "inference", "unknown"]
// Every Unicode format (Cf) code point (Unicode 16) as inclusive
// [first, last] ranges. C0/C1 controls and the line/paragraph separators
// (U+2028/2029) go too; see invisible().
var FORMAT_RANGES = [[173, 173], [1536, 1541], [1564, 1564], [1757, 1757], [1807, 1807],
  [2192, 2193], [2274, 2274], [6158, 6158], [8203, 8207], [8234, 8238], [8288, 8292],
  [8294, 8303], [65279, 65279], [65529, 65531], [69821, 69821], [69837, 69837],
  [78896, 78911], [113824, 113827], [119155, 119162], [917505, 917505], [917536, 917631]]

function invisible(cp) {
  if (cp < 32 || (cp >= 127 && cp <= 159) || cp === 8232 || cp === 8233) return true
  for (var i = 0; i < FORMAT_RANGES.length; i++)
    if (cp >= FORMAT_RANGES[i][0] && cp <= FORMAT_RANGES[i][1]) return true
  return false
}
// Beyond this a figure is not a balance but a broken reply; it renders as
// unknown rather than in exponent notation.
var ABSURD = 1e15

// A figure is known when it is a finite number. Zero is a figure; negative is
// a figure (an overspent account); null, undefined, NaN, Infinity and strings
// are not.
function known(value) {
  return typeof value === "number" && isFinite(value)
}

function num(value) {
  return known(value) ? value : null
}

// Walked by code point, so an astral format character is matched whole and
// the cap never splits a surrogate pair.
function text(value) {
  if (typeof value !== "string") return ""
  var kept = []
  var points = Array.from(value)
  for (var i = 0; i < points.length; i++)
    if (!invisible(points[i].codePointAt(0))) kept.push(points[i])
  var clean = kept.join("").trim()
  points = Array.from(clean)
  return points.length > TEXT_CAP ? points.slice(0, TEXT_CAP).join("") : clean
}

// The same cleaning, for text that does not come through normalize (the
// save helper's error).
function cleanText(value) {
  return text(value)
}

function oneOf(value, allowed, fallback) {
  return typeof value === "string" && allowed.indexOf(value) >= 0 ? value : fallback
}

// The helper prints one JSON object; anything that is not an object becomes a
// failed result with no figure. The key itself never travels here: the
// helper only ever names where it came from.
function normalize(raw) {
  var r = raw
  if (typeof r === "string") {
    try { r = JSON.parse(r) } catch (e) { r = null }
  }
  if (!r || typeof r !== "object" || Array.isArray(r)) {
    return failedResult("Could not read the OpenRouter helper output")
  }
  var result = {
    ok: r.ok === true,
    // The helper's explicit "no key in any source" answer. Only this puts the
    // view in the calm no-key state; an empty keySource alone does not (the
    // helper also reports "" when it could not run at all).
    noKey: r.noKey === true,
    needsManagementKey: r.needsManagementKey === true,
    error: text(r.error),
    hint: text(r.hint),
    keySource: text(r.keySource),
    keyKind: oneOf(r.keyKind, KEY_KINDS, "unknown"),
    source: oneOf(r.source, SOURCES, "none"),
    fetchedAt: num(r.fetchedAt),
    accountError: text(r.accountError),
    keyError: text(r.keyError),
    activityError: text(r.activityError),
    funded: num(r.funded),
    spent: num(r.spent),
    remaining: num(r.remaining),
    keyLabel: text(r.keyLabel),
    keyLimit: num(r.keyLimit),
    keyLimitRemaining: num(r.keyLimitRemaining),
    keyLimitReset: text(r.keyLimitReset),
    keyUsage: num(r.keyUsage),
    keyUsageDaily: num(r.keyUsageDaily),
    keyUsageWeekly: num(r.keyUsageWeekly),
    keyUsageMonthly: num(r.keyUsageMonthly),
    freeTier: r.freeTier === true,
    spendToday: num(r.spendToday),
    spendTodaySince: num(r.spendTodaySince),
    usageWeekly: num(r.usageWeekly),
    usageMonthly: num(r.usageMonthly)
  }
  if (!result.ok && result.error === "") result.error = "OpenRouter returned no usable figures"
  return result
}

// A run that produced no JSON at all (helper missing, killed by the
// watchdog, unparseable output). keySource is unknown, which the reducer
// reads as "keep what we knew".
function failedResult(message) {
  return {
    ok: false, noKey: false, needsManagementKey: false,
    error: text(message), hint: "", keySource: "",
    keyKind: "unknown", source: "none", fetchedAt: null,
    accountError: "", keyError: "", activityError: "",
    funded: null, spent: null, remaining: null,
    keyLabel: "", keyLimit: null, keyLimitRemaining: null, keyLimitReset: "",
    keyUsage: null, keyUsageDaily: null, keyUsageWeekly: null, keyUsageMonthly: null,
    freeTier: false, spendToday: null, spendTodaySince: null,
    usageWeekly: null, usageMonthly: null
  }
}

// ---------------------------------------------------------------- the view
//
// status: loading (no result yet) · live · stale (the last run failed, the
// last good snapshot is still shown) · offline (failed, nothing to show) ·
// nokey. `data` is the last good result, `failedAt` the time of the latest
// failure (0 when the latest run succeeded). keySource "" means unknown
// unless the status is nokey.
function initialView() {
  return { status: "loading", data: null, keySource: "", error: "", hint: "", failedAt: 0 }
}

function reduce(view, result, nowMs) {
  var prev = view || initialView()
  if (result.ok) {
    return { status: "live", data: result, keySource: result.keySource, error: "", hint: "", failedAt: 0 }
  }
  // No key anywhere, said explicitly: an old snapshot belongs to a key that
  // is gone.
  if (result.noKey === true) {
    return { status: "nokey", data: null, keySource: "", error: result.error, hint: result.hint, failedAt: 0 }
  }
  // Any other failure. An empty key source is "unknown", so the one we knew
  // stands; a different key source answering means the snapshot on screen is
  // not this key's, so it is dropped rather than mislabelled.
  var keySource = result.keySource !== "" ? result.keySource : String(prev.keySource || "")
  var data = prev.data && (result.keySource === "" || prev.keySource === result.keySource) ? prev.data : null
  return {
    status: data ? "stale" : "offline",
    data: data,
    keySource: keySource,
    error: result.error !== "" ? result.error : "OpenRouter check failed",
    hint: result.hint,
    failedAt: known(nowMs) ? nowMs : 0
  }
}

// A key was just saved: the key path is the same, the key behind it is not,
// so nothing on screen may be read as the new key's. Back to loading until
// the next run answers for it.
function afterSave() {
  return initialView()
}

function hasData(view) {
  return !!(view && view.data)
}

function failed(view) {
  return !!view && (view.status === "stale" || view.status === "offline")
}

function statusPill(view) {
  var status = view ? view.status : "loading"
  if (status === "live") return "LIVE"
  if (status === "stale") return "STALE"
  if (status === "offline") return "OFFLINE"
  if (status === "nokey") return "NO KEY"
  return "CHECKING"
}

// --------------------------------------------------------------- money

function group(digits) {
  return String(digits).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function displayable(value) {
  return known(value) && Math.abs(value) < ABSURD
}

// Credits are US dollars on OpenRouter. The sign is decided on the rounded
// figure, so -0 and -$0.004 read $0.00.
function money(value, decimals) {
  if (!displayable(value)) return "\u2014"
  var places = decimals === undefined ? 2 : decimals
  var fixed = Math.abs(value).toFixed(places)
  var parts = fixed.split(".")
  parts[0] = group(parts[0])
  var negative = value < 0 && Number(fixed) !== 0
  return (negative ? "-$" : "$") + parts.join(".")
}

// The bar has room for a figure, not a ledger: cents below $1,000, whole
// dollars to $9,999, then thousands with one decimal. Each threshold is
// tested on the figure as it would be printed (999.995 prints as $1,000,
// 9999.99 as $10.0k), never on the raw value.
function compactMoney(value) {
  if (!displayable(value)) return "\u2014"
  var magnitude = Math.abs(value)
  if (Number(magnitude.toFixed(0)) >= 10000) {
    var thousands = (magnitude / 1000).toFixed(1)
    return (value < 0 ? "-$" : "$") + group(thousands.split(".")[0]) + "." + thousands.split(".")[1] + "k"
  }
  if (Number(magnitude.toFixed(2)) >= 1000) return money(value, 0)
  return money(value, 2)
}

// ---------------------------------------------------------------- wording

function sourceMeta(source, freeTier) {
  if (source === "account") return "Account balance"
  if (source === "key") return "Left on key cap"
  if (source === "usage") return freeTier ? "Free tier" : "Spend only"
  return "Not connected"
}

function resetPhrase(reset) {
  var value = String(reset || "").toLowerCase()
  if (value === "daily" || value === "weekly" || value === "monthly") return "resets " + value
  return ""
}

function balanceDetail(funded, spent) {
  if (!known(funded) || !known(spent)) return ""
  return "Spent " + money(spent) + " of " + money(funded) + " purchased"
}

function capDetail(limit, remaining, reset) {
  if (!known(limit)) return ""
  var body = known(remaining)
    ? "Used " + money(limit - remaining) + " of " + money(limit)
    : "Cap " + money(limit)
  var phrase = resetPhrase(reset)
  return phrase === "" ? body : body + " \u00b7 " + phrase
}

function keyKindText(kind) {
  if (kind === "management") return "management key"
  if (kind === "inference") return "inference key"
  return "unknown"
}

// Where the key came from: an environment variable by name, or a file path
// with $HOME folded to ~.
function keySourceText(keySource, home) {
  var source = String(keySource || "")
  if (source === "") return "none"
  if (source.charAt(0) !== "/") return "$" + source
  var h = String(home || "").replace(/\/+$/, "")
  if (h !== "" && source.indexOf(h + "/") === 0) return "~" + source.substring(h.length)
  return source
}

function keyFromEnv(keySource) {
  var source = String(keySource || "")
  return source !== "" && source.charAt(0) !== "/"
}

// Floored, so an age never reads older than it is: 59.5 minutes is "59 min
// ago", 23.5 hours is "23 hours ago".
function relativeAge(fetchedAtSeconds, nowMs) {
  if (!known(fetchedAtSeconds) || fetchedAtSeconds <= 0 || !known(nowMs)) return ""
  var seconds = Math.max(0, Math.floor(nowMs / 1000 - fetchedAtSeconds))
  if (seconds < 45) return "just now"
  if (seconds < 120) return "1 min ago"
  if (seconds < 3600) return Math.floor(seconds / 60) + " min ago"
  var hours = Math.floor(seconds / 3600)
  if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
  var days = Math.floor(hours / 24)
  return days + (days === 1 ? " day ago" : " days ago")
}

// ------------------------------------------------------------- today

// The helper starts today's baseline at the first poll of the UTC day. One
// taken more than half an hour after midnight has missed whatever was spent
// before it, and the caption says so in plain words.
var PARTIAL_AFTER_MS = 30 * 60 * 1000

function todayIsPartial(sinceSeconds) {
  if (!known(sinceSeconds)) return false
  var ms = sinceSeconds * 1000
  var midnight = Math.floor(ms / 86400000) * 86400000
  return ms - midnight > PARTIAL_AFTER_MS
}

function utcClock(seconds) {
  var d = new Date(seconds * 1000)
  if (!isFinite(d.getTime())) return "--:--"
  var hh = d.getUTCHours()
  var mm = d.getUTCMinutes()
  return (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm
}

// The caption under the SPEND rows: where today starts and what the week and
// month windows are. "" when today's account-wide figure is unknown.
function spendCaption(sinceSeconds) {
  if (!known(sinceSeconds)) return ""
  var windows = "Week (from Monday) and month (from the 1st) are UTC."
  if (!todayIsPartial(sinceSeconds)) return "Today counts from 00:00 UTC. " + windows
  return "Today counts from " + utcClock(sinceSeconds)
    + " UTC (the panel's first check); earlier spend today is not included. " + windows
}

// --------------------------------------------------------------- spend

// One row per window, account-wide when the ledger answered and this key's
// own window when it did not. A window neither reported is skipped rather
// than drawn as $0.00, which would claim a quiet day.
function spendRows(d) {
  if (!d) return []
  var windows = [
    { label: "Today", account: d.spendToday, key: d.keyUsageDaily },
    { label: "This week", account: d.usageWeekly, key: d.keyUsageWeekly },
    { label: "This month", account: d.usageMonthly, key: d.keyUsageMonthly },
    { label: "All time", account: d.spent, key: d.keyUsage }
  ]
  var rows = []
  for (var i = 0; i < windows.length; i++) {
    var w = windows[i]
    if (known(w.account)) rows.push({ label: w.label, amount: w.account, value: money(w.account), scope: "account", tag: "account" })
    else if (known(w.key)) rows.push({ label: w.label, amount: w.key, value: money(w.key), scope: "key", tag: "this key" })
  }
  return rows
}

// One scope for every row ("account" or "key"), "mixed" when the rows
// disagree, "" when there are none. With one scope it is said once, in the
// header; only mixed rows carry a tag each.
function spendScope(rows) {
  if (!rows || rows.length === 0) return ""
  var scope = rows[0].scope
  for (var i = 1; i < rows.length; i++) if (rows[i].scope !== scope) return "mixed"
  return scope
}

// ------------------------------------------------------- balance + meter

function headline(view) {
  return hasData(view) ? view.data.remaining : null
}

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value))
}

// The share left, as a 0..1 ratio, and what it is a share of; ratio -1 when
// nothing can be drawn. A key cap is measured against the cap. An account is
// measured against today's starting balance when today's spend is known (so
// the meter moves day to day), else against everything ever purchased.
function meter(d) {
  if (!d) return { ratio: -1, basis: "" }
  if (d.source === "key") {
    if (known(d.keyLimit) && d.keyLimit > 0 && known(d.keyLimitRemaining))
      return { ratio: clamp(d.keyLimitRemaining / d.keyLimit, 0, 1), basis: "of the key's cap" }
    return { ratio: -1, basis: "" }
  }
  if (!known(d.remaining)) return { ratio: -1, basis: "" }
  if (known(d.spendToday) && d.remaining + d.spendToday > 0)
    return { ratio: clamp(d.remaining / (d.remaining + d.spendToday), 0, 1), basis: "of today's starting balance" }
  if (known(d.funded) && d.funded > 0)
    return { ratio: clamp(d.remaining / d.funded, 0, 1), basis: "of credit purchased" }
  return { ratio: -1, basis: "" }
}

// The meter's percentage, floored: 100% only while nothing is spent.
function meterPercent(ratio) {
  if (!known(ratio) || ratio < 0) return ""
  return Math.floor(clamp(ratio, 0, 1) * 100) + "%"
}

// ------------------------------------------------------- account note

// Why the account ledger is not on screen. A 403 on /credits is the common
// case (not a management key) and gets the advice; any other reason is just
// reported.
function accountNote(d) {
  if (!d) return { kind: "", text: "" }
  if (d.needsManagementKey === true) return { kind: "management", text: "" }
  var reason = typeof d.accountError === "string" ? d.accountError : ""
  if (reason !== "") return { kind: "other", text: "Account balance unavailable: " + reason }
  return { kind: "", text: "" }
}

// ------------------------------------------------------------- bar

function isLow(view, threshold) {
  var remaining = headline(view)
  return known(remaining) && known(threshold) && remaining <= threshold
}

// The mark lights for a low balance and for any failed check — with a key
// present, or with the key source unknown (the helper could not even say).
// The explicit no-key answer is a calm state, not an alarm.
function attention(view, threshold) {
  if (isLow(view, threshold)) return true
  return failed(view)
}

function barLabel(view) {
  var remaining = headline(view)
  if (known(remaining)) return compactMoney(remaining)
  if (failed(view)) return "!"
  return "\u2014"
}

// The key behind a failure is the likely fix: with a key source known, the
// pane leads with Replace API key and Enter opens it.
function recoveryFirst(view) {
  return failed(view) && String(view.keySource || "") !== ""
}

// OpenRouter refused the key itself (HTTP 401): top-up and activity links
// are no help until the key is replaced.
function keyRejected(view) {
  return failed(view) && /rejected the key/i.test(String(view.error || ""))
}

function tooltipLine(view) {
  if (!view || view.status === "loading") return "OpenRouter: checking\u2026"
  if (view.status === "nokey") return "OpenRouter: not connected"
  if (!hasData(view)) return "OpenRouter: offline"
  var d = view.data
  var meta = sourceMeta(d.source, d.freeTier).toLowerCase()
  var body = known(d.remaining) ? money(d.remaining) + " \u00b7 " + meta : meta
  return "OpenRouter: " + body + (view.status === "stale" ? " (stale)" : "")
}

// Hero meta: what the figure is, and how old. Offline carries the reason;
// stale says how old the last good figure is.
function statusMeta(view, nowMs) {
  if (!view || view.status === "loading") return "checking OpenRouter\u2026"
  if (view.status === "nokey") return "no API key yet"
  if (!hasData(view)) return String(view.error || "") !== "" ? view.error : "last check failed"
  var d = view.data
  var age = relativeAge(d.fetchedAt, nowMs)
  var meta = sourceMeta(d.source, d.freeTier)
  if (age === "") return view.status === "stale" ? meta + " \u00b7 stale" : meta
  return meta + (view.status === "stale" ? " \u00b7 last good " : " \u00b7 updated ") + age
}

// --------------------------------------------------------------- key entry

// The same allowlist the helpers enforce. The panel checks it first so a
// pasted paragraph never even reaches the save helper.
var KEY_PATTERN = /^[A-Za-z0-9._~+\/=-]{16,256}$/

function cleanKey(value) {
  return String(value === undefined || value === null ? "" : value).replace(/\s/g, "")
}

function validKey(value) {
  return KEY_PATTERN.test(cleanKey(value))
}

if (typeof module !== "undefined") {
  module.exports = {
    known: known,
    normalize: normalize,
    failedResult: failedResult,
    afterSave: afterSave,
    cleanText: cleanText,
    accountNote: accountNote,
    initialView: initialView,
    reduce: reduce,
    hasData: hasData,
    failed: failed,
    statusPill: statusPill,
    money: money,
    compactMoney: compactMoney,
    sourceMeta: sourceMeta,
    balanceDetail: balanceDetail,
    capDetail: capDetail,
    keyKindText: keyKindText,
    keySourceText: keySourceText,
    keyFromEnv: keyFromEnv,
    relativeAge: relativeAge,
    todayIsPartial: todayIsPartial,
    spendCaption: spendCaption,
    spendRows: spendRows,
    spendScope: spendScope,
    meterPercent: meterPercent,
    recoveryFirst: recoveryFirst,
    keyRejected: keyRejected,
    headline: headline,
    meter: meter,
    isLow: isLow,
    attention: attention,
    barLabel: barLabel,
    tooltipLine: tooltipLine,
    statusMeta: statusMeta,
    cleanKey: cleanKey,
    validKey: validKey
  }
}
