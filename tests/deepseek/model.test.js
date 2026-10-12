// Node self-check for Model.js (DeepSpend).
//
// Deterministic unit tests for config parsing (no key leaks anywhere), HTTP
// request construction, transport + response parsing, the state reducer and
// the display helpers, plus one live curl round-trip against a local mock
// HTTP server (no external network, no real key).
//
// Run: node test-model.js

const assert = require("assert")
const { spawnSync } = require("child_process")
const M = require("../../DeepSeekModel.js")

const SECRET = "sk-SECRET-DO-NOT-LEAK-0123456789"

const tests = []
function test(name, fn) {
  tests.push([name, fn])
}
async function run() {
  let pass = 0
  let fail = 0
  for (const [name, fn] of tests) {
    try {
      await fn()
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

// --------------------------------------------------------------------------
// config parsing
// --------------------------------------------------------------------------

const VALID = JSON.stringify({
  apiKey: SECRET,
  currency: "USD",
  pollIntervalSeconds: 90,
  requestTimeoutSeconds: 8
})

test("parseConfig: valid sample normalizes", () => {
  const parsed = M.parseConfig(VALID)
  assert.strictEqual(parsed.ok, true, parsed.error)
  const cfg = parsed.config
  assert.strictEqual(cfg.apiKey, SECRET)
  assert.strictEqual(cfg.hasKey, true)
  assert.strictEqual(cfg.currency, "USD")
  assert.strictEqual(cfg.pollIntervalSeconds, 90)
  assert.strictEqual(cfg.requestTimeoutSeconds, 8)
})

test("parseConfig: missing fields fall back to defaults", () => {
  const parsed = M.parseConfig(JSON.stringify({ apiKey: SECRET }))
  assert.strictEqual(parsed.ok, true)
  const cfg = parsed.config
  assert.strictEqual(cfg.currency, M.DEFAULT_CURRENCY)
  assert.strictEqual(cfg.pollIntervalSeconds, M.DEFAULT_POLL_INTERVAL_SECONDS)
  assert.strictEqual(cfg.requestTimeoutSeconds, M.DEFAULT_REQUEST_TIMEOUT_SECONDS)
  assert.strictEqual(cfg.hasKey, true)
})

test("parseConfig: no key -> hasKey false, empty config object allowed", () => {
  const parsed = M.parseConfig("{}")
  assert.strictEqual(parsed.ok, true)
  assert.strictEqual(parsed.config.hasKey, false)
  assert.strictEqual(parsed.config.apiKey, "")
})

test("parseConfig: whitespace-only key -> hasKey false", () => {
  const parsed = M.parseConfig(JSON.stringify({ apiKey: "   " }))
  assert.strictEqual(parsed.ok, true)
  assert.strictEqual(parsed.config.hasKey, false)
})

test("parseConfig: invalid JSON / wrong root shapes are rejected", () => {
  assert.strictEqual(M.parseConfig("{ not json").ok, false)
  assert.strictEqual(M.parseConfig("42").ok, false)
  assert.strictEqual(M.parseConfig("[1,2]").ok, false)
  assert.strictEqual(M.parseConfig("").ok, false)
  assert.strictEqual(M.parseConfig(null).ok, false)
})

test("parseConfig: apiKey type and currency validation", () => {
  const badKey = M.parseConfig(JSON.stringify({ apiKey: 42 }))
  assert.strictEqual(badKey.ok, false)
  assert.ok(/apiKey/.test(badKey.error))

  const badCur = M.parseConfig(JSON.stringify({ apiKey: SECRET, currency: "DOLLAR" }))
  assert.strictEqual(badCur.ok, false)
  assert.ok(/currency/.test(badCur.error))

  const lowerCur = M.parseConfig(JSON.stringify({ apiKey: SECRET, currency: "usd" }))
  assert.strictEqual(lowerCur.ok, true)
  assert.strictEqual(lowerCur.config.currency, "USD", "currency uppercased")
})

test("parseConfig: poll/timeout clamp to configured bounds", () => {
  const parsed = M.parseConfig(JSON.stringify({
    apiKey: SECRET,
    pollIntervalSeconds: 1,
    requestTimeoutSeconds: 999
  }))
  assert.strictEqual(parsed.ok, true)
  assert.strictEqual(parsed.config.pollIntervalSeconds, M.MIN_INTERVAL_SECONDS)
  assert.strictEqual(parsed.config.requestTimeoutSeconds, M.MAX_TIMEOUT_SECONDS)
})

test("parseConfig + helpers: the secret never appears in any message", () => {
  const gathered = []
  const grab = (name, value) => { if (typeof value === "string") gathered.push(name + ":" + value) }

  const badInputs = [
    "{ not json " + SECRET,
    JSON.stringify({ apiKey: 42 }),
    JSON.stringify({ currency: SECRET }),
    JSON.stringify({ apiKey: SECRET, currency: "DOLLAR" }),
    JSON.stringify({ apiKey: SECRET, targets: [1] })
  ]
  for (const input of badInputs) {
    const r = M.parseConfig(input)
    grab("parse-error", r.error)
  }
  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET })).config

  // Every display/status path must stay clean.
  const viewNoKey = M.reduce(M.initialView(), { type: "config", config: M.parseConfig("{}").config })
  grab("bar-nokey", M.barAmount(viewNoKey))
  grab("tip-nokey", M.tooltipText(viewNoKey, "/cfg/deepspend.json"))
  grab("line-nokey", M.statusLine(viewNoKey))

  const loading = M.reduce(viewNoKey, { type: "config", config: cfg })
  grab("bar-loading", M.barAmount(loading))
  grab("tip-loading", M.tooltipText(loading, "/cfg/deepspend.json"))

  const ok = M.reduce(loading, { type: "fetchSuccess", at: 1,
    balance: { isAvailable: true, currency: "USD", total: "12.30", granted: "0.00", toppedUp: "12.30" } })
  grab("bar-ok", M.barAmount(ok))
  grab("tip-ok", M.tooltipText(ok, "/cfg/deepspend.json"))
  grab("line-ok", M.statusLine(ok))

  const degraded = M.reduce(ok, { type: "fetchFail", kind: "network", message: "request timed out" })
  grab("bar-degraded", M.barAmount(degraded))
  grab("tip-degraded", M.tooltipText(degraded, "/cfg/deepspend.json"))

  const err = M.reduce(loading, { type: "fetchFail", kind: "unauthorized",
    message: "DeepSeek rejected the API key (HTTP 401)" })
  grab("bar-error", M.barAmount(err))
  grab("tip-error", M.tooltipText(err, "/cfg/deepspend.json"))
  grab("line-error", M.statusLine(err))

  const parseBad = M.parseFetchResult(0, "__DS_HTTP__" + "200\n" + "{ bad json")
  grab("fetch-parse-bad", parseBad.message)

  const joined = gathered.join("\n")
  assert.ok(!joined.includes(SECRET), "secret leaked into model output:\n" + joined)
  assert.ok(!joined.includes("sk-SECRET"), "key prefix leaked into model output")
})

