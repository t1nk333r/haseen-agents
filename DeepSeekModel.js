// DeepSpend — pure logic for the DeepSeek API spending bar widget.
//
// This file is plain ECMAScript shared by two runtimes:
//   - BarWidget.qml / Panel.qml import it as a QML JS module;
//   - test-model.js requires it from Node (see the module.exports guard
//     at the bottom).
//
// DS-1/DS-2 scope: config parsing/validation, DeepSeek HTTP request
// construction, transport + response parsing, a small state reducer, and
// every display string. The QML side owns the config FileView, the Timer,
// the Process lifecycle and the bar/panel UI; all decision logic lives here
// so it can be exercised from Node without a shell. DS-2 added the live
// saldo-centric monitor behaviour: polling with a quiet bar update, manual
// refresh, granted/topped-up breakdown and calm error states (401, 402,
// 429, 5xx, network/timeout), plus the stale-result guard below. DS-3 added
// the calm low-balance threshold alert: config parsing for
// notificationsEnabled/lowBalanceThreshold, a pure zone transition reducer
// (one event per ok<->low transition, never periodic), human notification
// strings, and the cross-instance flock gate used before sending. DS-5 made
// config failure handling robust: a broken/empty config.json now produces a
// specific, calm, recoverable state (JSON parse hints from a tiny scanner,
// a backup-and-create-default recovery argv, an explicit config_error view
// state) instead of one vague error line.
//
// Privacy rule: the API key NEVER appears in any output of this module
// (errors, tooltips, status lines, logs) and NEVER as a command-line
// argument. It travels to curl through the process environment, which a
// short-lived fetch process feeds to curl via `--config -` (stdin), so the
// key is not visible in /proc/<pid>/cmdline to process observers.
//
// Config file (documented in README.md):
//   ~/.config/deepspend/config.json
//   {
//     "apiKey": "sk-...",             // optional; you paste your key here
//     "currency": "USD",              // optional; preferred balance currency
//     "pollIntervalSeconds": 60,      // optional (30..3600)
//     "requestTimeoutSeconds": 10,    // optional (3..30)
//     "notificationsEnabled": true,   // optional; master switch for alerts
//     "lowBalanceThreshold": 0        // optional; amount in display currency
//   }                                 //   (0 disables the low-balance alert)

var GLYPH = "\uf201"; // chart-line icon, used in alert payloads

var DEFAULT_POLL_INTERVAL_SECONDS = 60;
var DEFAULT_REQUEST_TIMEOUT_SECONDS = 10;
var DEFAULT_CURRENCY = "USD";
var MIN_INTERVAL_SECONDS = 30;
var MAX_INTERVAL_SECONDS = 3600;
var MIN_TIMEOUT_SECONDS = 3;
var MAX_TIMEOUT_SECONDS = 30;
var DEFAULT_NOTIFICATIONS_ENABLED = true;
var DEFAULT_LOW_BALANCE_THRESHOLD = 0; // 0 = alert threshold disabled

var BALANCE_URL = "https://api.deepseek.com/user/balance";

// Marker curl appends after the response body so the HTTP status survives
// even when the body itself is not valid JSON (e.g. DeepSeek's plain-text
// 401 page). See buildRequestArgs().
var STATUS_MARKER = "__DS_HTTP__";

// Hard cap on the response body (bytes) the authenticated remote endpoint
// may drive us to collect. curl enforces it with --max-filesize (exit 63);
// parseHttpResult also enforces it defensively before any JSON parsing.
var MAX_RESPONSE_BYTES = 262144; // 256 KiB
var ENV_KEY_NAME = "DS_API_KEY";

var ERROR_CURL_EXIT_CODES = { 6: true, 7: true, 22: true, 28: true, 35: true, 56: true };

// ---------------------------------------------------------------------------
// config
// ---------------------------------------------------------------------------

function defaults() {
  return {
    apiKey: "",
    hasKey: false,
    currency: DEFAULT_CURRENCY,
    pollIntervalSeconds: DEFAULT_POLL_INTERVAL_SECONDS,
    requestTimeoutSeconds: DEFAULT_REQUEST_TIMEOUT_SECONDS,
    notificationsEnabled: DEFAULT_NOTIFICATIONS_ENABLED,
    lowBalanceThreshold: DEFAULT_LOW_BALANCE_THRESHOLD
  };
}

function stringField(value) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeNumber(value, fallback, min, max) {
  if (value === undefined || value === null || value === "") return fallback;
  var n = Number(value);
  if (!isFinite(n)) return fallback;
  return Math.round(Math.max(min, Math.min(max, n)));
}

// Parse and validate the config.json text. Returns
//   { ok: true,  config: { apiKey, hasKey, currency, pollIntervalSeconds,
//                          requestTimeoutSeconds } }
// or
//   { ok: false, kind, error, at, hint }
// `kind` classifies the problem:
//   "empty"  file is blank (a first-run state, not an error)
//   "parse"  text is not valid JSON (at/hint locate the trouble)
//   "shape"  valid JSON whose root is not a plain object
//   "field"  a known field has an invalid value
// Error strings are static and never echo the config content (the key cannot
// leak through a parse error).
//
// DS-5: JSON.parse error messages are engine-specific and can quote the
// offending file content (V8 does), so they are never surfaced verbatim.
// Instead scanJson() finds the first invalid spot and the UI hints are built
// from fixed strings plus a character offset.

// JSON structural whitespace.
function isJsonSpace(c) {
  return c === " " || c === "\t" || c === "\n" || c === "\r";
}

function isJsonDigit(c) {
  return c >= "0" && c <= "9";
}

function isJsonAlpha(c) {
  return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");
}

