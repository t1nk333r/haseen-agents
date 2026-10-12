// Node self-check for OpenRouterModel.js — behaviour only.
//
// The model is a `.pragma library` QML script, which Node cannot require as
// is, so the pragma line is dropped and the file runs in a vm context that
// offers it a `module` to export through.
//
// Run: node tests/openrouter/model.test.js

const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "..", "OpenRouterModel.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const sandbox = { module: { exports: {} } }
vm.runInNewContext(source, sandbox)
const M = sandbox.module.exports
// Arrays built inside the vm context carry that realm's prototypes; compare
// plain copies.
const plain = (value) => JSON.parse(JSON.stringify(value))

const tests = []
function test(name, fn) {
  tests.push([name, fn])
}
function run() {
  let pass = 0
  let fail = 0
  for (const [name, fn] of tests) {
    try {
      fn()
      pass++
      console.log("ok   - " + name)
    } catch (e) {
      fail++
      console.log("FAIL - " + name)
      console.log("       " + (e && e.message ? e.message : e))
    }
  }
  console.log("")
  console.log(pass + " passed, " + fail + " failed")
  if (fail > 0) process.exit(1)
}

// A full helper reply with every key present, as the helper contract says.
function reply(over) {
  return Object.assign({
    ok: true, error: "", hint: "", keySource: "/test-home/u/.config/haseen/agents/openrouter/key",
    keyKind: "management", source: "account", fetchedAt: 1790000000,
    accountError: "", keyError: "", activityError: "",
    funded: 100, spent: 25.25, remaining: 74.75,
    keyLabel: "sk-or-v1-abc...xyz", keyLimit: null, keyLimitRemaining: null, keyLimitReset: "", // gitleaks:allow -- synthetic masked label
    keyUsage: 3, keyUsageDaily: 0.5, keyUsageWeekly: 1, keyUsageMonthly: 2,
    freeTier: false, spendToday: 1.5, spendTodaySince: 1790000000,
    usageWeekly: 10, usageMonthly: 20
  }, over || {})
}

function live(over) {
  return M.reduce(M.initialView(), M.normalize(reply(over)), 1)
}

// ------------------------------------------------------------ normalise

test("normalize: null and non-finite numbers become unknown, zero stays a figure", () => {
  const r = M.normalize(reply({ funded: null, spent: 0, remaining: Infinity, keyUsage: NaN }))
  assert.strictEqual(r.funded, null)
  assert.strictEqual(r.spent, 0)
  assert.ok(M.known(r.spent), "0 is a known figure")
  assert.strictEqual(r.remaining, null)
  assert.strictEqual(r.keyUsage, null)
})

test("normalize: numbers sent as strings or booleans are rejected", () => {
  const r = M.normalize(reply({ remaining: "74.75", funded: true, spendToday: [1], usageWeekly: {} }))
  assert.strictEqual(r.remaining, null)
  assert.strictEqual(r.funded, null)
  assert.strictEqual(r.spendToday, null)
  assert.strictEqual(r.usageWeekly, null)
})

test("normalize: unknown enum values fall back, ok must be literally true", () => {
  const r = M.normalize(reply({ ok: "true", source: "bank", keyKind: "root" }))
  assert.strictEqual(r.ok, false)
  assert.strictEqual(r.source, "none")
  assert.strictEqual(r.keyKind, "unknown")
  assert.notStrictEqual(r.error, "", "a failed result always carries a reason")
})

test("normalize: control characters are stripped and server text is capped", () => {
  const r = M.normalize(reply({ keyLabel: "a\u001b[31mb\nc" + "x".repeat(500) }))
  assert.ok(!/[\u0000-\u001f]/.test(r.keyLabel))
  assert.ok(r.keyLabel.length <= 200)
})

test("normalize: non-object and unparseable input is a failure with no figures", () => {
  for (const bad of ["not json", "[1,2]", "42", null, undefined, ""]) {
    const r = M.normalize(bad)
    assert.strictEqual(r.ok, false, String(bad))
    assert.strictEqual(r.remaining, null)
  }
  assert.strictEqual(M.normalize(JSON.stringify(reply())).remaining, 74.75)
})

// ------------------------------------------------------------ money

test("an overspent negative balance is a figure, not unknown", () => {
  const v = live({ remaining: -3.2, funded: 10, spent: 13.2 })
  assert.strictEqual(M.headline(v), -3.2)
  assert.strictEqual(M.money(-3.2), "-$3.20")
  assert.strictEqual(M.barLabel(v), "-$3.20")
  assert.ok(M.isLow(v, 5), "below the threshold, so low")
})