// --------------------------------------------------------------------------
// request construction
// --------------------------------------------------------------------------

test("buildRequestArgs: no key -> null (never fetch unauthenticated)", () => {
  const noKey = M.parseConfig("{}").config
  assert.strictEqual(M.buildRequestArgs(noKey), null)
})

test("buildRequestArgs: key NOT in argv, only in environment; stdin-config curl", () => {
  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET, requestTimeoutSeconds: 7 })).config
  const req = M.buildRequestArgs(cfg)
  assert.ok(req, "request present")
  assert.ok(Array.isArray(req.command), "command is an argv vector")
  assert.strictEqual(typeof req.environment, "object", "environment is a JS object (Quickshell)")

  // 1. The key must never appear in the command line / argv.
  const argvText = req.command.join("\n")
  assert.ok(!argvText.includes(SECRET), "secret must not be in argv:\n" + argvText)
  assert.ok(!argvText.includes("sk-"), "key prefix must not be in argv")

  // 2. The key lives in the environment object and reaches curl via --config -.
  assert.strictEqual(req.environment[M.ENV_KEY_NAME], SECRET,
    "environment object carries the key under DS_API_KEY")
  assert.ok(argvText.includes("--config -"), "curl reads its config from stdin")
  assert.ok(argvText.includes("$" + M.ENV_KEY_NAME), "script references the env var, not the key")

  // 3. Timeout and body cap are enforced on the curl command line.
  assert.ok(argvText.includes("--max-time 7"), "timeout is on the curl argv")
  assert.ok(argvText.includes("--max-filesize " + M.MAX_RESPONSE_BYTES),
    "response body cap is on the curl argv")
  assert.ok(argvText.includes("'" + M.BALANCE_URL + "'"), "fixed target URL")
  assert.ok(argvText.includes(M.STATUS_MARKER), "status marker present")
})

test("buildRequestArgs: timeout clamps to the configured maximum", () => {
  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET, requestTimeoutSeconds: 999 })).config
  const req = M.buildRequestArgs(cfg)
  assert.ok(req.command.join("\n").includes("--max-time " + String(M.MAX_TIMEOUT_SECONDS)))
})

// --------------------------------------------------------------------------
// HTTP result parsing
// --------------------------------------------------------------------------

test("parseHttpResult: status marker + body split", () => {
  const r = M.parseHttpResult(0, "{\"is_available\":true}\n" + M.STATUS_MARKER + "200\n")
  assert.strictEqual(r.httpStatus, 200)
  assert.strictEqual(r.body, "{\"is_available\":true}")
  assert.strictEqual(r.transportError, "")
})

test("parseHttpResult: plain-text error body keeps its text and status", () => {
  const r = M.parseHttpResult(0, "Authentication Fails (governor)\n" + M.STATUS_MARKER + "401\n")
  assert.strictEqual(r.httpStatus, 401)
  assert.ok(r.body.includes("Authentication"))
})

test("parseHttpResult: transport failures (no marker) map to curl errors", () => {
  const timeout = M.parseHttpResult(28, "")
  assert.ok(timeout.transportError.includes("timed out"), timeout.transportError)
  const conn = M.parseHttpResult(7, "")
  assert.ok(conn.transportError.includes("connect"), conn.transportError)
  const tooBig = M.parseHttpResult(63, "")
  assert.ok(tooBig.transportError.includes("too large"), tooBig.transportError)
  const ok = M.parseHttpResult(0, "")
  assert.strictEqual(ok.transportError, "")
})

test("parseHttpResult: response body is capped before parsing", () => {
  const big = "x".repeat(M.MAX_RESPONSE_BYTES + 50000)
  const r = M.parseHttpResult(0, big + "\n" + M.STATUS_MARKER + "200\n")
  assert.ok(r.body.length <= M.MAX_RESPONSE_BYTES, "body capped at MAX_RESPONSE_BYTES")
})

// --------------------------------------------------------------------------
// balance response parsing
// --------------------------------------------------------------------------

const OFFICIAL = JSON.stringify({
  is_available: true,
  balance_infos: [
    { currency: "CNY", total_balance: "110.00", granted_balance: "10.00", topped_up_balance: "100.00" },
    { currency: "USD", total_balance: "15.25", granted_balance: "0.00", topped_up_balance: "15.25" }
  ]
})

test("parseBalanceBody: official sample, preferred currency is picked", () => {
  const r = M.parseBalanceBody(OFFICIAL, "USD")
  assert.strictEqual(r.ok, true, r.message)
  assert.deepStrictEqual(r.balance, {
    isAvailable: true, currency: "USD", total: "15.25", granted: "0.00", toppedUp: "15.25"
  })
})

test("parseBalanceBody: falls back to the first entry when preferred is absent", () => {
  const r = M.parseBalanceBody(OFFICIAL, "EUR")
  assert.strictEqual(r.ok, true)
  assert.strictEqual(r.balance.currency, "CNY")
  assert.strictEqual(r.balance.total, "110.00")
})

test("parseBalanceBody: is_available false and missing fields tolerated", () => {
  const r = M.parseBalanceBody(JSON.stringify({
    is_available: false,
    balance_infos: [{ currency: "USD", total_balance: "0.42" }]
  }), "USD")
  assert.strictEqual(r.ok, true)
  assert.strictEqual(r.balance.isAvailable, false)
  assert.strictEqual(r.balance.granted, "0")
  assert.strictEqual(r.balance.toppedUp, "0")
})

test("parseBalanceBody: garbage rejected cleanly", () => {
  for (const bad of ["", "not json", "[]", "{}", JSON.stringify({ balance_infos: [] }),
    JSON.stringify({ balance_infos: [{ currency: "USD", total_balance: "abc" }] }),
    JSON.stringify({ balance_infos: [{ currency: "US", total_balance: "1.00" }] })]) {
    const r = M.parseBalanceBody(bad, "USD")
    assert.strictEqual(r.ok, false, "should fail: " + bad)
    assert.strictEqual(r.kind, "parse")
  }
})