// Tiny JSON structure scanner used only to *hint* at the first invalid spot.
// JSON.parse remains the authority for validity; when the scanner cannot
// pinpoint anything the caller falls back to a generic hint. Returns
//   { ok: true }
// or
//   { ok: false, at: <0-based char index>, code: <string> }
function scanJson(raw) {
  var s = String(raw == null ? "" : raw);
  var n = s.length;
  var i = 0;

  function err(at, code) { return { ok: false, at: at, code: code }; }

  function skipWs() {
    while (i < n && isJsonSpace(s.charAt(i))) i++;
  }

  function parseString() {
    i++; // opening quote
    while (i < n) {
      var c = s.charAt(i);
      if (c === "\"") { i++; return null; }
      if (c === "\\") { i += 2; continue; }
      if (c === "\n" || c === "\r") return err(i, "badControl");
      i++;
    }
    return err(n, "unterminated");
  }

  function parseNumber() {
    if (s.charAt(i) === "-") i++;
    while (i < n) {
      var c = s.charAt(i);
      if (isJsonDigit(c) || c === "." || c === "e" || c === "E"
        || c === "+" || c === "-") i++;
      else break;
    }
    return null;
  }

  function parseWord() {
    while (i < n && isJsonAlpha(s.charAt(i))) i++;
    return null;
  }

  function parseValue() {
    skipWs();
    if (i >= n) return err(n, "unexpectedEnd");
    var c = s.charAt(i);
    if (c === "{") return parseObject();
    if (c === "[") return parseArray();
    if (c === "\"") return parseString();
    if (c === "-" || isJsonDigit(c)) return parseNumber();
    if (c === "t" || c === "f" || c === "n") return parseWord();
    return err(i, "unexpectedChar");
  }

  function parseObject() {
    i++; // "{"
    skipWs();
    if (i < n && s.charAt(i) === "}") { i++; return null; }
    for (;;) {
      skipWs();
      if (i >= n) return err(n, "unexpectedEnd");
      if (s.charAt(i) !== "\"") return err(i, "expectedKey");
      var r = parseString();
      if (r) return r;
      skipWs();
      if (i >= n) return err(n, "unexpectedEnd");
      if (s.charAt(i) !== ":") return err(i, "expectedColon");
      i++;
      r = parseValue();
      if (r) return r;
      skipWs();
      if (i >= n) return err(n, "unexpectedEnd");
      var c = s.charAt(i);
      if (c === ",") { i++; continue; }
      if (c === "}") { i++; return null; }
      return err(i, "expectedCommaOrClose");
    }
  }

  function parseArray() {
    i++; // "["
    skipWs();
    if (i < n && s.charAt(i) === "]") { i++; return null; }
    for (;;) {
      var r = parseValue();
      if (r) return r;
      skipWs();
      if (i >= n) return err(n, "unexpectedEnd");
      var c = s.charAt(i);
      if (c === ",") { i++; continue; }
      if (c === "]") { i++; return null; }
      return err(i, "expectedCommaOrClose");
    }
  }

  skipWs();
  if (i >= n) return { ok: false, at: n, code: "unexpectedEnd" };
  var root = parseValue();
  if (root) return root;
  skipWs();
  if (i < n) return err(i, "trailing");
  return { ok: true };
}

// Static, human hint for a JSON parse failure. Never includes file content.
function jsonErrorHintFor(raw) {
  var text = String(raw == null ? "" : raw);
  var scan = scanJson(text);
  if (scan.ok) {
    // The scanner could not pinpoint the problem (rare strictness cases);
    // keep the message generic and calm.
    return { at: null, hint: "Check the double quotes, commas and braces." };
  }
  var at = scan.at;
  if (at !== null && at >= text.length) at = null; // end-of-input: no useful column
  var code = scan.code;
  var hint;
  if (code === "unterminated") {
    hint = "A string value is missing its closing double quote.";
  } else if (code === "badControl") {
    hint = "A string value contains a raw line break — quotes must stay on one line.";
  } else if (code === "unexpectedEnd") {
    hint = "The file ends too early — a closing double quote or brace is missing.";
  } else if (code === "expectedKey") {
    hint = "An object key is missing or not wrapped in double quotes.";
  } else if (code === "expectedColon") {
    hint = "A colon (:) is missing after an object key.";
  } else if (code === "expectedCommaOrClose") {
    hint = "There is an extra or a missing comma, double quote or brace at this spot.";
  } else if (code === "trailing") {
    hint = "There is extra content after the JSON object.";
  } else {
    hint = "Check the double quotes, commas and braces.";
  }
  var near = "";
  if (at !== null && (code === "expectedCommaOrClose" || code === "unexpectedChar")) {
    var keyIdx = text.indexOf("\"apiKey\"");
    if (keyIdx >= 0 && at >= keyIdx && at <= keyIdx + 80) {
      near = " It is right beside the \"apiKey\" value — an extra or missing double quote around the key is the usual cause.";
    }
  }
  return { at: at, hint: hint + near };
}

function parseConfig(raw) {
  var textRaw = String(raw == null ? "" : raw);
  if (textRaw.trim() === "") {
    return { ok: false, kind: "empty", error: "config.json is empty",
      at: null, hint: "" };
  }
  var parsed;
  try {
    parsed = JSON.parse(textRaw);
  } catch (e) {
    var hint = jsonErrorHintFor(textRaw);
    return { ok: false, kind: "parse", error: "config.json is not valid JSON",
      at: hint.at, hint: hint.hint };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, kind: "shape", error: "config.json must contain a JSON object",
      at: null, hint: "" };
  }

  var apiKey = "";
  if (parsed.apiKey !== undefined && parsed.apiKey !== null) {
    if (typeof parsed.apiKey !== "string") {
      return { ok: false, kind: "field", error: "config: \"apiKey\" must be a string",
        at: null, hint: "" };
    }
    apiKey = parsed.apiKey.trim();
  }

  var currency = stringField(parsed.currency) || DEFAULT_CURRENCY;
  currency = currency.toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) {
    return { ok: false, kind: "field", error: "config: \"currency\" must be a 3-letter code such as USD or CNY",
      at: null, hint: "" };
  }

  var poll = normalizeNumber(parsed.pollIntervalSeconds,
    DEFAULT_POLL_INTERVAL_SECONDS, MIN_INTERVAL_SECONDS, MAX_INTERVAL_SECONDS);
  var timeout = normalizeNumber(parsed.requestTimeoutSeconds,
    DEFAULT_REQUEST_TIMEOUT_SECONDS, MIN_TIMEOUT_SECONDS, MAX_TIMEOUT_SECONDS);

  var notificationsEnabled = parsed.notificationsEnabled === undefined
    ? DEFAULT_NOTIFICATIONS_ENABLED
    : parsed.notificationsEnabled;
  if (typeof notificationsEnabled !== "boolean") {
    return { ok: false, kind: "field", error: "config: \"notificationsEnabled\" must be true or false",
      at: null, hint: "" };
  }

  var threshold = parseThreshold(parsed.lowBalanceThreshold);
  if (threshold === null) {
    return { ok: false, kind: "field", error: "config: \"lowBalanceThreshold\" must be a non-negative number (0 disables)",
      at: null, hint: "" };
  }

  return {
    ok: true,
    config: {
      apiKey: apiKey,
      hasKey: apiKey !== "",
      currency: currency,
      pollIntervalSeconds: poll,
      requestTimeoutSeconds: timeout,
      notificationsEnabled: notificationsEnabled,
      lowBalanceThreshold: threshold
    }
  };
}

// Parse the optional low-balance alert threshold. Accepts a non-negative
// number or numeric string; missing/empty/null means disabled (0). Returns
// the number or null when the value is present but not a valid threshold.
function parseThreshold(value) {
  if (value === undefined || value === null || value === "") return 0;
  if (typeof value === "boolean") return null;
  var n = Number(value);
  if (!isFinite(n) || n < 0) return null;
  return n;
}

