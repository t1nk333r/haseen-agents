// The usage ledger's arithmetic. DeepSeek reports no usage, so spend is
// measured from balance movement: these cases pin what "measured" means —
// drops are usage, rises are money added, days are local, gaps count in full.
const assert = require("node:assert/strict")
const M = require("../../DeepSeekModel.js")

let checks = 0
function ok(condition, what) {
  if (!condition) { console.error("FAIL: " + what); process.exit(1) }
  checks++
}

const at = (iso) => new Date(iso).getTime()
const sample = (total, currency) => ({ total: total, currency: currency || "USD" })

// A first sighting is a baseline, not usage: there is nothing to compare with.
let u = M.initialUsage()
u = M.usageRecord(u, sample(25.04), at("2026-09-11T09:00:00+03:00"))
ok(u.spent === 0 && u.added === 0, "the first sample spends nothing")
ok(u.lastTotal === 25.04, "the ledger keeps the last balance")
ok(u.firstSeenAt === at("2026-09-11T09:00:00+03:00"), "and when it was first seen")

// A drop is usage; several drops add up, in the day row and the total.
u = M.usageRecord(u, sample(24.92), at("2026-09-11T10:00:00+03:00"))
u = M.usageRecord(u, sample(24.80), at("2026-09-11T11:00:00+03:00"))
ok(Math.abs(u.spent - 0.24) < 1e-9, "drops accumulate as usage: " + u.spent)
ok(Math.abs(M.usageToday(u, at("2026-09-11T11:30:00+03:00")).spent - 0.24) < 1e-9,
  "the day row carries today's usage")

// A rise is money added — a top-up — never negative usage. The spend that
// happened before the top-up stays spent.
u = M.usageRecord(u, sample(45.00), at("2026-09-11T12:00:00+03:00"))
ok(Math.abs(u.spent - 0.24) < 1e-9, "a top-up is not negative usage: " + u.spent)
ok(Math.abs(u.added - 20.20) < 1e-9, "a top-up is recorded as money added: " + u.added)
ok(Math.abs(M.usageToday(u, at("2026-09-11T12:30:00+03:00")).added - 20.20) < 1e-9,
  "the day row carries today's top-ups")
u = M.usageRecord(u, sample(44.50), at("2026-09-11T13:00:00+03:00"))
ok(Math.abs(u.spent - 0.74) < 1e-9, "usage resumes after a top-up: " + u.spent)

// A gap — the shell was off, the machine slept — counts in full: the money
// left the account while nothing was watching.
u = M.usageRecord(u, sample(40.50), at("2026-09-11T20:00:00+03:00"))
ok(Math.abs(u.spent - 4.74) < 1e-9, "a gap's spend is counted in full: " + u.spent)

// Days are local: the same instant in two zones falls in two different days,
// which is why the ledger asks the operator's clock, not UTC.
const rollover = at("2026-09-12T00:30:00+03:00")
u = M.usageRecord(u, sample(40.20), at("2026-09-12T00:30:00+03:00"))
ok(M.usageDayKey(rollover) === "2026-09-12", "the day key is the local day")
ok(Math.abs(M.usageToday(u, rollover).spent - 0.30) < 1e-9,
  "after local midnight the day row starts again: " + M.usageToday(u, rollover).spent)
ok(Math.abs(u.spent - 5.04) < 1e-9, "while the total keeps every day: " + u.spent)

// A different currency is a different account of money: start over.
const switched = M.usageRecord(u, sample(100, "CNY"), at("2026-09-12T01:00:00+03:00"))
ok(switched.spent === 0 && switched.added === 0, "a currency switch resets the ledger")
ok(switched.currency === "CNY", "the new series is in the new currency")
// The switching sample is the new baseline: one fresh day, carrying no spend
// and no top-up, and none of the old currency's history.
ok(switched.days.length === 1 && switched.days[0].spent === 0 && switched.days[0].added === 0,
  "and starts a fresh series with the switching sample as its baseline")
ok(switched.lastTotal === 100, "which remembers where the new series began")

// The file round-trips, and anything unusable reads as a fresh ledger rather
// than throwing: a truncated file costs history, never the widget.
const text = M.usageToText(u)
const back = M.usageFromText(text)
ok(Math.abs(back.spent - u.spent) < 1e-9 && back.days.length === u.days.length,
  "the ledger survives a round trip through the file")