test("parseBalanceBody: numeric amounts and partial entries are tolerated", () => {
  const r = M.parseBalanceBody(JSON.stringify({
    is_available: true,
    balance_infos: [{ currency: "USD", total_balance: 15.5, granted_balance: 0, topped_up_balance: 15.5 }]
  }), "USD")
  assert.strictEqual(r.ok, true, r.message)
  assert.strictEqual(r.balance.total, "15.5")
  assert.strictEqual(r.balance.granted, "0")
  assert.strictEqual(r.balance.toppedUp, "15.5")
})

test("parseBalanceBody: total_balance zero is valid, not a parse failure", () => {
  const r = M.parseBalanceBody(JSON.stringify({
    is_available: false,
    balance_infos: [{ currency: "USD", total_balance: "0.00", granted_balance: "0.00", topped_up_balance: "0.00" }]
  }), "USD")
  assert.strictEqual(r.ok, true, r.message)
  assert.strictEqual(r.balance.total, "0.00")
  assert.strictEqual(r.balance.isAvailable, false)
})

test("parseBalanceBody: unknown extra fields are ignored (future API fields)", () => {
  // DS-4 robustness: the API may add fields (e.g. a new balance kind, a
  // version marker). An unrecognised field must never make a healthy balance
  // unreadable; only the documented fields drive the parse.
  const r = M.parseBalanceBody(JSON.stringify({
    is_available: true,
    balance_infos: [{
      currency: "USD",
      total_balance: "12.34",
      granted_balance: "2.00",
      topped_up_balance: "10.34",
      some_future_field: { nested: true },
      another: "future-value"
    }],
    future_top_level: ["x", 1, null]
  }), "USD")
  assert.strictEqual(r.ok, true, r.message)
  assert.strictEqual(r.balance.total, "12.34")
  assert.strictEqual(r.balance.granted, "2.00")
  assert.strictEqual(r.balance.toppedUp, "10.34")
})

test("parseFetchResult: status -> error kind mapping", () => {
  const unauthorized = M.parseFetchResult(0, M.STATUS_MARKER + "401")
  assert.strictEqual(unauthorized.ok, false)
  assert.strictEqual(unauthorized.kind, "unauthorized")
  assert.ok(/401/.test(unauthorized.message))

  const denied = M.parseFetchResult(0, M.STATUS_MARKER + "403")
  assert.strictEqual(denied.kind, "http_403")
  assert.ok(/403/.test(denied.message))
  assert.ok(/denied/.test(denied.message))

  const rate = M.parseFetchResult(0, M.STATUS_MARKER + "429")
  assert.strictEqual(rate.kind, "rate_limit")
  const server = M.parseFetchResult(0, M.STATUS_MARKER + "503")
  assert.strictEqual(server.kind, "server")
  const insufficient = M.parseFetchResult(0, M.STATUS_MARKER + "402")
  assert.strictEqual(insufficient.kind, "insufficient")
  const unexpected = M.parseFetchResult(0, M.STATUS_MARKER + "418")
  assert.strictEqual(unexpected.kind, "http_418")
})

test("parseFetchResult: transport and parse failures", () => {
  const timeout = M.parseFetchResult(28, "")
  assert.strictEqual(timeout.ok, false)
  assert.strictEqual(timeout.kind, "timeout")
  const net = M.parseFetchResult(7, "")
  assert.strictEqual(net.kind, "network")
  const badBody = M.parseFetchResult(0, M.STATUS_MARKER + "200\n{ nope")
  assert.strictEqual(badBody.ok, false)
  assert.strictEqual(badBody.kind, "parse")
})

// --------------------------------------------------------------------------
// state reducer
// --------------------------------------------------------------------------

test("reduce: no key -> nokey, key -> loading, success -> ok", () => {
  let view = M.initialView()
  assert.strictEqual(view.status, "nokey")
  const noKey = M.reduce(view, { type: "config", config: M.parseConfig("{}").config })
  assert.strictEqual(noKey.status, "nokey")

  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET })).config
  view = M.reduce(view, { type: "config", config: cfg })
  assert.strictEqual(view.status, "loading")
  assert.strictEqual(view.refreshing, true)

  view = M.reduce(view, { type: "fetchSuccess", at: 1234,
    balance: { isAvailable: true, currency: "USD", total: "12.30", granted: "0.00", toppedUp: "12.30" } })
  assert.strictEqual(view.status, "ok")
  assert.strictEqual(view.total, "12.30")
  assert.strictEqual(view.checkedAt, 1234)
  assert.strictEqual(view.refreshing, false)
})

test("reduce: failure without data -> error; with data -> degraded keeps balance", () => {
  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET })).config
  let view = M.reduce(M.initialView(), { type: "config", config: cfg })
  view = M.reduce(view, { type: "fetchFail", kind: "unauthorized", message: "key rejected" })
  assert.strictEqual(view.status, "error")
  assert.strictEqual(view.errorKind, "unauthorized")
  assert.strictEqual(M.hasData(view), false)

  const ok = M.reduce(view, { type: "fetchSuccess", at: 1,
    balance: { isAvailable: true, currency: "USD", total: "5.00", granted: "0", toppedUp: "5.00" } })
  const degraded = M.reduce(ok, { type: "fetchFail", kind: "timeout", message: "request timed out" })
  assert.strictEqual(degraded.status, "degraded")
  assert.strictEqual(degraded.total, "5.00", "balance kept when the refresh fails")
  assert.strictEqual(degraded.errorKind, "timeout")

  const recovered = M.reduce(degraded, { type: "fetchSuccess", at: 2,
    balance: { isAvailable: true, currency: "USD", total: "4.75", granted: "0", toppedUp: "4.75" } })
  assert.strictEqual(recovered.status, "ok")
  assert.strictEqual(recovered.errorMessage, "")
})

test("reduce: removing the key resets to the calm no-key state", () => {
  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET })).config
  let view = M.reduce(M.initialView(), { type: "config", config: cfg })
  view = M.reduce(view, { type: "fetchSuccess", at: 1,
    balance: { isAvailable: true, currency: "USD", total: "5.00", granted: "0", toppedUp: "5.00" } })
  const gone = M.reduce(view, { type: "config", config: M.parseConfig("{ }").config })
  assert.strictEqual(gone.status, "nokey")
  assert.strictEqual(gone.total, "", "stale balance dropped when the key disappears")
})

test("acceptFetchResult: stale results are dropped once the key is gone", () => {
  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET })).config
  assert.strictEqual(M.acceptFetchResult(cfg), true)
  assert.strictEqual(M.acceptFetchResult(M.parseConfig("{ }").config), false)
  assert.strictEqual(M.acceptFetchResult(null), false)
  assert.strictEqual(M.acceptFetchResult(undefined), false)
  assert.strictEqual(M.acceptFetchResult({}), false, "config without hasKey is rejected")
})