test("compact money: cents below 1000, whole dollars to 9999, thousands from 10000", () => {
  assert.strictEqual(M.compactMoney(999.994), "$999.99")
  assert.strictEqual(M.compactMoney(1000), "$1,000")
  assert.strictEqual(M.compactMoney(9999.4), "$9,999")
  assert.strictEqual(M.compactMoney(10000), "$10.0k")
  assert.strictEqual(M.compactMoney(12345), "$12.3k")
  assert.strictEqual(M.compactMoney(-12345), "-$12.3k")
  assert.strictEqual(M.compactMoney(null), M.money(undefined), "unknown renders the same placeholder")
  assert.ok(!/\d/.test(M.compactMoney(null)))
})

// ------------------------------------------------------------ spend rows

test("spend rows: account-wide when the ledger answered", () => {
  const rows = M.spendRows(M.normalize(reply()))
  assert.deepStrictEqual(plain(rows.map((r) => [r.label, r.amount, r.scope])), [
    ["Today", 1.5, "account"], ["This week", 10, "account"],
    ["This month", 20, "account"], ["All time", 25.25, "account"]])
})

test("spend rows: each unknown account window falls back to this key's own", () => {
  const rows = M.spendRows(M.normalize(reply({ spendToday: null, usageWeekly: null, usageMonthly: 20, spent: null })))
  assert.deepStrictEqual(plain(rows.map((r) => [r.label, r.amount, r.scope])), [
    ["Today", 0.5, "key"], ["This week", 1, "key"],
    ["This month", 20, "account"], ["All time", 3, "key"]])
})

test("spend rows: a window neither scope reported is skipped, a zero is kept", () => {
  const rows = M.spendRows(M.normalize(reply({
    spendToday: 0, usageWeekly: null, keyUsageWeekly: null,
    usageMonthly: null, keyUsageMonthly: null, spent: null, keyUsage: null })))
  assert.deepStrictEqual(plain(rows.map((r) => [r.label, r.amount])), [["Today", 0]])
  assert.strictEqual(M.spendRows(null).length, 0)
})

// ------------------------------------------------------------ today

test("today is partial only when the baseline is more than 30 min after UTC midnight", () => {
  const midnight = Date.UTC(2026, 9, 3) / 1000
  assert.strictEqual(M.todayIsPartial(midnight), false)
  assert.strictEqual(M.todayIsPartial(midnight + 30 * 60), false)
  assert.strictEqual(M.todayIsPartial(midnight + 30 * 60 + 1), true)
  assert.strictEqual(M.todayIsPartial(midnight + 23 * 3600), true)
  assert.strictEqual(M.todayIsPartial(null), false)
  // A late baseline names the real start time; an on-time one does not.
  assert.ok(M.spendCaption(midnight + 51 * 60).includes("00:51"))
  assert.ok(!M.spendCaption(midnight + 60).includes("00:01"))
  assert.strictEqual(M.spendCaption(null), "")
})

test("spend scope: one scope for uniform rows, mixed only when rows disagree", () => {
  const all = M.spendRows(M.normalize(reply()))
  assert.strictEqual(M.spendScope(all), "account")
  const keyOnly = M.spendRows(M.normalize(reply({ spendToday: null, usageWeekly: null, usageMonthly: null, spent: null })))
  assert.strictEqual(M.spendScope(keyOnly), "key")
  const mixed = M.spendRows(M.normalize(reply({ spendToday: null })))
  assert.strictEqual(M.spendScope(mixed), "mixed")
  assert.strictEqual(M.spendScope([]), "")
})

test("meter percentage is floored: 100% only while untouched", () => {
  assert.strictEqual(M.meterPercent(1), "100%")
  assert.strictEqual(M.meterPercent(0.999), "99%")
  assert.strictEqual(M.meterPercent(0), "0%")
  assert.strictEqual(M.meterPercent(-1), "")
})

test("recovery: a failure with a known key source leads with the key; a 401 is a rejected key", () => {
  const rejected = M.reduce(M.initialView(), M.normalize({ ok: false, error: "OpenRouter rejected the key", keySource: "OPENROUTER_KEY" }), 1)
  assert.strictEqual(M.recoveryFirst(rejected), true)
  assert.strictEqual(M.keyRejected(rejected), true)
  const unreachable = M.reduce(live(), M.normalize({ ok: false, error: "Could not reach openrouter.ai", keySource: reply().keySource }), 1)
  assert.strictEqual(M.recoveryFirst(unreachable), true)
  assert.strictEqual(M.keyRejected(unreachable), false)
  const unknown = M.reduce(M.initialView(), M.failedResult("helper could not run"), 1)
  assert.strictEqual(M.recoveryFirst(unknown), false, "unknown source offers Enter API key instead")
  assert.strictEqual(M.recoveryFirst(live()), false)
})