// Whether the low-balance alert is armed by the config: a positive threshold
// and notifications not switched off.
function alertArmed(config) {
  return !!(config && config.lowBalanceThreshold > 0
    && config.notificationsEnabled !== false);
}

// The config file template written when the user asks the widget to create
// one. Contains a placeholder, never a real key.
function templateConfigText() {
  return "{"
    + "\n  \"apiKey\": \"\","
    + "\n  \"currency\": \"USD\","
    + "\n  \"pollIntervalSeconds\": 60,"
    + "\n  \"requestTimeoutSeconds\": 10,"
    + "\n  \"notificationsEnabled\": true,"
    + "\n  \"lowBalanceThreshold\": 0"
    + "\n}\n";
}

// ---------------------------------------------------------------------------
// HTTP request construction
// ---------------------------------------------------------------------------

// Build the launch vector for a balance fetch, suitable for Quickshell
// Process.command/.environment or Node child_process.spawn. Returns null
// when no key is configured.
//
// Security (HANCORE review, 2026-09-04):
//   1. The API key is passed through the process ENVIRONMENT, not as a
//      command-line argument. The fetch runs `bash -c` whose script text
//      contains no key material (it only references $DS_API_KEY), and the
//      key reaches curl via stdin using `curl --config -` (curl config
//      format: header = "Authorization: Bearer ..."). The key is therefore
//      not visible in /proc/<pid>/cmdline to process observers.
//   2. A strict response-body cap is enforced by curl (--max-filesize,
//      exit 63) before any body is buffered, so the authenticated remote
//      endpoint cannot drive unbounded memory use.
// The fixed URL, timeout and marker are compile-time constants; the only
// variable interpolated into the script is the numeric timeout, so no
// config value can inject shell syntax.
function buildRequestArgs(config, url) {
  if (!config || !config.hasKey) return null;
  var target = url || BALANCE_URL;
  var maxTime = String(clampInt(config.requestTimeoutSeconds,
    DEFAULT_REQUEST_TIMEOUT_SECONDS, MIN_TIMEOUT_SECONDS, MAX_TIMEOUT_SECONDS));
  var script = "printf 'header = \"Authorization: Bearer %s\"\\n' \"$" + ENV_KEY_NAME + "\""
    + " | exec curl -sS --config -"
    + " --max-time " + maxTime
    + " --max-filesize " + String(MAX_RESPONSE_BYTES)
    + " -w '\\n" + STATUS_MARKER + "%{http_code}' '" + target + "'";
  // Quickshell Process.environment is a JS OBJECT ({ VAR: value }), not a
  // list of "VAR=value" strings — assigning an array would make the child
  // miss DS_API_KEY and send an empty Authorization header (401). Node
  // consumers must merge Object.entries(environment) into the child env.
  var environment = {};
  environment[ENV_KEY_NAME] = config.apiKey;
  return {
    command: ["bash", "-c", script],
    environment: environment
  };
}

function clampInt(value, fallback, min, max) {
  var n = parseInt(value, 10);
  if (!isFinite(n)) return fallback;
  if (n < min) return min;
  if (n > max) return max;
  return n;
}

// ---------------------------------------------------------------------------
// HTTP result parsing
// ---------------------------------------------------------------------------

// Split the curl output into { httpStatus, body }. When the transport
// succeeded the marker produced by -w is always present; without it the
// request did not complete (curl exit code non-zero) or the marker was lost.
// The body is defensively capped at MAX_RESPONSE_BYTES before it can reach
// any JSON parser (curl already enforces --max-filesize at the socket).
function parseHttpResult(exitCode, output) {
  var text = String(output == null ? "" : output);
  if (text.length > MAX_RESPONSE_BYTES) text = text.substring(0, MAX_RESPONSE_BYTES);
  var markerIndex = text.lastIndexOf(STATUS_MARKER);
  var httpStatus = 0;
  var body = "";
  if (markerIndex >= 0) {
    var statusText = text.substring(markerIndex + STATUS_MARKER.length).trim();
    httpStatus = parseInt(statusText, 10);
    if (!isFinite(httpStatus)) httpStatus = 0;
    body = text.substring(0, markerIndex).trim();
  } else {
    body = text.trim();
  }
  var code = typeof exitCode === "number" ? exitCode : -1;
  var transportError = code === 0 ? "" : describeCurlError(code);
  return { httpStatus: httpStatus, body: body, curlExitCode: code, transportError: transportError };
}

function describeCurlError(code) {
  if (code === 6) return "network: could not resolve api.deepseek.com";
  if (code === 7) return "network: could not connect to api.deepseek.com";
  if (code === 28) return "request timed out";
  if (code === 35) return "network: TLS connection failed";
  if (code === 56) return "network: connection reset";
  if (code === 63) return "response too large (over 256 KiB)";
  return "request failed (curl exit " + code + ")";
}

// Pick the balance_info entry matching the preferred currency, else the
// first entry. Returns an index or -1.
function pickBalanceInfo(infos, preferredCurrency) {
  if (!infos || infos.length === 0) return -1;
  var pref = String(preferredCurrency || "").toUpperCase();
  for (var i = 0; i < infos.length; i++) {
    var info = infos[i];
    if (info && typeof info === "object"
      && String(info.currency || "").toUpperCase() === pref) return i;
  }
  return 0;
}

function isNumericString(v) {
  if (typeof v !== "string" || v.trim() === "") return false;
  var n = Number(v);
  return isFinite(n);
}

// Parse the 200 response body of GET /user/balance.
// Returns
//   { ok: true, balance: { isAvailable, currency, total, granted, toppedUp } }
// or
//   { ok: false, kind: "parse", message: "..." }
// Amounts are kept as the API sends them (strings).
function parseBalanceBody(text, preferredCurrency) {
  var parsed;
  try {
    parsed = JSON.parse(String(text == null ? "" : text));
  } catch (e) {
    return { ok: false, kind: "parse", message: "balance response is not valid JSON" };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, kind: "parse", message: "balance response is not a JSON object" };
  }
  var infos = parsed.balance_infos;
  if (!Array.isArray(infos) || infos.length === 0) {
    return { ok: false, kind: "parse", message: "balance response has no balance_infos" };
  }
  var idx = pickBalanceInfo(infos, preferredCurrency);
  if (idx < 0) {
    return { ok: false, kind: "parse", message: "balance response has no balance_infos" };
  }
  var info = infos[idx];
  if (!info || typeof info !== "object") {
    return { ok: false, kind: "parse", message: "balance entry is malformed" };
  }
  var currency = String(info.currency || "").trim().toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) {
    return { ok: false, kind: "parse", message: "balance entry has no valid currency" };
  }
  var total = String(info.total_balance == null ? "" : info.total_balance).trim();
  if (!isNumericString(total)) {
    return { ok: false, kind: "parse", message: "balance entry has no valid total_balance" };
  }
  var granted = info.granted_balance === undefined || info.granted_balance === null
    ? "0" : String(info.granted_balance).trim();
  if (!isNumericString(granted)) granted = "0";
  var toppedUp = info.topped_up_balance === undefined || info.topped_up_balance === null
    ? "0" : String(info.topped_up_balance).trim();
  if (!isNumericString(toppedUp)) toppedUp = "0";

  return {
    ok: true,
    balance: {
      isAvailable: parsed.is_available === undefined ? true : parsed.is_available === true,
      currency: currency,
      total: total,
      granted: granted,
      toppedUp: toppedUp
    }
  };
}