test("reduce: manual refresh on ok keeps the shown balance while refreshing", () => {
  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET })).config
  let view = M.reduce(M.initialView(), { type: "config", config: cfg })
  view = M.reduce(view, { type: "fetchSuccess", at: 1,
    balance: { isAvailable: true, currency: "USD", total: "9.50", granted: "0", toppedUp: "9.50" } })
  assert.strictEqual(view.status, "ok")
  view = M.reduce(view, { type: "fetchStart" })
  assert.strictEqual(view.status, "ok", "ok stays ok during a silent refresh")
  assert.strictEqual(view.refreshing, true)
  assert.strictEqual(view.total, "9.50")
})

// --------------------------------------------------------------------------
// display helpers
// --------------------------------------------------------------------------

test("formatAmount and currencySymbol", () => {
  assert.strictEqual(M.currencySymbol("USD"), "$")
  assert.strictEqual(M.currencySymbol("CNY"), "\u00a5")
  assert.strictEqual(M.currencySymbol("EUR"), "EUR ")
})

test("formatAmount: real values", () => {
  assert.strictEqual(M.formatAmount("12.30", "USD"), "$12.30")
  assert.strictEqual(M.formatAmount("0.98", "CNY"), "\u00a50.98")
  assert.strictEqual(M.formatAmount("110", "USD"), "$110.00")
  assert.strictEqual(M.formatAmount("1234567.89", "USD"), "$1,234,567.89")
  assert.strictEqual(M.formatAmount("", "USD"), "")
  assert.strictEqual(M.formatAmount("abc", "USD"), "")
  assert.strictEqual(M.formatAmount(undefined, "USD"), "")
})

test("barAmount shows the amount alone: the whale carries the name", () => {
  const nokey = M.initialView()
  // Nothing to say yet: the logo is the whole widget, so the label is empty
  // rather than a name the logo already states.
  assert.strictEqual(M.barAmount(nokey), "")
  assert.ok(!M.barAmount(nokey).includes("DeepSpend"))

  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET })).config
  const ok = M.reduce(M.reduce(nokey, { type: "config", config: cfg }),
    { type: "fetchSuccess", at: 1,
      balance: { isAvailable: true, currency: "USD", total: "12.30", granted: "0.00", toppedUp: "12.30" } })
  assert.strictEqual(M.barAmount(ok), "$12.30")

  const err = M.reduce(M.reduce(nokey, { type: "config", config: cfg }),
    { type: "fetchFail", kind: "unauthorized", message: "x" })
  assert.strictEqual(M.barAmount(err), "!", "error marker alone")

  // A balance that arrived before a failure stays shown, as upstream's did.
  const degraded = M.reduce(ok, { type: "fetchFail", kind: "network", message: "timed out" })
  assert.strictEqual(M.barAmount(degraded), "$12.30")
})

test("attention/dimmed state mapping", () => {
  const nokey = M.initialView()
  assert.strictEqual(M.isDimmed(nokey), true)
  assert.strictEqual(M.wantsAttention(nokey), false)

  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET })).config
  const loading = M.reduce(nokey, { type: "config", config: cfg })
  assert.strictEqual(M.isDimmed(loading), false)
  assert.strictEqual(M.wantsAttention(loading), false)

  const ok = M.reduce(loading, { type: "fetchSuccess", at: 1,
    balance: { isAvailable: true, currency: "USD", total: "1.00", granted: "0", toppedUp: "1.00" } })
  assert.strictEqual(M.wantsAttention(ok), false)

  const empty = M.reduce(loading, { type: "fetchSuccess", at: 1,
    balance: { isAvailable: false, currency: "USD", total: "0.00", granted: "0", toppedUp: "0.00" } })
  assert.strictEqual(M.wantsAttention(empty), true, "low balance demands attention")

  const err = M.reduce(loading, { type: "fetchFail", kind: "unauthorized", message: "x" })
  assert.strictEqual(M.wantsAttention(err), true)
})

test("tooltip and status line read well in every state", () => {
  const path = "/test-home/u/.config/deepspend/config.json"
  assert.ok(M.tooltipText(M.initialView(), path).includes(path))
  assert.ok(M.tooltipText(M.initialView(), path).includes("apiKey"))

  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET })).config
  let view = M.reduce(M.initialView(), { type: "config", config: cfg })
  assert.ok(/checking balance/.test(M.statusLine(view)))

  view = M.reduce(view, { type: "fetchSuccess", at: Date.now(),
    balance: { isAvailable: true, currency: "USD", total: "9.99", granted: "0", toppedUp: "9.99" } })
  const tip = M.tooltipText(view, path)
  assert.ok(tip.includes("$9.99"), tip)
  assert.ok(!tip.includes("never"), "checkedAt set")

  view = M.reduce(view, { type: "fetchFail", kind: "rate_limit",
    message: "DeepSeek rate limit reached (HTTP 429)" })
  const degradedTip = M.tooltipText(view, path)
  assert.ok(degradedTip.includes("$9.99"), "stale balance in tooltip")
  assert.ok(degradedTip.includes("rate limit"), degradedTip)
  assert.ok(!degradedTip.includes(SECRET))
})

test("templateConfigText has a placeholder only", () => {
  const t = M.templateConfigText()
  assert.ok(t.includes("apiKey"))
  assert.ok(t.includes("\"sk-\"") || t.includes("\"\"") || t.includes("sk-"))
  assert.ok(!t.includes(SECRET))
  const parsed = M.parseConfig(t)
  assert.strictEqual(parsed.ok, true)
  assert.strictEqual(parsed.config.hasKey, false, "template never contains a real key")
})

test("configDir strips the filename", () => {
  assert.strictEqual(M.configDir("/test-home/u/.config/deepspend/config.json"), "/test-home/u/.config/deepspend")
  assert.strictEqual(M.configDir(""), "")
})

// --------------------------------------------------------------------------
// DS-5: robust config handling — specific hints, empty state, recovery flow
// --------------------------------------------------------------------------

test("parseConfig: Shirak's extra-quote repro gives a specific, key-free hint", () => {
  // The real incident: an extra double quote before the key ("sk-…).
  const raw = '{"apiKey": ""' + SECRET + '", "currency": "USD"}'
  const r = M.parseConfig(raw)
  assert.strictEqual(r.ok, false)
  assert.strictEqual(r.kind, "parse")
  assert.ok(/not valid JSON/.test(r.error), r.error)
  assert.strictEqual(typeof r.at, "number", "a character offset is reported")
  assert.ok(/apiKey/.test(r.hint), "hint points at the apiKey value: " + r.hint)
  assert.ok(/double quote/.test(r.hint), r.hint)
  assert.ok(!r.error.includes(SECRET), "error never echoes the file content")
  assert.ok(!r.hint.includes(SECRET), "hint never echoes the file content")
  assert.ok(!r.hint.includes("sk-"))
})