test("hero meta: offline carries the error; stale is the last good age", () => {
  const off = M.reduce(M.initialView(), M.normalize({ ok: false, error: "OpenRouter rejected the key", keySource: "OPENROUTER_KEY" }), 1)
  assert.ok(M.statusMeta(off, 0).includes("OpenRouter rejected the key"))
  assert.strictEqual(M.statusPill(off), "OFFLINE")
  const now = 1790000000 * 1000 + 600000
  const fresh = M.statusMeta(live(), now)
  const stale = M.statusMeta(M.reduce(live(), M.failedResult("x"), 1), now)
  assert.notStrictEqual(stale, fresh)
  assert.ok(stale.includes("10 min ago") && fresh.includes("10 min ago"))
})

test("every Unicode format character in the model's table is stripped from text", () => {
  const ranges = [[173, 173], [1536, 1541], [1564, 1564], [1757, 1757], [1807, 1807], [2192, 2193], [2274, 2274],
    [6158, 6158], [8203, 8207], [8234, 8238], [8288, 8292], [8294, 8303], [65279, 65279], [65529, 65531],
    [69821, 69821], [69837, 69837], [78896, 78911], [113824, 113827], [119155, 119162], [917505, 917505], [917536, 917631]]
  let count = 0
  for (const [lo, hi] of ranges) {
    for (let cp = lo; cp <= hi; cp++) {
      count++
      const r = M.normalize(reply({ keyLabel: "A" + String.fromCodePoint(cp) + "B" }))
      assert.strictEqual(r.keyLabel, "AB", "U+" + cp.toString(16))
    }
  }
  assert.strictEqual(count, 170)
  for (const cp of [0x2028, 0x2029, 0x85, 0x1b])
    assert.strictEqual(M.normalize(reply({ keyLabel: "A" + String.fromCodePoint(cp) + "B" })).keyLabel, "AB")
})

// ------------------------------------------------------------ view states

test("a failure keeps the last good snapshot as stale; with nothing it is offline", () => {
  const fail = M.normalize({ ok: false, error: "Could not reach openrouter.ai", keySource: reply().keySource })
  const stale = M.reduce(live(), fail, 2)
  assert.strictEqual(stale.status, "stale")
  assert.strictEqual(M.headline(stale), 74.75)
  assert.strictEqual(M.statusPill(stale), "STALE")
  const offline = M.reduce(M.initialView(), fail, 2)
  assert.strictEqual(offline.status, "offline")
  assert.strictEqual(M.headline(offline), null)
  assert.strictEqual(M.statusPill(offline), "OFFLINE")
})

test("a helper crash (no key source reported) keeps the known key source", () => {
  const v = M.reduce(live(), M.failedResult("helper died"), 2)
  assert.strictEqual(v.status, "stale")
  assert.strictEqual(v.keySource, reply().keySource)
})

test("a failure from a different key source drops the old snapshot", () => {
  const fail = M.normalize({ ok: false, error: "rejected", keySource: "OPENROUTER_API_KEY" })
  const v = M.reduce(live(), fail, 2)
  assert.strictEqual(v.status, "offline")
  assert.strictEqual(M.headline(v), null)
})

test("only the explicit noKey answer is the calm no-key state", () => {
  const v = M.reduce(live(), M.normalize({ ok: false, noKey: true, error: "No OpenRouter API key found", keySource: "" }), 2)
  assert.strictEqual(v.status, "nokey")
  assert.strictEqual(M.hasData(v), false)
  assert.strictEqual(M.statusPill(v), "NO KEY")
  assert.strictEqual(M.statusPill(M.initialView()), "CHECKING")
})

test("an empty key source without noKey is a failure: the snapshot stays (stale), else offline with the real error", () => {
  const fail = M.normalize({ ok: false, noKey: false, error: "jq is not installed", keySource: "" })
  const stale = M.reduce(live(), fail, 2)
  assert.strictEqual(stale.status, "stale")
  assert.strictEqual(stale.keySource, reply().keySource, "the known key source stands")
  const offline = M.reduce(M.initialView(), fail, 2)
  assert.strictEqual(offline.status, "offline")
  assert.strictEqual(offline.error, "jq is not installed")
  // A missing noKey is not an invitation to guess.
  assert.strictEqual(M.reduce(M.initialView(), M.normalize({ ok: false, keySource: "" }), 2).status, "offline")
})