// Human message for a non-200 HTTP status. Never includes response content.
function describeHttpStatus(status) {
  if (status === 401) return "DeepSeek rejected the API key (HTTP 401)";
  if (status === 402) return "DeepSeek reports insufficient balance (HTTP 402)";
  if (status === 429) return "DeepSeek rate limit reached (HTTP 429)";
  if (status >= 500) return "DeepSeek API error (HTTP " + status + ")";
  if (status === 403) return "DeepSeek access denied (HTTP 403)";
  return "unexpected DeepSeek response (HTTP " + status + ")";
}

// One entry point for the QML Process handler: turn (exitCode, output) into
//   { ok: true, balance: {...} }
// or
//   { ok: false, kind, message }
function parseFetchResult(exitCode, output, preferredCurrency) {
  var res = parseHttpResult(exitCode, output);
  if (res.transportError) {
    return { ok: false, kind: res.curlExitCode === 28 ? "timeout" : "network",
      message: res.transportError };
  }
  if (res.httpStatus === 200) {
    return parseBalanceBody(res.body, preferredCurrency);
  }
  return {
    ok: false,
    kind: describeErrorKind(res.httpStatus),
    message: describeHttpStatus(res.httpStatus)
  };
}

function describeErrorKind(status) {
  if (status === 401) return "unauthorized";
  if (status === 402) return "insufficient";
  if (status === 429) return "rate_limit";
  if (status >= 500) return "server";
  return "http_" + status;
}

// ---------------------------------------------------------------------------
// state reducer
// ---------------------------------------------------------------------------

// view.status:
//   "nokey"     no API key configured (calm, dimmed; instructions in panel)
//   "loading"   first fetch in flight, no data yet
//   "ok"        last fetch succeeded, balance present
//   "degraded"  balance present but the latest fetch failed (stale data)
//   "error"     latest fetch failed and no usable balance is available
function initialView() {
  return {
    status: "nokey",
    refreshing: false,
    errorKind: "",
    errorMessage: "",
    isAvailable: true,
    currency: "",
    total: "",
    granted: "",
    toppedUp: "",
    checkedAt: 0
  };
}

function hasData(view) {
  return !!view && view.total !== "";
}

// Whether a fetch result may still be applied to the view. When the config
// no longer has a key (the user removed it, or the file became invalid while
// a request was in flight) the no-key state is authoritative: a stale result
// must not resurrect an old balance underneath it.
function acceptFetchResult(config) {
  return !!(config && config.hasKey);
}

function merge(base, extra) {
  var out = {};
  var k;
  for (k in base) if (Object.prototype.hasOwnProperty.call(base, k)) out[k] = base[k];
  for (k in extra) if (Object.prototype.hasOwnProperty.call(extra, k)) out[k] = extra[k];
  return out;
}

function reduce(view, event) {
  if (!view) view = initialView();
  if (!event) return view;
  switch (event.type) {
    case "config":
      if (!event.config || !event.config.hasKey) return initialView();
      if (hasData(view)) {
        // Keep showing the last known balance; the fresh fetch replaces it.
        return merge(view, { refreshing: true, errorKind: "", errorMessage: "" });
      }
      return merge(initialView(), { status: "loading", refreshing: true });
    case "fetchStart":
      return merge(view, {
        refreshing: true,
        errorKind: "",
        errorMessage: "",
        status: hasData(view) ? view.status : "loading"
      });
    case "fetchSuccess":
      return merge(view, {
        status: "ok",
        refreshing: false,
        errorKind: "",
        errorMessage: "",
        isAvailable: event.balance.isAvailable,
        currency: event.balance.currency,
        total: event.balance.total,
        granted: event.balance.granted,
        toppedUp: event.balance.toppedUp,
        checkedAt: event.at || Date.now()
      });
    case "fetchFail":
      return merge(view, {
        refreshing: false,
        errorKind: event.kind || "unknown",
        errorMessage: event.message || "request failed",
        status: hasData(view) ? "degraded" : "error"
      });
    // The config file is present but unusable (invalid JSON, wrong shape or
    // an invalid field). The calm error state carries the human-readable
    // problem (error/hint/at come from parseConfig and never contain file
    // content). Any balance is dropped: a broken config is not a source of
    // truth. The no-key defaults keep the widget from fetching.
    case "configError":
      return merge(initialView(), {
        status: "config_error",
        refreshing: false,
        errorKind: "config",
        errorMessage: (event && event.problem && event.problem.error)
          ? event.problem.error : "config file problem",
        configIssueKind: (event && event.problem && event.problem.kind)
          ? event.problem.kind : "parse",
        configIssueAt: (event && event.problem
          && typeof event.problem.at === "number") ? event.problem.at : null,
        configIssueHint: (event && event.problem && event.problem.hint)
          ? event.problem.hint : ""
      });
    default:
      return view;
  }
}

// ---------------------------------------------------------------------------
// display helpers
// ---------------------------------------------------------------------------

function currencySymbol(code) {
  var c = String(code || "").toUpperCase();
  if (c === "USD") return "$";
  if (c === "CNY") return "\u00a5"; // yen sign
  return c + " ";
}

// "$12.34", "\u00a50.98", "$1,234,567.89". Empty string when unparseable.
function formatAmount(value, code) {
  if (value === undefined || value === null || value === "") return "";
  var n = Number(value);
  if (!isFinite(n)) return "";
  var negative = n < 0;
  var fixed = Math.abs(n).toFixed(2);
  var parts = fixed.split(".");
  var intPart = parts[0];
  var withSep = "";
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 === 0) withSep += ",";
    withSep += intPart[i];
  }
  return (negative ? "-" : "") + currencySymbol(code) + withSep + "." + parts[1];
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n;
}