ok(M.usageFromText("").spent === 0, "an empty file is a fresh ledger")
ok(M.usageFromText("{").spent === 0, "a truncated file is a fresh ledger")
ok(M.usageFromText('{"version":99,"spent":9}').spent === 0, "a foreign version is a fresh ledger")
const partial = M.usageFromText('{"version":2,"currency":"USD","spent":3,"days":[{"date":"2026-09-11","spent":3},{"date":"nonsense","spent":9}]}')
ok(partial.spent === 3 && partial.days.length === 1, "a bad day row is dropped, the rest is kept")

// A clock that goes backwards must not invent usage.
const before = M.usageRecord(M.initialUsage(), sample(10), at("2026-09-11T10:00:00+03:00"))
const backwards = M.usageRecord(before, sample(5), at("2026-09-11T09:00:00+03:00"))
ok(backwards.spent === 0, "a backwards clock records nothing")

// Retention: a year of days is the bound, the totals are not.
let long = M.initialUsage()
for (let d = 0; d < 370; d++) {
  const day = new Date(at("2026-01-01T12:00:00+03:00") + d * 86400000)
  long = M.usageRecord(long, sample(100 - d), day.getTime())
}
ok(long.days.length === 366, "the day rows are pruned to a year: " + long.days.length)
ok(long.days[long.days.length - 1].date > long.days[0].date, "the newest days are the ones kept")

// Spend is recorded per pricing state, because DeepSeek's off-peak rate is
// half the peak rate: the same money buys twice the tokens off-peak, so a
// single-rate conversion would double-count an off-peak evening.
let priced = M.initialUsage()
priced = M.usageRecord(priced, { total: 100, currency: "USD", peak: false }, at("2026-09-11T12:00:00+03:00"))
priced = M.usageRecord(priced, { total: 99.625, currency: "USD", peak: false }, at("2026-09-11T12:10:00+03:00"))
priced = M.usageRecord(priced, { total: 98.875, currency: "USD", peak: true }, at("2026-09-11T12:20:00+03:00"))
ok(Math.abs(priced.spentPeak - 0.75) < 1e-9, "peak spend is kept apart: " + priced.spentPeak)
ok(Math.abs(priced.spentOffPeak - 0.375) < 1e-9, "off-peak spend is kept apart: " + priced.spentOffPeak)
ok(Math.abs(priced.spent - 1.125) < 1e-9, "and the two still add up to the measured spend")

// The estimate: flash peak is (0.30 + 1.20) / 2 = $0.75 per 1M, and off-peak
// is half of that, so $0.375 off-peak and $0.75 peak are a million tokens each.
const flashTokens = M.usageTokens(priced.spentPeak, priced.spentOffPeak, "USD", "deepseek-flash")
ok(flashTokens === 2000000, "the estimate converts each state at its own rate: " + flashTokens)
ok(Math.abs(M.tokenRatePerMillion("deepseek-flash", true) - 0.75) < 1e-9, "flash peak rate")
ok(Math.abs(M.tokenRatePerMillion("deepseek-flash", false) - 0.375) < 1e-9, "flash off-peak is half")
const proTokens = M.usageTokens(priced.spentPeak, priced.spentOffPeak, "USD", "deepseek-v4-pro")
ok(proTokens < flashTokens, "the pro model buys fewer tokens for the same money: " + proTokens)
ok(M.usageTokens(1, 1, "CNY", "deepseek-flash") === null,
  "a currency with no published rate table gets no estimate")
ok(M.usageTokens(0, 0, "USD", "deepseek-flash") === 0, "no spend is no tokens")

// Tokens read compactly, at the magnitudes an API bill actually reaches.
ok(M.formatTokens(980) === "980", "tokens under a thousand: " + M.formatTokens(980))
ok(M.formatTokens(12400) === "12.4K", "thousands: " + M.formatTokens(12400))
ok(M.formatTokens(1240000) === "1.24M", "millions: " + M.formatTokens(1240000))
ok(M.formatTokens(2400000000) === "2.40B", "billions: " + M.formatTokens(2400000000))

// v1 ledgers (spend with no pricing split) read as fresh rather than being
// guessed at: a wrong token figure is worse than a restart.
ok(M.usageFromText('{"version":1,"spent":9,"days":[]}').spent === 0,
  "an older ledger version starts over")

// "Since" reads as a short date, and nothing else is invented.
ok(M.usageSinceText(u, at("2026-09-12T00:00:00+03:00")) === "11 Sep",
  "the total says since when, without the year inside the same year: " + M.usageSinceText(u, at("2026-09-12T00:00:00+03:00")))
ok(M.usageSinceText(u, at("2027-01-02T00:00:00+03:00")) === "11 Sep 2026",
  "and with the year once it is a different one")
ok(M.usageSinceText(M.initialUsage()) === "", "and says nothing before the first sample")

console.log("usage.test.js: all checks passed (" + checks + ")")