test("a malformed helper reply keeps the snapshot as stale", () => {
  for (const bad of ["{", "[]", "null", "{\"ok\":", "<html>"]) {
    const v = M.reduce(live(), M.normalize(bad), 2)
    assert.strictEqual(v.status, "stale", bad)
    assert.strictEqual(M.headline(v), 74.75)
    assert.notStrictEqual(v.error, "")
  }
})

test("after a save nothing of the previous key's figures survives", () => {
  const v = M.afterSave(live())
  assert.strictEqual(M.hasData(v), false)
  assert.strictEqual(M.headline(v), null)
  assert.strictEqual(M.statusPill(v), "CHECKING")
  // A later failure has no old snapshot to fall back on.
  assert.strictEqual(M.reduce(v, M.failedResult("x"), 3).status, "offline")
})

test("account note: management advice only for a 403, any other reason is reported as such", () => {
  assert.strictEqual(M.accountNote(M.normalize(reply({ needsManagementKey: true, accountError: "needs a management key" }))).kind, "management")
  const other = M.accountNote(M.normalize(reply({ needsManagementKey: false, accountError: "OpenRouter answered 500" })))
  assert.strictEqual(other.kind, "other")
  assert.ok(other.text.includes("OpenRouter answered 500"))
  assert.strictEqual(M.accountNote(M.normalize(reply())).kind, "")
  assert.strictEqual(M.accountNote(null).kind, "")
})

// ------------------------------------------------------------ low + attention

test("low balance is at or below the threshold, unknown is never low", () => {
  assert.strictEqual(M.isLow(live({ remaining: 5 }), 5), true)
  assert.strictEqual(M.isLow(live({ remaining: 5.01 }), 5), false)
  assert.strictEqual(M.isLow(live({ remaining: 0 }), 0), true)
  assert.strictEqual(M.isLow(live({ remaining: null, source: "usage" }), 5), false)
  assert.strictEqual(M.isLow(M.initialView(), 5), false)
})

test("attention: low balance or any failed check (key known or unknown); the explicit no-key state is calm", () => {
  assert.strictEqual(M.attention(live({ remaining: 50 }), 5), false)
  assert.strictEqual(M.attention(live({ remaining: 2 }), 5), true)
  const fail = M.normalize({ ok: false, error: "x", keySource: "OPENROUTER_KEY" })
  assert.strictEqual(M.attention(M.reduce(M.initialView(), fail, 1), 5), true)
  assert.strictEqual(M.attention(M.reduce(live({ remaining: 50 }), M.failedResult("x"), 1), 5), true)
  const unknown = M.reduce(M.initialView(), M.normalize({ ok: false, error: "x", keySource: "" }), 1)
  assert.strictEqual(unknown.status, "offline")
  assert.strictEqual(M.attention(unknown, 5), true, "offline with an unknown key source lights the mark")
  const nokey = M.reduce(M.initialView(), M.normalize({ ok: false, noKey: true, error: "x", keySource: "" }), 1)
  assert.strictEqual(M.attention(nokey, 5), false)
  assert.strictEqual(M.attention(M.initialView(), 5), false)
  assert.strictEqual(M.attention(live({ remaining: 3 }), "5"), false, "a non-number threshold never alarms")
})

// ------------------------------------------------------------ bar label

test("bar label: the balance when known (also while stale), ! on failure, placeholder otherwise", () => {
  assert.strictEqual(M.barLabel(live()), "$74.75")
  assert.strictEqual(M.barLabel(M.reduce(live(), M.failedResult("x"), 1)), "$74.75")
  const fail = M.normalize({ ok: false, error: "x", keySource: "OPENROUTER_KEY" })
  assert.strictEqual(M.barLabel(M.reduce(M.initialView(), fail, 1)), "!")
  const nokey = M.reduce(M.initialView(), M.normalize({ ok: false, noKey: true, error: "x", keySource: "" }), 1)
  const placeholder = M.barLabel(nokey)
  assert.notStrictEqual(placeholder, "!")
  assert.ok(!/\d/.test(placeholder))
  assert.strictEqual(M.barLabel(M.initialView()), placeholder)
  assert.strictEqual(M.barLabel(live({ remaining: null, source: "usage" })), placeholder)
  for (const v of [null, undefined, {}, { status: "stale" }, { status: "stale", data: {} }])
    assert.doesNotThrow(() => { M.barLabel(v); M.attention(v, 5) })
})

// ------------------------------------------------------------ meter