function formatChecked(ts) {
  if (!ts) return "never";
  var d = new Date(ts);
  if (isNaN(d.getTime())) return "never";
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes()) + ":" + pad2(d.getSeconds());
}

function pad2Utc(n) {
  return (n < 10 ? "0" : "") + n;
}

// Short date-time for panel footers, e.g. "03 Sep 14:32:05".
function formatDateTime(ts) {
  if (!ts) return "never";
  var d = new Date(ts);
  if (isNaN(d.getTime())) return "never";
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return pad2(d.getDate()) + " " + months[d.getMonth()]
    + " " + pad2Utc(d.getHours()) + ":" + pad2Utc(d.getMinutes());
}

function wantsAttention(view) {
  if (!view) return false;
  if (view.status === "error" || view.status === "config_error") return true;
  if (hasData(view) && view.isAvailable === false) return true;
  return false;
}

function isDimmed(view) {
  return !view || view.status === "nokey";
}

// Bar label. Always keeps the glyph + widget name so the widget is
// identifiable; the current balance is appended when one is known.
// What the bar shows beside the whale: the balance, or a failure marker. The
// plugin's name moved into the logo, so this is the amount alone.
function barAmount(view) {
  if (view && hasData(view)) {
    var amount = formatAmount(view.total, view.currency);
    if (amount !== "") return amount;
  }
  if (view && (view.status === "error" || view.status === "config_error")) return "!";
  return "";
}

// Full human problem text for the config_error view state, e.g.
//   "config.json is not valid JSON (character 26). There is an extra or a
//    missing comma, double quote or brace at this spot. It is right beside
//    the \"apiKey\" value — an extra or missing double quote around the key is
//    the usual cause."
// For "shape"/"field" problems the parseConfig error already reads as a full
// sentence. Never includes file content.
function configProblemText(view) {
  if (!view || view.status !== "config_error") return "";
  var text = String(view.errorMessage || "config file problem");
  var kind = view.configIssueKind || "parse";
  if (kind === "parse") {
    if (typeof view.configIssueAt === "number" && isFinite(view.configIssueAt)
      && view.configIssueAt >= 0) {
      text += " (character " + (view.configIssueAt + 1) + ")";
    }
    if (view.configIssueHint) {
      text += ". " + String(view.configIssueHint);
    }
  }
  if (text.charAt(text.length - 1) !== "." && text.charAt(text.length - 1) !== "!") {
    text += ".";
  }
  return text;
}

// Tooltip for the config_error bar state: names the problem and points to the
// panel (click) where the repair actions live. The key never appears here.
function configTooltip(view, path) {
  var detail = configProblemText(view);
  if (!detail) return "DeepSpend — config file problem.";
  return "DeepSpend — " + detail + " Click for repair options — your current file is kept as a backup first.";
}

// One-line human summary used in the panel hero meta and status text.
function statusLine(view, configPath) {
  if (!view) return "no API key configured";
  switch (view.status) {
    case "nokey":
      return "no API key configured";
    case "config_error":
      return "config file needs attention";
    case "loading":
      return "checking balance\u2026";
    case "ok":
      if (view.isAvailable === false) return "balance too low for API calls";
      return "live \u00b7 updated " + formatDateTime(view.checkedAt);
    case "degraded":
      return "showing balance from " + formatDateTime(view.checkedAt)
        + " \u00b7 last check failed";
    case "error":
      return "last check failed";
    default:
      return view.status;
  }
}

// Tooltip for the bar button. The key is never part of any of these strings.
function tooltipText(view, configPath) {
  var path = configPath || "~/.config/deepspend/config.json";
  if (!view || view.status === "nokey") {
    return "DeepSpend \u2014 no API key yet. Add your DeepSeek API key as \"apiKey\" in "
      + path + ". The widget picks it up automatically (keep the file private, chmod 600).";
  }
  if (view.status === "loading") {
    return "DeepSpend \u2014 checking balance\u2026";
  }
  if (view.status === "config_error") {
    return configTooltip(view, path);
  }
  if (view.status === "error") {
    return "DeepSpend \u2014 " + view.errorMessage + "."
      + " Check the key in " + path + " or try again.";
  }
  var text = "DeepSpend \u2014 balance " + formatAmount(view.total, view.currency);
  if (hasData(view)) {
    text += " (granted " + formatAmount(view.granted, view.currency)
      + " \u00b7 topped up " + formatAmount(view.toppedUp, view.currency) + ")";
  }
  if (view.status === "degraded") {
    text += " \u00b7 last check failed: " + view.errorMessage;
  }
  if (view.isAvailable === false) {
    text += " \u00b7 balance too low for API calls";
  }
  return text + " \u00b7 updated " + formatDateTime(view.checkedAt);
}

// ---------------------------------------------------------------------------
// low-balance threshold alerts (DS-3)
// ---------------------------------------------------------------------------
//
// The alert is quiet by design and follows the same calm rules as the rest of
// the widget:
//   - Only armed alerts (lowBalanceThreshold > 0 and notificationsEnabled)
//     are evaluated.
//   - A fetch that failed or a view without balance data never notifies and
//     never erases the last concrete zone ("degraded" keeps the last good
//     state instead of flipping to an alert).
//   - The first concrete observation is a silent baseline: arming a threshold
//     never announces the current balance, only later *changes* matter. This
//     keeps shell restarts quiet when the balance already sits below the
//     threshold.
//   - A real transition (ok -> low, or low -> ok) emits exactly one event;
//     while the zone stays the same nothing is emitted, so a low balance
//     cannot re-notify on every poll.
//
// State: { zone: "" | "ok" | "low" }  ("" = no concrete observation yet)

function initialAlertState() {
  return { zone: "" };
}

// Numeric total of a view, or NaN when there is no usable balance.
function numericTotal(view) {
  if (!view) return NaN;
  var raw = view.total;
  if (raw === undefined || raw === null || raw === "") return NaN;
  var n = Number(raw);
  return isFinite(n) ? n : NaN;
}

// Fresh zone for one concrete observation; "" when no threshold is configured
// or the total is unknown, "ok" when the balance is at/above the threshold,
// "low" when it dropped below it.
function freshZone(total, threshold, armed) {
  if (!armed || !isFinite(total)) return "";
  if (total < threshold) return "low";
  return "ok";
}

