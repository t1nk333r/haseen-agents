// DeepSeek peak/off-peak schedule math (pure JS, QML + Node shared).
// Peak windows fixed in UTC: 01:00-04:00 and 06:00-10:00, Mon-Fri.
// Everything else (weekends included) is off-peak at exactly half price.
// Source: https://api-docs.deepseek.com/quick_start/pricing/ (effective 2026-08-16)
//
// The schedule is defined in UTC, but the operator reads their own clock, so
// every rendered time goes through the fixed offset below. Riyadh is UTC+3
// year-round (no DST), which is what makes a fixed shift exact rather than an
// approximation. The window constants are the single source of truth: the
// drawn schedule, the labels and the boundaries all derive from them.

var TZ_OFFSET_MINUTES = 180 // UTC+3
var TZ_LABEL = "UTC+3"
var PEAK_WINDOWS_UTC = [
  [1, 4], // 01:00-04:00 UTC
  [6, 10] // 06:00-10:00 UTC
]

function isPeakAt(date) {
  var day = date.getUTCDay()
  if (day === 0 || day === 6) return false
  var hour = date.getUTCHours()
  for (var i = 0; i < PEAK_WINDOWS_UTC.length; i++) {
    if (hour >= PEAK_WINDOWS_UTC[i][0] && hour < PEAK_WINDOWS_UTC[i][1]) return true
  }
  return false
}

// Next UTC top-of-hour where the peak state flips. Hourly scan is fine: the
// furthest a flip can be is Fri 10:00 UTC -> Mon 01:00 UTC (63 hours).
// ponytail: naive hourly forward scan, guard 200; replace with direct
// boundary math only if the flip list ever stops being hour-aligned.
function nextChange(date) {
  var top = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(),
    date.getUTCDate(), date.getUTCHours())
  if (top <= date.getTime()) top += 3600000
  var current = isPeakAt(date)
  for (var i = 0; i < 200; i++) {
    if (isPeakAt(new Date(top)) !== current) return new Date(top)
    top += 3600000
  }
  return new Date(top)
}

function pad(value) {
  return value < 10 ? "0" + value : "" + value
}

function formatClock(ms) {
  var total = Math.max(0, Math.floor(ms / 1000))
  return pad(Math.floor(total / 3600)) + ":"
    + pad(Math.floor(total % 3600 / 60)) + ":" + pad(total % 60)
}

function formatCompact(ms) {
  var total = Math.max(0, Math.round(ms / 60000))
  var hours = Math.floor(total / 60)
  var mins = total % 60
  return hours > 0 ? hours + "h " + mins + "m" : mins + "m"
}

// An instant rendered in the operator's zone: the same moment, shifted by the
// fixed offset and labelled, so it can never be read as UTC by mistake.
function formatLocal(date) {
  var shifted = new Date(date.getTime() + TZ_OFFSET_MINUTES * 60000)
  return pad(shifted.getUTCHours()) + ":" + pad(shifted.getUTCMinutes())
    + " " + TZ_LABEL
}

// The schedule the panel prints, in the same zone: "04:00-07:00, 09:00-13:00
// UTC+3". Derived from PEAK_WINDOWS_UTC so a window edit cannot drift from the
// text that describes it.
function peakWindowsLabel() {
  var parts = []
  for (var i = 0; i < PEAK_WINDOWS_UTC.length; i++) {
    parts.push(clockAt(PEAK_WINDOWS_UTC[i][0]) + "-" + clockAt(PEAK_WINDOWS_UTC[i][1]))
  }
  return parts.join(", ") + " " + TZ_LABEL
}

function clockAt(utcHour) {
  var minutes = (((utcHour * 60 + TZ_OFFSET_MINUTES) % 1440) + 1440) % 1440
  return pad(Math.floor(minutes / 60)) + ":" + pad(minutes % 60)
}

if (typeof module !== "undefined") {
  module.exports = {
    isPeakAt: isPeakAt,
    nextChange: nextChange,
    formatClock: formatClock,
    formatCompact: formatCompact,
    formatLocal: formatLocal,
    peakWindowsLabel: peakWindowsLabel
  }
}
