const assert = require("assert")
const P = require("../../Pricing.js")

const T = s => new Date(s)
const eq = (a, b, msg) => assert.strictEqual(a, b, msg)

// --- isPeakAt: peak windows 01-04 and 06-10 UTC Mon-Fri, weekend off-peak
eq(P.isPeakAt(T("2026-08-24T02:30:00Z")), true, "Mon 02:30 peak")        // Mon
eq(P.isPeakAt(T("2026-08-24T03:59:59Z")), true, "Mon 03:59 peak")        // Mon
eq(P.isPeakAt(T("2026-08-24T04:00:00Z")), false, "Mon 04:00 off-peak")
eq(P.isPeakAt(T("2026-08-24T06:00:00Z")), true, "Mon 06:00 peak")
eq(P.isPeakAt(T("2026-08-24T09:59:00Z")), true, "Mon 09:59 peak")
eq(P.isPeakAt(T("2026-08-24T10:00:00Z")), false, "Mon 10:00 off-peak")
eq(P.isPeakAt(T("2026-08-24T12:00:00Z")), false, "Mon noon off-peak")
eq(P.isPeakAt(T("2026-08-29T10:00:00Z")), false, "Sat 10:00 off-peak")
eq(P.isPeakAt(T("2026-08-28T03:00:00Z")), true, "Fri 03:00 peak")
eq(P.isPeakAt(T("2026-08-29T03:00:00Z")), false, "Sat 03:00 off-peak")
eq(P.isPeakAt(T("2026-08-30T08:00:00Z")), false, "Sun 08:00 off-peak")

// --- nextChange
eq(P.nextChange(T("2026-08-24T02:00:00Z")).toISOString(),
  "2026-08-24T04:00:00.000Z", "Mon 02:00 -> 04:00")
eq(P.nextChange(T("2026-08-24T05:00:00Z")).toISOString(),
  "2026-08-24T06:00:00.000Z", "Mon 05:00 -> 06:00")
eq(P.nextChange(T("2026-08-24T04:00:00Z")).toISOString(),
  "2026-08-24T06:00:00.000Z", "Mon 04:00 -> 06:00")
eq(P.nextChange(T("2026-08-24T23:59:00Z")).toISOString(),
  "2026-08-25T01:00:00.000Z", "Mon 23:59 -> Tue 01:00")
eq(P.nextChange(T("2026-08-28T12:00:00Z")).toISOString(),
  "2026-08-31T01:00:00.000Z", "Fri noon -> Mon 01:00")
eq(P.nextChange(T("2026-08-30T10:00:00Z")).toISOString(),
  "2026-08-31T01:00:00.000Z", "Sat -> Mon 01:00")

// --- formatters
eq(P.formatClock(0), "00:00:00")
eq(P.formatClock(3661000), "01:01:01")
eq(P.formatClock(-5000), "00:00:00")
eq(P.formatCompact(3600000 * 2 + 60000 * 31), "2h 31m")
eq(P.formatCompact(60000 * 5), "5m")
// Rendered clocks are the operator's zone: the same instant, +3, labelled.
eq(P.formatLocal(T("2026-08-24T02:05:00Z")), "05:05 UTC+3")
// The schedule the panel prints comes from the same window constants, so the
// text cannot describe windows the math no longer uses.
eq(P.peakWindowsLabel(), "04:00-07:00, 09:00-13:00 UTC+3")

console.log("pricing.js: all checks passed")