// Pure transition reducer. `state` is { zone } from a previous run (or
// undefined), `fresh` is { total, threshold, armed, enabled }:
//   - armed   = a positive threshold is configured (zone tracking on)
//   - enabled = notificationsEnabled (only gates *emission*, never tracking)
// Returns
//   { state: { zone }, events: [{ kind: "low"|"recovered", total, threshold }] }
function reduceAlertState(state, fresh) {
  var st = (state && state.zone) ? state : { zone: "" };
  var zone = freshZone(fresh && fresh.total, fresh && fresh.threshold,
    fresh && fresh.armed);
  if (zone === "") return { state: st, events: [] };
  if (zone === st.zone) return { state: st, events: [] };
  var events = [];
  var enabled = fresh && fresh.enabled !== false;
  if (st.zone === "") {
    // No previous concrete zone (first run, or first time a threshold is
    // set): an already-low balance is announced once so arming while low
    // still helps; a healthy balance is a silent baseline.
    if (enabled && zone === "low") {
      events.push({ kind: "low", total: fresh.total, threshold: fresh.threshold });
    }
  } else if (zone === "low") {
    if (enabled) events.push({ kind: "low", total: fresh.total, threshold: fresh.threshold });
  } else {
    if (enabled) events.push({ kind: "recovered", total: fresh.total, threshold: fresh.threshold });
  }
  return { state: { zone: zone }, events: events };
}

// Whether the current view is below an armed threshold (panel/bar state).
function isLowBalance(view, config) {
  var total = numericTotal(view);
  if (!isFinite(total) || !alertArmed(config)) return false;
  return total < config.lowBalanceThreshold;
}

// Compact status text for the panel alert row. Distinguishes:
//   "off"                          no threshold configured
//   "muted ($5.00)"                threshold set, notifications switched off
//   "on · below $5.00"             armed, balance healthy
//   "below $5.00"                  armed AND balance currently below
// The key never appears in any of these strings.
function alertStatusText(config, view) {
  if (!config) return "off";
  var threshold = Number(config.lowBalanceThreshold);
  if (!isFinite(threshold) || threshold <= 0) return "off";
  var code = (view && view.currency) || DEFAULT_CURRENCY;
  var text = formatAmount(threshold, code);
  if (config.notificationsEnabled === false) return "muted (" + text + ")";
  var total = numericTotal(view);
  if (isFinite(total) && total < threshold) return "below " + text;
  return "on \u00b7 below " + text;
}

// Whether two alert states carry the same zone (used to detect writes).
function sameAlertState(a, b) {
  return !!a && !!b && a.zone === b.zone;
}

// Serialize an alert state for the tiny state file ("ok" / "low" / "").
function alertStateToText(state) {
  return (state && state.zone) ? state.zone : "";
}

// Parse the state file content back into { zone }.
function alertStateFromText(text) {
  var t = String(text == null ? "" : text).trim();
  if (t === "ok" || t === "low") return { zone: t };
  return { zone: "" };
}

// ---- usage tracking ---------------------------------------------------------
// DeepSeek's public API has no usage endpoint: GET /user/balance returns the
// current balance and nothing historical, so spend cannot be *reported*, only
// *measured*. Every successful poll records the balance, and the movement
// between two samples is what happened in between: a drop is usage, a rise is
// money added (a top-up or a grant), which is counted separately and never
// subtracted from usage. The ledger keeps one row per local day — the day the
// operator lives in — plus two running totals, so a file that survives
// restarts and gaps still adds up.
var USAGE_VERSION = 2;
var USAGE_RETENTION_DAYS = 366;

// Published rates, USD per 1M tokens, from
// https://api-docs.deepseek.com/quick_start/pricing (read 2026-09-11).
// Off-peak is half of peak — the same windows this plugin already draws on the
// bar — so spend is accumulated per pricing state and converted per state,
// which is why the estimate does not double the token count after a quiet
// off-peak evening.
var TOKEN_MODELS = {
  "deepseek-flash": {
    label: "deepseek-flash",
    inputCacheHitPeak: 0.006,
    inputMissPeak: 0.30,
    outputPeak: 1.20
  },
  "deepseek-v4-pro": {
    label: "deepseek-v4-pro",
    inputCacheHitPeak: 0.044,
    inputMissPeak: 1.32,
    outputPeak: 3.96
  }
};
var TOKEN_MODEL_DEFAULT = "deepseek-flash";

// Spend is not tokens: no API reports how the money was split across cached
// input, fresh input and output, and the three rates differ by two orders of
// magnitude. The conversion therefore assumes a stated mix — half cache-miss
// input, half output, no cache hits — and the panel says so next to the
// figure. It is an estimate with a visible assumption, not a measurement.
function tokenRatePerMillion(model, peak) {
  var entry = TOKEN_MODELS[model] || TOKEN_MODELS[TOKEN_MODEL_DEFAULT];
  var rate = (entry.inputMissPeak + entry.outputPeak) / 2;
  return peak ? rate : rate / 2;
}

function formatTokens(count) {
  var n = Number(count);
  if (!isFinite(n) || n <= 0) return "0";
  if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(2) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "K";
  return String(Math.round(n));
}

// Estimated tokens for a spend recorded per pricing state. Returns null when
// there is no published rate table for the account's currency (the prices are
// USD), so a non-dollar account shows its measured spend instead of a figure
// converted at somebody else's exchange rate.
function usageTokens(spentPeak, spentOffPeak, currency, model) {
  if (String(currency || "").toUpperCase() !== "USD") return null;
  var peak = Number(spentPeak) || 0;
  var off = Number(spentOffPeak) || 0;
  var peakRate = tokenRatePerMillion(model, true);
  var offRate = tokenRatePerMillion(model, false);
  var tokens = 0;
  if (peak > 0) tokens += peak / peakRate * 1e6;
  if (off > 0) tokens += off / offRate * 1e6;
  return Math.round(tokens);
}

function initialUsage() {
  return {
    version: USAGE_VERSION,
    currency: "",
    firstSeenAt: 0,
    lastAt: 0,
    lastTotal: null,
    spent: 0,
    spentPeak: 0,
    spentOffPeak: 0,
    added: 0,
    days: []
  };
}

function usagePad(value) {
  return value < 10 ? "0" + value : "" + value;
}

// The local calendar day of a sample: `2026-09-11`. Local on purpose — the
// operator's day, not UTC's, and not the prayer location's.
function usageDayKey(epochMs) {
  var d = new Date(epochMs);
  if (isNaN(d.getTime())) return "";
  return d.getFullYear() + "-" + usagePad(d.getMonth() + 1) + "-" + usagePad(d.getDate());
}