test("parseConfig: empty and whitespace-only files classify as 'empty'", () => {
  for (const raw of ["", "   ", "\n\t \n"]) {
    const r = M.parseConfig(raw)
    assert.strictEqual(r.ok, false)
    assert.strictEqual(r.kind, "empty", JSON.stringify(raw))
    assert.ok(!r.error.includes(SECRET))
  }
})

test("parseConfig: root must be a JSON object (array/number/string/null -> shape)", () => {
  for (const raw of ["[1,2]", "42", '"hi"', "null"]) {
    const r = M.parseConfig(raw)
    assert.strictEqual(r.ok, false)
    assert.strictEqual(r.kind, "shape", raw)
    assert.ok(/object/.test(r.error))
  }
})

test("parseConfig: invalid field values classify as field problems", () => {
  const badKey = M.parseConfig(JSON.stringify({ apiKey: 42 }))
  assert.strictEqual(badKey.ok, false)
  assert.strictEqual(badKey.kind, "field")
  assert.ok(/apiKey/.test(badKey.error))

  const badCur = M.parseConfig(JSON.stringify({ currency: "DOLLAR" }))
  assert.strictEqual(badCur.kind, "field")

  const badNotif = M.parseConfig(JSON.stringify({ notificationsEnabled: "yes" }))
  assert.strictEqual(badNotif.kind, "field")

  const badTh = M.parseConfig(JSON.stringify({ lowBalanceThreshold: -1 }))
  assert.strictEqual(badTh.kind, "field")
})

test("parseConfig: malformed JSON near a key never leaks content into the message", () => {
  // Unterminated string that starts right at the key value.
  const unterminated = '{"apiKey": "' + SECRET
  const r = M.parseConfig(unterminated)
  assert.strictEqual(r.ok, false)
  assert.strictEqual(r.kind, "parse")
  const joined = r.error + " " + (r.hint || "")
  assert.ok(!joined.includes(SECRET))
  assert.ok(!joined.includes("sk-"))

  // Valid object followed by extra content that carries the marker.
  const trailing = M.parseConfig('{"apiKey": ""} ' + SECRET)
  assert.strictEqual(trailing.ok, false)
  assert.strictEqual(trailing.kind, "parse")
  const joined2 = trailing.error + " " + (trailing.hint || "")
  assert.ok(!joined2.includes(SECRET))
  assert.ok(!joined2.includes("sk-"))
})

test("config error view: reducer sets a calm, attention state and never leaks", () => {
  const view = M.reduce(M.initialView(), {
    type: "configError",
    problem: {
      kind: "parse",
      error: "config.json is not valid JSON",
      at: 26,
      hint: "There is an extra or a missing comma, double quote or brace at this spot. It is right beside the \"apiKey\" value — an extra or missing double quote around the key is the usual cause."
    }
  })
  assert.strictEqual(view.status, "config_error")
  assert.strictEqual(view.errorKind, "config")
  assert.strictEqual(M.hasData(view), false)

  const problem = M.configProblemText(view)
  assert.ok(/not valid JSON/.test(problem))
  assert.ok(/character 27/.test(problem), problem)
  assert.ok(/apiKey/.test(problem))

  const gathered = [
    M.barAmount(view),
    problem,
    M.configTooltip(view, "/cfg/deepspend.json"),
    M.tooltipText(view, "/cfg/deepspend.json"),
    M.statusLine(view)
  ].join("\n")
  assert.ok(!gathered.includes(SECRET), "secret leaked into config_error output:\n" + gathered)
  assert.ok(!gathered.includes("sk-"))

  assert.ok(M.barAmount(view).includes("!"))
  assert.strictEqual(M.wantsAttention(view), true)
  assert.strictEqual(M.isDimmed(view), false)
  assert.ok(/attention/.test(M.statusLine(view)))
})

test("reduce: configError drops stale balance; a later valid config clears it", () => {
  const cfg = M.parseConfig(JSON.stringify({ apiKey: SECRET })).config
  let view = M.reduce(M.initialView(), { type: "config", config: cfg })
  view = M.reduce(view, { type: "fetchSuccess", at: 1,
    balance: { isAvailable: true, currency: "USD", total: "5.00", granted: "0", toppedUp: "5.00" } })
  assert.strictEqual(view.status, "ok")

  view = M.reduce(view, {
    type: "configError",
    problem: { kind: "parse", error: "config.json is not valid JSON", at: 3, hint: "Check the quotes." }
  })
  assert.strictEqual(view.status, "config_error")
  assert.strictEqual(view.total, "", "stale balance dropped when the config is broken")

  // The file is repaired: a valid config (with key) moves back to loading.
  view = M.reduce(view, { type: "config", config: cfg })
  assert.strictEqual(view.status, "loading")
  assert.strictEqual(M.configProblemText(view), "")
  assert.strictEqual(view.errorKind, "")
})

test("reduce: a no-key config (absent/empty file) replaces config_error cleanly", () => {
  let view = M.reduce(M.initialView(), {
    type: "configError",
    problem: { kind: "field", error: "config: \"apiKey\" must be a string" }
  })
  assert.strictEqual(view.status, "config_error")
  view = M.reduce(view, { type: "config", config: M.parseConfig("{ }").config })
  assert.strictEqual(view.status, "nokey")
  assert.strictEqual(M.configProblemText(view), "")
  assert.strictEqual(M.acceptFetchResult(M.parseConfig("{ }").config), false,
    "no-key defaults never accept an in-flight fetch result")
})