test("meter: today's starting balance when today is known, else funded, else the key cap", () => {
  assert.strictEqual(M.meter(M.normalize(reply({ remaining: 75, spendToday: 25 }))).ratio, 0.75)
  assert.strictEqual(M.meter(M.normalize(reply({ remaining: 25, spendToday: null, funded: 100 }))).ratio, 0.25)
  assert.strictEqual(M.meter(M.normalize(reply({ source: "key", keyLimit: 10, keyLimitRemaining: 4, remaining: 4 }))).ratio, 0.4)
  assert.strictEqual(M.meter(M.normalize(reply({ remaining: -5, spendToday: null, funded: 100 }))).ratio, 0)
  assert.strictEqual(M.meter(M.normalize(reply({ source: "usage", remaining: null }))).ratio, -1)
})

// ------------------------------------------------------------ key allowlist

test("key allowlist: whitespace is stripped; quotes, backslashes and short keys are refused", () => {
  assert.strictEqual(M.validKey("  sk-or-v1-0123456789abcdef \n"), true)
  assert.strictEqual(M.validKey("sk-or-v1-0123\"456789abcdef"), false)
  assert.strictEqual(M.validKey("sk-or-v1-0123\\456789abcdef"), false)
  assert.strictEqual(M.validKey("short"), false)
  assert.strictEqual(M.validKey("a".repeat(257)), false)
  assert.strictEqual(M.validKey(null), false)
})

// ------------------------------------------------------------ format edges

test("money formats are chosen on the printed (rounded) figure", () => {
  assert.strictEqual(M.compactMoney(999.994), "$999.99")
  assert.strictEqual(M.compactMoney(999.995), "$1,000")
  assert.strictEqual(M.compactMoney(9999.49), "$9,999")
  assert.strictEqual(M.compactMoney(9999.99), "$10.0k")
  assert.strictEqual(M.compactMoney(10000), "$10.0k")
  assert.strictEqual(M.compactMoney(-9999.99), "-$10.0k")
  assert.strictEqual(M.compactMoney(-999.995), "-$1,000")
})

test("a zero that rounds from a negative carries no sign", () => {
  assert.strictEqual(M.compactMoney(-0), "$0.00")
  assert.strictEqual(M.money(-0), "$0.00")
  assert.strictEqual(M.money(-0.004), "$0.00")
  assert.strictEqual(M.money(-0.005), "-$0.01")
})

test("non-numbers and absurd magnitudes render as unknown, never in exponent notation", () => {
  const unknown = M.money(null)
  for (const v of [NaN, Infinity, -Infinity, "5", {}, [], undefined, true, 1e15, -1e15, 1e21, 1e25]) {
    assert.strictEqual(M.money(v), unknown, String(v))
    assert.strictEqual(M.compactMoney(v), unknown, String(v))
  }
  assert.ok(!/e\+/.test(M.money(999999999999999)))
})

test("relative age is floored: never older than it is", () => {
  const now = 1790000000 * 1000
  const age = (s) => M.relativeAge(1790000000 - s, now)
  assert.strictEqual(age(44), "just now")
  assert.strictEqual(age(-3600), "just now", "a future timestamp is not negative")
  assert.strictEqual(age(3570), "59 min ago")
  assert.strictEqual(age(3599), "59 min ago")
  assert.strictEqual(age(3600), "1 hour ago")
  assert.strictEqual(age(84600), "23 hours ago")
  assert.strictEqual(age(86400), "1 day ago")
  for (const v of [null, "1790000000", NaN, 0, -5]) assert.strictEqual(M.relativeAge(v, now), "")
})

test("server text loses invisible and bidi characters, and the cap never splits a surrogate pair", () => {
  const invisible = ["\u0007", "\u0085", "\u00ad", "\u0600", "\u061c", "\u06dd", "\u070f", "\u08e2", "\u180e",
    "\u200b", "\u200f", "\u202a", "\u202e", "\u2060", "\u2064", "\u2066", "\u206f", "\ufeff", "\ufff9", "\ufffb",
    "\u{E0001}", "\u{E0020}", "\u{E007F}"]
  for (const ch of invisible) {
    const r = M.normalize(reply({ keyLabel: "ab" + ch + "cd" }))
    assert.strictEqual(r.keyLabel, "abcd", JSON.stringify(ch))
  }
  assert.strictEqual(M.normalize(reply({ keyLabel: "caf\u00e9 \u{1F600}" })).keyLabel, "caf\u00e9 \u{1F600}", "ordinary text survives")
  const capped = M.normalize(reply({ keyLabel: "a" + "\u{1F600}".repeat(300) })).keyLabel
  assert.strictEqual(Array.from(capped).length, 200)
  assert.ok(!/[\ud800-\udbff]$/.test(capped), "ends in a lone high surrogate")
})

run()