// Fold one balance sample into the ledger and return the new ledger. Pure:
// `now` is passed in, so the tests drive days and gaps directly.
function usageRecord(usage, sample, now) {
  var u = usage && usage.version === USAGE_VERSION ? usage : initialUsage();
  var at = Number(now == null ? Date.now() : now);
  if (!sample || !isFinite(at)) return u;
  if (at < Number(u.lastAt || 0)) return u;   // a clock that went backwards
  var currency = String(sample.currency == null ? "" : sample.currency);
  var total = Number(sample.total);
  if (!isFinite(total)) return u;

  // Switching currency is a different account of money: dollars must not be
  // added to yuan. Start over rather than mix them.
  if (u.currency && currency && u.currency !== currency) u = initialUsage();

  var day = usageDayKey(at);
  if (day === "") return u;
  var row = null;
  for (var i = 0; i < u.days.length; i++) {
    if (u.days[i].date === day) { row = u.days[i]; break; }
  }
  if (!row) {
    row = { date: day, spent: 0, spentPeak: 0, spentOffPeak: 0, added: 0, samples: 0 };
    u.days.push(row);
  }

  // `Number(null)` is 0, which would read the first sample as a giant top-up.
  var atPeak = sample.peak === true;
  var previous = (u.lastTotal === null || u.lastTotal === undefined) ? NaN : Number(u.lastTotal);
  if (isFinite(previous)) {
    var delta = previous - total;
    if (delta > 0) {
      // The spend between two polls is billed at the rate in force when the
      // later sample was taken: at a minute's resolution that is the state the
      // whole interval was in, short of the four-second boundary itself.
      u.spent += delta;
      row.spent += delta;
      if (atPeak) { u.spentPeak += delta; row.spentPeak += delta; }
      else { u.spentOffPeak += delta; row.spentOffPeak += delta; }
    } else if (delta < 0) {
      u.added += -delta;
      row.added += -delta;
    }
  }
  row.samples += 1;
  if (!u.firstSeenAt) u.firstSeenAt = at;
  u.currency = currency || u.currency;
  u.lastTotal = total;
  u.lastAt = at;

  if (u.days.length > USAGE_RETENTION_DAYS) {
    u.days.sort(function (a, b) { return a.date < b.date ? -1 : 1; });
    u.days = u.days.slice(u.days.length - USAGE_RETENTION_DAYS);
  }
  return u;
}

// Today's row, or an empty one before the first sample of the day.
function usageToday(usage, now) {
  var empty = { date: usageDayKey(Number(now == null ? Date.now() : now)), spent: 0, spentPeak: 0, spentOffPeak: 0, added: 0, samples: 0 };
  var u = usage && usage.version === USAGE_VERSION ? usage : initialUsage();
  for (var i = 0; i < u.days.length; i++) {
    if (u.days[i].date === empty.date) return u.days[i];
  }
  return empty;
}

// The ledger as one JSON line. Any parse error later means a fresh ledger, so
// a truncated file costs the history, never a crash.
function usageToText(usage) {
  var u = usage && usage.version === USAGE_VERSION ? usage : initialUsage();
  return JSON.stringify({
    version: USAGE_VERSION,
    currency: u.currency,
    firstSeenAt: u.firstSeenAt,
    lastAt: u.lastAt,
    lastTotal: u.lastTotal === null ? null : Number(u.lastTotal),
    spent: Number(u.spent) || 0,
    spentPeak: Number(u.spentPeak) || 0,
    spentOffPeak: Number(u.spentOffPeak) || 0,
    added: Number(u.added) || 0,
    days: u.days
  });
}

function usageFromText(text) {
  var raw = String(text == null ? "" : text).trim();
  if (raw === "") return initialUsage();
  var parsed = null;
  try { parsed = JSON.parse(raw); } catch (error) { return initialUsage(); }
  if (!parsed || typeof parsed !== "object") return initialUsage();
  if (Number(parsed.version) !== USAGE_VERSION) return initialUsage();
  var u = initialUsage();
  u.currency = typeof parsed.currency === "string" ? parsed.currency : "";
  u.firstSeenAt = Number(parsed.firstSeenAt) || 0;
  u.lastAt = Number(parsed.lastAt) || 0;
  u.lastTotal = parsed.lastTotal === null || parsed.lastTotal === undefined
    ? null : Number(parsed.lastTotal);
  u.spent = Number(parsed.spent) || 0;
  u.spentPeak = Number(parsed.spentPeak) || 0;
  u.spentOffPeak = Number(parsed.spentOffPeak) || 0;
  u.added = Number(parsed.added) || 0;
  u.days = [];
  var days = parsed.days instanceof Array ? parsed.days : [];
  for (var i = 0; i < days.length; i++) {
    var d = days[i];
    if (!d || typeof d.date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(d.date)) continue;
    u.days.push({
      date: d.date,
      spent: Number(d.spent) || 0,
      spentPeak: Number(d.spentPeak) || 0,
      spentOffPeak: Number(d.spentOffPeak) || 0,
      added: Number(d.added) || 0,
      samples: Math.max(0, Math.round(Number(d.samples) || 0))
    });
  }
  return u;
}

// "11 Sep" for the total's "since" — the row also carries a figure, and the
// year is only worth its width once the ledger has crossed one.
function usageSinceText(usage, nowMs) {
  var u = usage && usage.version === USAGE_VERSION ? usage : initialUsage();
  if (!u.firstSeenAt) return "";
  var d = new Date(Number(u.firstSeenAt));
  if (isNaN(d.getTime())) return "";
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  var now = new Date(Number(nowMs == null ? Date.now() : nowMs));
  var text = d.getDate() + " " + months[d.getMonth()];
  if (isNaN(now.getTime()) || now.getFullYear() !== d.getFullYear()) {
    text += " " + d.getFullYear();
  }
  return text;
}


// Human strings for a low-balance alert event (used by the widget to send one
// Omarchy notification per event). The key never appears in these strings.
function alertParts(event, view) {
  if (!event) return {};
  var code = (view && view.currency) || DEFAULT_CURRENCY;
  var amount = formatAmount(event.total, code);
  var threshold = formatAmount(event.threshold, code);
  if (event.kind === "low") {
    return {
      summary: "DeepSpend \u2014 balance low",
      body: "Balance " + amount + " dropped below your "
        + threshold + " threshold.",
      urgency: "normal",
      glyph: GLYPH
    };
  }
  return {
    summary: "DeepSpend \u2014 balance restored",
    body: "Balance is back above your " + threshold + " threshold (now "
      + amount + ").",
    urgency: "low",
    glyph: GLYPH
  };
}

// Cross-instance notification dedupe. Omarchy may run one widget instance
// per monitor, so two instances can observe the same transition and both
// want to notify. Before sending, each instance atomically records
// "{key} {instance} {unixSeconds}" in a state file (flock'd). An instance
// skips only when the same key was recorded by a *different* instance within
// the ttl window; its own earlier record never suppresses a genuine later
// transition (the in-memory zone already prevents periodic repeats). Key
// includes the threshold so successive *different* transitions are never
// mistaken for the same one.
function alertGateKey(event) {
  if (!event) return "";
  return String(event.kind || "") + "|" + String(event.threshold == null ? "" : event.threshold);
}