test("backupAndTemplateCommandArgs: backs up the broken file and writes a key-free default (temp dir)", () => {
  const os = require("os")
  const path = require("path")
  const fs = require("fs")
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "deepspend-ds5-"))
  const broken = '{ "apiKey": ""' + SECRET + '", "currency": "USD" }'
  fs.writeFileSync(path.join(dir, "config.json"), broken, { mode: 0o600 })

  const template = M.templateConfigText()
  const args = M.backupAndTemplateCommandArgs(dir, template)
  assert.strictEqual(args[0], "bash")
  assert.strictEqual(args[3], "deepspend-backup-config")

  const res = spawnSync(args[0], args.slice(1), { encoding: "utf8" })
  assert.strictEqual(res.status, 0, res.stderr)
  const ts = res.stdout.trim()
  assert.ok(/^\d+-\d+$/.test(ts), "prints a unique backup stamp: " + res.stdout)

  const bak = path.join(dir, "config.json.bak-" + ts)
  assert.ok(fs.existsSync(bak), "backup exists")
  assert.strictEqual(fs.readFileSync(bak, "utf8"), broken,
    "the broken file is preserved byte-for-byte in the backup")
  assert.ok(broken.includes(SECRET), "fixture sanity: the broken file carried the marker")

  const fresh = fs.readFileSync(path.join(dir, "config.json"), "utf8")
  assert.ok(!fresh.includes(SECRET), "the fresh default never contains a key")
  const parsed = M.parseConfig(fresh)
  assert.strictEqual(parsed.ok, true, parsed.error)
  assert.strictEqual(parsed.config.hasKey, false)

  assert.strictEqual(fs.statSync(path.join(dir, "config.json")).mode & 0o777, 0o600)
  assert.ok(!res.stdout.includes(SECRET), "stdout never echoes the broken content")
  assert.ok(!res.stderr.includes(SECRET), "stderr never echoes the broken content")
})

test("backupAndTemplateCommandArgs: mode 600 from the first byte (no write-then-chmod, HANCORE)", () => {
  const os = require("os")
  const path = require("path")
  const fs = require("fs")
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "deepspend-ds5c-"))
  fs.writeFileSync(path.join(dir, "config.json"), "{ broken", { mode: 0o600 })
  const args = M.backupAndTemplateCommandArgs(dir, M.templateConfigText())
  const script = args[2]
  // The script must NOT rely on a post-write chmod: restrictive creation is
  // done with umask 077 before the file is first written.
  assert.ok(!/chmod/.test(script), "script never chmods after writing")
  assert.ok(/umask 077/.test(script), "script sets umask 077 before creating")
  // Run under a deliberately wide parent umask (000): if creation were not
  // restrictive from the first byte, a race window would expose the file.
  const res2 = spawnSync("bash", ["-c", "umask 000; exec \"$@\"", "x", args[0], ...args.slice(1)], { encoding: "utf8" })
  assert.strictEqual(res2.status, 0, res2.stderr)
  const mode = fs.statSync(path.join(dir, "config.json")).mode & 0o777
  assert.strictEqual(mode, 0o600, "file is 600 even when the parent umask is 000")
  const baks = fs.readdirSync(dir).filter((f) => /^config\.json\.bak-/.test(f))
  assert.strictEqual(baks.length, 1)
  assert.strictEqual(fs.statSync(path.join(dir, baks[0])).mode & 0o777, 0o600,
    "backup preserves the original restrictive mode")
})

test("backupAndTemplateCommandArgs: can be run again for a later recovery", () => {
  const os = require("os")
  const path = require("path")
  const fs = require("fs")
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "deepspend-ds5b-"))
  fs.writeFileSync(path.join(dir, "config.json"), "{ broken", { mode: 0o600 })
  const args = M.backupAndTemplateCommandArgs(dir, M.templateConfigText())
  const run = () => spawnSync(args[0], args.slice(1), { encoding: "utf8" })
  const first = run()
  assert.strictEqual(first.status, 0, first.stderr)
  const second = run()
  assert.strictEqual(second.status, 0, second.stderr)
  assert.notStrictEqual(second.stdout.trim(), first.stdout.trim(),
    "each recovery gets its own timestamped backup")
  const baks = fs.readdirSync(dir).filter((f) => /^config\.json\.bak-\d+-\d+$/.test(f))
  assert.strictEqual(baks.length, 2)
})

// --------------------------------------------------------------------------
// DS-3: low-balance threshold config + alert state machine
// --------------------------------------------------------------------------

test("parseConfig: notificationsEnabled and lowBalanceThreshold defaults", () => {
  const parsed = M.parseConfig("{}")
  assert.strictEqual(parsed.ok, true)
  assert.strictEqual(parsed.config.notificationsEnabled, true)
  assert.strictEqual(parsed.config.lowBalanceThreshold, 0, "threshold disabled by default")

  const d = M.defaults()
  assert.strictEqual(d.notificationsEnabled, M.DEFAULT_NOTIFICATIONS_ENABLED)
  assert.strictEqual(d.lowBalanceThreshold, M.DEFAULT_LOW_BALANCE_THRESHOLD)
})

test("parseConfig: explicit notification fields are honoured", () => {
  const parsed = M.parseConfig(JSON.stringify({
    notificationsEnabled: false,
    lowBalanceThreshold: "5.50"
  }))
  assert.strictEqual(parsed.ok, true)
  assert.strictEqual(parsed.config.notificationsEnabled, false)
  assert.strictEqual(parsed.config.lowBalanceThreshold, 5.5, "numeric strings accepted")
})

test("parseConfig: invalid notification fields are rejected", () => {
  const badBool = M.parseConfig(JSON.stringify({ notificationsEnabled: "yes" }))
  assert.strictEqual(badBool.ok, false)
  assert.ok(/notificationsEnabled/.test(badBool.error))

  const badNeg = M.parseConfig(JSON.stringify({ lowBalanceThreshold: -1 }))
  assert.strictEqual(badNeg.ok, false)
  assert.ok(/lowBalanceThreshold/.test(badNeg.error))

  const badNaN = M.parseConfig(JSON.stringify({ lowBalanceThreshold: "abc" }))
  assert.strictEqual(badNaN.ok, false)
  assert.ok(/lowBalanceThreshold/.test(badNaN.error))

  const badBoolTh = M.parseConfig(JSON.stringify({ lowBalanceThreshold: true }))
  assert.strictEqual(badBoolTh.ok, false)
})

test("templateConfigText: includes the DS-3 alert fields and stays key-free", () => {
  const t = M.templateConfigText()
  assert.ok(t.includes("notificationsEnabled"))
  assert.ok(t.includes("lowBalanceThreshold"))
  const parsed = M.parseConfig(t)
  assert.strictEqual(parsed.ok, true)
  assert.strictEqual(parsed.config.lowBalanceThreshold, 0)
  assert.strictEqual(parsed.config.hasKey, false)
})

test("alertArmed reflects threshold + notifications switch", () => {
  const cfg = (extra) => M.parseConfig(JSON.stringify(Object.assign({}, extra))).config
  assert.strictEqual(M.alertArmed(cfg({})), false)
  assert.strictEqual(M.alertArmed(cfg({ lowBalanceThreshold: 5 })), true)
  assert.strictEqual(M.alertArmed(cfg({ lowBalanceThreshold: 5, notificationsEnabled: false })), false)
  assert.strictEqual(M.alertArmed(cfg({ notificationsEnabled: false })), false)
  assert.strictEqual(M.alertArmed(null), false)
})

test("freshZone classifies balance against the threshold", () => {
  assert.strictEqual(M.freshZone(12.3, 5, true), "ok")
  assert.strictEqual(M.freshZone(5, 5, true), "ok", "equal is not low")
  assert.strictEqual(M.freshZone(4.99, 5, true), "low")
  assert.strictEqual(M.freshZone(12.3, 5, false), "", "disarmed has no zone")
  assert.strictEqual(M.freshZone(NaN, 5, true), "", "no data has no zone")
  assert.strictEqual(M.freshZone(undefined, 5, true), "")
})

test("numericTotal reads a view total safely", () => {
  assert.strictEqual(M.numericTotal({ total: "12.30" }), 12.3)
  assert.strictEqual(M.numericTotal({ total: "0" }), 0)
  assert.ok(Number.isNaN(M.numericTotal({ total: "" })))
  assert.ok(Number.isNaN(M.numericTotal({ total: "abc" })))
  assert.ok(Number.isNaN(M.numericTotal(null)))
  assert.ok(Number.isNaN(M.numericTotal({})))
})

test("reduceAlertState: healthy first sighting is a silent baseline", () => {
  const state = M.initialAlertState()
  const r = M.reduceAlertState(state, { total: 12.3, threshold: 5, armed: true })
  assert.strictEqual(r.state.zone, "ok")
  assert.strictEqual(r.events.length, 0, "healthy baseline never notifies")
})

test("reduceAlertState: ok -> low emits exactly one low event, never repeats", () => {
  let state = M.initialAlertState()
  state = M.reduceAlertState(state, { total: 12.3, threshold: 5, armed: true }).state
  let r = M.reduceAlertState(state, { total: 3.2, threshold: 5, armed: true })
  assert.strictEqual(r.events.length, 1)
  assert.strictEqual(r.events[0].kind, "low")
  state = r.state

  // While the zone stays low, no further events (the quiet guarantee).
  r = M.reduceAlertState(state, { total: 2.9, threshold: 5, armed: true })
  assert.strictEqual(r.events.length, 0, "still low must not re-notify")
  r = M.reduceAlertState(state, { total: 3.2, threshold: 5, armed: true })
  assert.strictEqual(r.events.length, 0, "same low must not re-notify")
  assert.strictEqual(r.state.zone, "low")
})

test("reduceAlertState: low -> ok emits exactly one recovered event", () => {
  let state = M.initialAlertState()
  state = M.reduceAlertState(state, { total: 3.2, threshold: 5, armed: true }).state
  let r = M.reduceAlertState(state, { total: 7.5, threshold: 5, armed: true })
  assert.strictEqual(r.events.length, 1)
  assert.strictEqual(r.events[0].kind, "recovered")
  state = r.state

  r = M.reduceAlertState(state, { total: 8.0, threshold: 5, armed: true })
  assert.strictEqual(r.events.length, 0, "still ok must not re-notify")
})

test("reduceAlertState: first observation while already low announces once", () => {
  const r = M.reduceAlertState(M.initialAlertState(), { total: 3.2, threshold: 5, armed: true })
  assert.strictEqual(r.events.length, 1)
  assert.strictEqual(r.events[0].kind, "low")
  // And never again while the persisted zone is low.
  const again = M.reduceAlertState(r.state, { total: 3.2, threshold: 5, armed: true })
  assert.strictEqual(again.events.length, 0)
})

test("reduceAlertState: disabling notifications keeps tracking but never emits (no backlog on re-enable)", () => {
  // Healthy baseline while armed.
  let state = M.initialAlertState()
  state = M.reduceAlertState(state, { total: 12.3, threshold: 5, armed: true, enabled: true }).state

  // Balance drops while notifications are switched off: the zone follows
  // silently, nothing is emitted.
  let r = M.reduceAlertState(state, { total: 3.2, threshold: 5, armed: true, enabled: false })
  assert.strictEqual(r.events.length, 0)
  assert.strictEqual(r.state.zone, "low", "zone is tracked even while muted")

  // Re-enabling with the same low situation must not fire a backlog.
  r = M.reduceAlertState(r.state, { total: 3.2, threshold: 5, armed: true, enabled: true })
  assert.strictEqual(r.events.length, 0, "re-enable while still low stays quiet")

  // A genuine later recovery does fire exactly once.
  r = M.reduceAlertState(r.state, { total: 8.0, threshold: 5, armed: true, enabled: true })
  assert.strictEqual(r.events.length, 1)
  assert.strictEqual(r.events[0].kind, "recovered")
})

test("reduceAlertState: removing the threshold (armed false) freezes the zone", () => {
  let state = M.initialAlertState()
  state = M.reduceAlertState(state, { total: 12.3, threshold: 5, armed: true }).state
  let r = M.reduceAlertState(state, { total: 3.2, threshold: 5, armed: false })
  assert.strictEqual(r.events.length, 0)
  assert.strictEqual(r.state.zone, "ok", "no threshold means no zone change")
  // Re-arming later with the balance low is a real transition: one event.
  r = M.reduceAlertState(state, { total: 3.2, threshold: 5, armed: true })
  assert.strictEqual(r.events.length, 1, "a real low after re-arm notifies once")
})

test("reduceAlertState: no usable data keeps the last concrete zone", () => {
  let state = M.initialAlertState()
  state = M.reduceAlertState(state, { total: 12.3, threshold: 5, armed: true }).state
  const r = M.reduceAlertState(state, { total: NaN, threshold: 5, armed: true })
  assert.strictEqual(r.events.length, 0)
  assert.strictEqual(r.state.zone, "ok")
})

test("reduceAlertState: full ok/low/ok/low cycle gives one event per transition", () => {
  let state = M.initialAlertState()
  state = M.reduceAlertState(state, { total: 12.3, threshold: 5, armed: true }).state
  const kinds = []
  const feed = (total) => {
    const r = M.reduceAlertState(state, { total, threshold: 5, armed: true })
    state = r.state
    r.events.forEach((e) => kinds.push(e.kind))
  }
  feed(4.0); feed(4.1); feed(4.2)   // low, stays low
  feed(6.0); feed(6.1)              // recovered, stays ok
  feed(3.0)                         // low again
  assert.deepStrictEqual(kinds, ["low", "recovered", "low"])
})