// argv: bash -c script name stateFile key instanceId ttlSeconds; prints
// "send" or "skip". flock failures degrade to "skip" (no notification) --
// never to a duplicate.
function alertGateCommandArgs(stateFile, key, instanceId, ttlSeconds) {
  var ttl = Number(ttlSeconds);
  if (!isFinite(ttl) || ttl < 1) ttl = 25;
  var script = "f=$1; key=$2; me=$3; ttl=$4;"
    + " dir=$(dirname -- \"$f\"); mkdir -p -- \"$dir\" 2>/dev/null || { echo skip; exit 0; };"
    + " lock=\"$f.lock\"; exec 9>\"$lock\" || { echo skip; exit 0; };"
    + " flock 9 2>/dev/null || { echo skip; exit 0; };"
    + " now=$(date +%s); prev=\"\"; prevme=\"\"; prevts=0;"
    + " if [ -f \"$f\" ]; then read -r prev prevme prevts < \"$f\" 2>/dev/null || true; fi;"
    + " if [ \"$prev\" = \"$key\" ] && [ -n \"$prevme\" ] && [ \"$prevme\" != \"$me\" ]"
    + "   && [ -n \"$prevts\" ] && [ \"$(( now - prevts ))\" -lt \"$ttl\" ]; then echo skip;"
    + " else printf '%s %s %s\\n' \"$key\" \"$me\" \"$now\" > \"$f\"; echo send; fi";
  return ["bash", "-c", script, "deepspend-alert-gate",
    String(stateFile == null ? "" : stateFile), String(key == null ? "" : key),
    String(instanceId == null ? "" : instanceId), String(ttl)];
}

// Config file path directory (used by the "create config" helper).
function configDir(configPath) {
  if (!configPath) return "";
  var idx = configPath.lastIndexOf("/");
  return idx > 0 ? configPath.substring(0, idx) : configPath;
}

// argv for the DS-5 recovery action "back up & create default":
//   1. keep a copy of the current (broken) config as config.json.bak-<ts>-<pid>
//      so nothing the user typed is lost (pid keeps two recoveries in the
//      same second from colliding);
//   2. write the key-free template in its place — mode 600 from the first
//      byte (umask 077 before creation; unique temp file + atomic mv, never
//      write-then-chmod — HANCORE review, 2026-09-04);
//   3. print the backup stamp so the UI can name it.
// `dir` is the config directory and `template` the new file content. The
// broken file and the template travel as argv, never through shell syntax,
// so the file content (which may contain a stray key) cannot inject
// commands and is never echoed anywhere.
function backupAndTemplateCommandArgs(dir, template) {
  var d = String(dir == null ? "" : dir);
  var t = String(template == null ? "" : template);
  var script = "umask 077;"
    + " mkdir -p -- \"$1\" || exit 1;"
    + " f=\"$1/config.json\";"
    + " ts=$(date +%s)-$$;"
    + " if [ -f \"$f\" ]; then cp -a -- \"$f\" \"$f.bak-$ts\" || exit 1; fi;"
    + " tmp=\"$f.tmp.$$\";"
    + " printf '%s' \"$2\" > \"$tmp\" || exit 1;"
    + " mv -f -- \"$tmp\" \"$f\" || exit 1;"
    + " printf '%s' \"$ts\"";
  return ["bash", "-c", script, "deepspend-backup-config", d, t];
}

if (typeof module !== "undefined") {
  module.exports = {
    GLYPH: GLYPH,
    DEFAULT_POLL_INTERVAL_SECONDS: DEFAULT_POLL_INTERVAL_SECONDS,
    DEFAULT_REQUEST_TIMEOUT_SECONDS: DEFAULT_REQUEST_TIMEOUT_SECONDS,
    DEFAULT_CURRENCY: DEFAULT_CURRENCY,
    MIN_INTERVAL_SECONDS: MIN_INTERVAL_SECONDS,
    MAX_INTERVAL_SECONDS: MAX_INTERVAL_SECONDS,
    MIN_TIMEOUT_SECONDS: MIN_TIMEOUT_SECONDS,
    MAX_TIMEOUT_SECONDS: MAX_TIMEOUT_SECONDS,
    DEFAULT_NOTIFICATIONS_ENABLED: DEFAULT_NOTIFICATIONS_ENABLED,
    DEFAULT_LOW_BALANCE_THRESHOLD: DEFAULT_LOW_BALANCE_THRESHOLD,
    BALANCE_URL: BALANCE_URL,
    STATUS_MARKER: STATUS_MARKER,
    MAX_RESPONSE_BYTES: MAX_RESPONSE_BYTES,
    ENV_KEY_NAME: ENV_KEY_NAME,
    defaults: defaults,
    parseConfig: parseConfig,
    parseThreshold: parseThreshold,
    alertArmed: alertArmed,
    templateConfigText: templateConfigText,
    buildRequestArgs: buildRequestArgs,
    parseHttpResult: parseHttpResult,
    parseBalanceBody: parseBalanceBody,
    parseFetchResult: parseFetchResult,
    initialView: initialView,
    hasData: hasData,
    acceptFetchResult: acceptFetchResult,
    reduce: reduce,
    currencySymbol: currencySymbol,
    barAmount: barAmount,
    formatAmount: formatAmount,
    formatChecked: formatChecked,
    formatDateTime: formatDateTime,
    wantsAttention: wantsAttention,
    isDimmed: isDimmed,
    statusLine: statusLine,
    tooltipText: tooltipText,
    configProblemText: configProblemText,
    initialUsage: initialUsage,
    usageRecord: usageRecord,
    usageToday: usageToday,
    usageDayKey: usageDayKey,
    usageToText: usageToText,
    usageFromText: usageFromText,
    usageSinceText: usageSinceText,
    usageTokens: usageTokens,
    tokenRatePerMillion: tokenRatePerMillion,
    formatTokens: formatTokens,
    TOKEN_MODELS: TOKEN_MODELS,
    TOKEN_MODEL_DEFAULT: TOKEN_MODEL_DEFAULT,
    configTooltip: configTooltip,
    initialAlertState: initialAlertState,
    numericTotal: numericTotal,
    freshZone: freshZone,
    reduceAlertState: reduceAlertState,
    sameAlertState: sameAlertState,
    alertStateToText: alertStateToText,
    alertStateFromText: alertStateFromText,
    isLowBalance: isLowBalance,
    alertStatusText: alertStatusText,
    alertParts: alertParts,
    alertGateKey: alertGateKey,
    alertGateCommandArgs: alertGateCommandArgs,
    configDir: configDir,
    backupAndTemplateCommandArgs: backupAndTemplateCommandArgs
  };
}