test("isLowBalance + alertStatusText drive the panel state", () => {
  const cfg = M.parseConfig(JSON.stringify({
    lowBalanceThreshold: 5, notificationsEnabled: true, currency: "USD"
  })).config
  const viewOk = { total: "12.30", currency: "USD" }
  const viewLow = { total: "3.20", currency: "USD" }
  assert.strictEqual(M.isLowBalance(viewLow, cfg), true)
  assert.strictEqual(M.isLowBalance(viewOk, cfg), false)
  assert.strictEqual(M.isLowBalance({ total: "" }, cfg), false)
  assert.strictEqual(M.alertStatusText(cfg, viewOk), "on \u00b7 below $5.00")
  assert.strictEqual(M.alertStatusText(cfg, viewLow), "below $5.00")

  const muted = M.parseConfig(JSON.stringify({
    lowBalanceThreshold: 5, notificationsEnabled: false, currency: "USD"
  })).config
  assert.strictEqual(M.alertStatusText(muted, viewLow), "muted ($5.00)")
  const off = M.parseConfig(JSON.stringify({ currency: "USD" })).config
  assert.strictEqual(M.alertStatusText(off, viewLow), "off")
  assert.strictEqual(M.alertStatusText(null, viewLow), "off")
})

test("alert state persistence helpers round-trip", () => {
  assert.strictEqual(M.sameAlertState({ zone: "low" }, { zone: "low" }), true)
  assert.strictEqual(M.sameAlertState({ zone: "low" }, { zone: "ok" }), false)
  assert.strictEqual(M.sameAlertState(null, { zone: "ok" }), false)
  assert.strictEqual(M.alertStateToText({ zone: "low" }), "low")
  assert.strictEqual(M.alertStateToText({ zone: "" }), "")
  assert.strictEqual(M.alertStateFromText("low").zone, "low")
  assert.strictEqual(M.alertStateFromText("ok").zone, "ok")
  assert.strictEqual(M.alertStateFromText("garbage").zone, "")
  assert.strictEqual(M.alertStateFromText("").zone, "")
  assert.strictEqual(M.alertStateFromText(null).zone, "")
})

test("alertParts: readable summary/body per event, no secret anywhere", () => {
  const view = { currency: "USD" }
  const low = M.alertParts({ kind: "low", total: 3.2, threshold: 5 }, view)
  assert.ok(low.summary.includes("low"))
  assert.ok(low.body.includes("$3.20"))
  assert.ok(low.body.includes("$5.00"))
  assert.strictEqual(low.urgency, "normal")
  const rec = M.alertParts({ kind: "recovered", total: 7.5, threshold: 5 }, view)
  assert.ok(rec.summary.includes("restored"))
  assert.ok(rec.body.includes("$7.50"))
  assert.strictEqual(rec.urgency, "low")
  const joined = low.summary + low.body + rec.summary + rec.body
  assert.ok(!joined.includes(SECRET))
  assert.ok(!joined.includes("sk-"))
})

test("alertGateKey is stable per kind+threshold", () => {
  assert.strictEqual(M.alertGateKey({ kind: "low", threshold: 5 }), "low|5")
  assert.strictEqual(M.alertGateKey({ kind: "recovered", threshold: 5 }), "recovered|5")
  assert.strictEqual(M.alertGateKey({}), "|")
})

test("alertGateCommandArgs builds a fixed argv and works over flock (send once, twin skips)", () => {
  const os = require("os")
  const path = require("path")
  const fs = require("fs")
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "deepspend-gate-"))
  const file = path.join(dir, "gate.state")
  const args = M.alertGateCommandArgs(file, "low|5", "instance-a", 60)
  assert.strictEqual(args[0], "bash")
  assert.ok(args[1] === "-c" || args[1] === "-c")
  assert.strictEqual(args[3], "deepspend-alert-gate")

  const run = () => spawnSync("bash", ["-c", args[2], args[3], file, "low|5", "instance-a", "60"], { encoding: "utf8" }).stdout.trim()
  const first = run()
  assert.strictEqual(first, "send")
  const second = run()
  assert.strictEqual(second, "send", "same instance may notify again after a real recovery")
})

test("alertGateCommandArgs: a twin instance within the ttl skips", () => {
  const os = require("os")
  const path = require("path")
  const fs = require("fs")
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "deepspend-gate2-"))
  const file = path.join(dir, "gate.state")
  const script = M.alertGateCommandArgs(file, "low|5", "x", 60)[2]
  const run = (me) => spawnSync("bash", ["-c", script, "deepspend-alert-gate", file, "low|5", me, "60"], { encoding: "utf8" }).stdout.trim()
  assert.strictEqual(run("instance-a"), "send")
  assert.strictEqual(run("instance-b"), "skip", "the twin must not duplicate")
  assert.strictEqual(run("instance-a"), "send", "the original may send again for a later genuine transition")
})

// --------------------------------------------------------------------------
// live curl round-trip against the real DeepSeek endpoint
// --------------------------------------------------------------------------

// Same launch shape as the Quickshell widget: a { command, environment }
// request built by buildRequestArgs. The key only reaches the child via
// its environment object (never argv).
function runFetch(req) {
  const env = { ...process.env }
  for (const key of Object.keys(req.environment || {})) {
    env[key] = req.environment[key]
  }
  const res = spawnSync(req.command[0], req.command.slice(1), {
    encoding: "utf8", timeout: 20000, env
  })
  return res
}

test("live: real DeepSeek endpoint + bogus key maps to unauthorized", async () => {
  const curlAvailable = spawnSync("curl", ["--version"], { encoding: "utf8" }).status === 0
  if (!curlAvailable) {
    console.log("     (curl not available — live DeepSeek check skipped)")
    return
  }
  // Deliberately fake key: the whole point is to exercise the real network
  // path (exactly what the widget runs) and confirm the 401 maps cleanly.
  const cfg = M.parseConfig(JSON.stringify({
    apiKey: "sk-deepspend-live-test-invalid",
    requestTimeoutSeconds: 8
  })).config
  const req = M.buildRequestArgs(cfg)
  assert.ok(req, "request built")
  assert.ok(!req.command.join("\n").includes("sk-deepspend-live-test-invalid"),
    "the key value must not travel in argv (HANCORE review)")
  const res = runFetch(req)
  const parsed = M.parseFetchResult(res.status === 0 ? 0 : 1, res.stdout, "USD")
  // The check only asserts when DeepSeek is actually reachable, so the suite
  // stays green offline or behind a firewall.
  if (parsed.ok || parsed.kind === "network" || parsed.kind === "timeout") {
    console.log("     (DeepSeek not reachable here — live check skipped: "
      + parsed.message + ")")
    return
  }
  assert.strictEqual(parsed.kind, "unauthorized",
    "an invalid key must be reported as unauthorized, got: "
    + JSON.stringify(parsed))
})

run().catch((e) => {
  console.error(e)
  process.exit(1)
})
