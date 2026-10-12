// bin/openrouter-credits against a loopback fixture server.
//
// Every run goes through PATH shims: `curl` records its argv, the config it
// was fed on stdin, its environment and its parent's name, optionally
// snapshots $TMPDIR before and after the real transfer, then runs the real
// curl with that config; `date` answers `date [-u] +%s` with $FAKE_NOW when
// set, so the calendar maths can be pinned. The only network traffic is to
// 127.0.0.1. All keys here are fake.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.resolve(here, '../../bin/openrouter-credits');
const which = (name) => execFileSync('bash', ['-c', `command -v ${name}`]).toString().trim();
const REAL_CURL = which('curl');
const REAL_DATE = which('date');

// Non-periodic bodies, so any 16-character window of a key is unique to it.
const ALPHA = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-';
const KEY = `sk-or-v1-${ALPHA}`;
const OTHER_KEY = `sk-or-v1-${[...ALPHA].reverse().join('')}`;
const FILE_KEY = 'sk-or-v1-fakefile4444fixture5555notreal6666';
// The label the helper computes LOCALLY: public prefix (when present) + last 4.
const mask = (key) => (key.startsWith('sk-or-v1-') ? `sk-or-v1-...${key.slice(-4)}` : `...${key.slice(-4)}`);
const MASK = mask(KEY);
const OTHER_MASK = mask(OTHER_KEY);

const OUTPUT_KEYS = [
  'ok', 'error', 'hint', 'noKey', 'needsManagementKey', 'keySource', 'keyKind', 'source',
  'fetchedAt', 'accountError', 'keyError', 'activityError',
  'funded', 'spent', 'remaining',
  'keyLabel', 'keyLimit', 'keyLimitRemaining', 'keyLimitReset',
  'keyUsage', 'keyUsageDaily', 'keyUsageWeekly', 'keyUsageMonthly', 'freeTier',
  'spendToday', 'spendTodaySince', 'usageWeekly', 'usageMonthly',
].sort();

// A UTF-8 locale for the locale-independence checks, if the host has one.
const UTF8_LOCALE = (() => {
  try {
    const all = execFileSync('locale', ['-a']).toString().split('\n');
    return ['en_US.UTF-8', 'en_US.utf8', 'C.UTF-8', 'C.utf8']
      .find((l) => all.includes(l)) ?? all.find((l) => /utf-?8/i.test(l)) ?? null;
  } catch { return null; }
})();

// ── fixture servers ──────────────────────────────────────────────────────────
function fixture() {
  const fx = { routes: {}, requests: [] };
  fx.server = http.createServer((req, res) => {
    fx.requests.push({ path: req.url, auth: req.headers.authorization });
    const route = fx.routes[req.url];
    if (!route) {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end('{"error":{"message":"no such fixture","code":404}}');
      return;
    }
    if (typeof route === 'function') { route(req, res); return; }
    const body = typeof route.body === 'string' ? route.body : JSON.stringify(route.body);
    res.writeHead(route.status, { 'content-type': 'application/json' });
    if (route.chunked) {
      for (let i = 0; i < body.length; i += 65536) res.write(body.slice(i, i + 65536));
      res.end();
      return;
    }
    res.end(body);
  });
  return fx;
}
const fx = fixture();
const proxy = fixture(); // a would-be HTTP proxy: must never be contacted
let port;

before(async () => {
  for (const f of [fx, proxy]) {
    await new Promise((resolve) => f.server.listen(0, '127.0.0.1', resolve));
    f.port = f.server.address().port;
  }
  port = fx.port;
});
after(async () => {
  for (const f of [fx, proxy]) {
    f.server.closeAllConnections();
    await new Promise((resolve) => f.server.close(resolve));
  }
});

const BASE = () => `http://127.0.0.1:${port}/api/v1`;

function serve(map) {
  fx.routes = {};
  fx.requests = [];
  proxy.requests = [];
  for (const [name, route] of Object.entries(map)) fx.routes[`/api/v1/${name}`] = route;
}

// ── per-case sandbox ─────────────────────────────────────────────────────────
function sandbox(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'or-credits-test-'));
  const dirs = { root };
  for (const name of ['home', 'config', 'state', 'tmp', 'shim', 'log']) {
    dirs[name] = path.join(root, name);
    fs.mkdirSync(dirs[name]);
  }
  fs.writeFileSync(path.join(dirs.shim, 'curl'), `#!/usr/bin/bash -p
dir=$CURL_SHIM_DIR
n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$dir/count"
printf '%s\\0' "$@" > "$dir/argv.$n"
cat > "$dir/config.$n"
env > "$dir/env.$n"
cat "/proc/$PPID/comm" > "$dir/parent.$n" 2>/dev/null
if [[ -n \${CURL_SHIM_NO_EXEC:-} ]]; then printf '000'; exit 7; fi
if [[ -n \${CURL_SHIM_SNAP:-} ]]; then
  cp -r "$TMPDIR" "$dir/snap.$n.pre"
  ${JSON.stringify(REAL_CURL)} "$@" < "$dir/config.$n"
  rc=$?
  cp -r "$TMPDIR" "$dir/snap.$n.post"
  exit $rc
fi
exec ${JSON.stringify(REAL_CURL)} "$@" < "$dir/config.$n"
`, { mode: 0o755 });
  fs.writeFileSync(path.join(dirs.shim, 'date'), `#!/usr/bin/bash -p
if [[ -n \${FAKE_NOW:-} && ( "$*" == "-u +%s" || "$*" == "+%s" ) ]]; then
  printf '%s\\n' "$FAKE_NOW"; exit 0
fi
exec ${JSON.stringify(REAL_DATE)} "$@"
`, { mode: 0o755 });
  t.after(() => {
    try { fs.chmodSync(root, 0o700); } catch {}
    fs.rmSync(root, { recursive: true, force: true });
  });
  return dirs;
}

// A bin directory holding only the given tools (to withhold jq and the like).
function minimalBin(dirs, tools) {
  const bin = path.join(dirs.root, 'minbin');
  fs.mkdirSync(bin, { recursive: true });
  for (const tool of tools) fs.symlinkSync(which(tool), path.join(bin, tool));
  return bin;
}

function shimCalls(dirs) {
  const file = path.join(dirs.log, 'count');
  const count = fs.existsSync(file) ? Number(fs.readFileSync(file, 'utf8')) : 0;
  const calls = [];
  for (let n = 1; n <= count; n++) {
    const read = (name) => fs.readFileSync(path.join(dirs.log, `${name}.${n}`), 'utf8');
    calls.push({
      argv: read('argv').split('\0').slice(0, -1),
      config: read('config'),
      env: read('env'),
      parent: fs.existsSync(path.join(dirs.log, `parent.${n}`)) ? read('parent').trim() : '',
    });
  }
  return calls;
}

function filesUnder(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { recursive: true, withFileTypes: true })
    .filter((e) => e.isFile())
    .map((e) => path.join(e.parentPath ?? e.path, e.name));
}

// Every 16-character window of the key's secret part.
const windows = (key) => {
  const body = key.slice(9);
  const out = [];
  for (let i = 0; i + 16 <= body.length; i++) out.push(body.slice(i, i + 16));
  return out;
};
const leaks = (text, key) => windows(key).filter((w) => text.includes(w));

// Runs the helper and checks what must hold for every run: exit 0, exactly one
// JSON object of the fixed shape, nothing on stderr, and no 16-character piece
// of any of `secrets` in stdout, stderr or the state directory, and no whole
// secret in curl's argv or environment.
async function run(dirs, { env = {}, secrets = [KEY, OTHER_KEY, FILE_KEY] } = {}) {
  const fullEnv = {
    PATH: `${dirs.shim}:${process.env.PATH}`,
    HOME: dirs.home,
    XDG_CONFIG_HOME: dirs.config,
    XDG_STATE_HOME: dirs.state,
    TMPDIR: dirs.tmp,
    CURL_SHIM_DIR: dirs.log,
    OPENROUTER_API_BASE: BASE(),
    ...env,
  };
  for (const [name, value] of Object.entries(fullEnv)) if (value === undefined) delete fullEnv[name];
  const child = spawn(SCRIPT, [], { env: fullEnv, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (d) => { stdout += d; });
  child.stderr.on('data', (d) => { stderr += d; });
  const code = await new Promise((resolve) => child.on('close', resolve));
  assert.equal(code, 0, 'helper always exits 0');
  assert.equal(stderr, '', 'helper writes nothing to stderr');
  const lines = stdout.trim().split('\n');
  assert.equal(lines.length, 1, `exactly one JSON line, got: ${stdout}`);
  const json = JSON.parse(lines[0]);
  assert.deepEqual(Object.keys(json).sort(), OUTPUT_KEYS, 'fixed output shape');
  const calls = shimCalls(dirs);
  for (const secret of secrets) {
    assert.deepEqual(leaks(stdout, secret), [], 'no piece of the key on stdout');
    assert.deepEqual(leaks(stderr, secret), [], 'no piece of the key on stderr');
    for (const call of calls) {
      assert.ok(!call.argv.some((arg) => arg.includes(secret)), 'key not in curl argv');
      assert.ok(!call.env.includes(secret), 'key not in curl environment');
    }
    for (const file of filesUnder(dirs.state)) {
      assert.deepEqual(leaks(fs.readFileSync(file, 'latin1'), secret), [], `key not in ${file}`);
    }
  }
  assert.deepEqual(fs.readdirSync(dirs.tmp), [], 'scratch directory removed');
  return { json, calls, stdout };
}

// ── fixtures ─────────────────────────────────────────────────────────────────
const DAY = 86400;
const at = (y, m, d, hh = 12, mm = 0, ss = 0) => Date.UTC(y, m - 1, d, hh, mm, ss) / 1000;
const isoDay = (s) => new Date(s * 1000).toISOString().slice(0, 10);
// Wednesday 2026-10-07 12:00 UTC: the default pinned clock.
const NOW = at(2026, 10, 7);
const TODAY = isoDay(NOW);

const forbidden403 = { status: 403, body: { error: { code: 403, message: 'Only management keys can perform this operation' } } };
const credits = (funded, spent) => ({ status: 200, body: { data: { total_credits: funded, total_usage: spent } } });
const keyInfo = (data) => ({
  status: 200,
  body: {
    data: {
      label: 'sk-or-v1-fak...test', limit: null, limit_remaining: null, limit_reset: null,
      usage: 0, usage_daily: 0, usage_weekly: 0, usage_monthly: 0,
      is_free_tier: false, is_management_key: false, ...data,
    },
  },
});
const activity = (rows) => ({ status: 200, body: { data: rows } });

const paths = () => fx.requests.map((r) => r.path.replace('/api/v1/', ''));
const todayFile = (dirs) => path.join(dirs.state, 'haseen/agents/openrouter/today-spend.json');
const mode = (p) => fs.statSync(p).mode & 0o777;
const pinned = (env = {}, now = NOW) => ({ env: { OPENROUTER_API_KEY: KEY, FAKE_NOW: String(now), ...env } });

function writeBaseline(dirs, value) {
  fs.mkdirSync(path.dirname(todayFile(dirs)), { recursive: true, mode: 0o700 });
  fs.writeFileSync(todayFile(dirs), typeof value === 'string' ? value : JSON.stringify(value), { mode: 0o600 });
}
const readBaseline = (dirs) => JSON.parse(fs.readFileSync(todayFile(dirs), 'utf8'));

// ── the main flows ───────────────────────────────────────────────────────────
test('management key: account figures, week/month sums and today’s spend', async (t) => {
  const dirs = sandbox(t);
  // Week of Wed 2026-10-07 starts Mon 2026-10-05; month is 2026-10.
  const rows = [
    { date: '2026-10-06', usage: 1.5, requests: 1 },
    { date: '2026-10-05 00:00:00', usage: 0.25 },
    { date: '2026-10-04', usage: 2 }, // last week, this month
    { date: '2026-09-30', usage: 4 }, // last month
    { date: '2026-10-06', usage: '100' }, // not a number: ignored
    { usage: 100 }, // no date: ignored
    'not a row',
  ];
  serve({
    credits: credits(20, 7.5),
    key: keyInfo({ label: MASK, usage: 3.25, usage_daily: 0.5, usage_weekly: 1, usage_monthly: 2, is_management_key: true }),
    activity: activity(rows),
  });
  const first = await run(dirs, pinned());
  assert.deepEqual(paths(), ['credits', 'key', 'activity']);
  for (const r of fx.requests) assert.equal(r.auth, `Bearer ${KEY}`);
  const j = first.json;
  assert.equal(j.ok, true);
  assert.equal(j.error, '');
  assert.equal(j.noKey, false);
  assert.equal(j.needsManagementKey, false);
  assert.equal(j.source, 'account');
  assert.equal(j.keyKind, 'management');
  assert.equal(j.keySource, 'OPENROUTER_API_KEY');
  assert.equal(j.funded, 20);
  assert.equal(j.spent, 7.5);
  assert.equal(j.remaining, 12.5);
  assert.equal(j.keyLabel, MASK);
  assert.equal(j.keyUsage, 3.25);
  assert.equal(j.keyUsageDaily, 0.5);
  assert.equal(j.keyUsageWeekly, 1);
  assert.equal(j.keyUsageMonthly, 2);
  assert.equal(j.accountError, '');
  assert.equal(j.activityError, '');
  assert.equal(j.fetchedAt, NOW);
  assert.equal(j.spendToday, 0, 'first poll of the day sets the baseline');
  assert.equal(j.spendTodaySince, NOW);
  assert.equal(j.usageWeekly, 1.75);
  assert.equal(j.usageMonthly, 3.75);

  const stateDir = path.dirname(todayFile(dirs));
  assert.equal(mode(stateDir), 0o700, 'state dir mode 700');
  assert.equal(mode(todayFile(dirs)), 0o600, 'today-spend.json mode 600');
  assert.deepEqual(readBaseline(dirs), { date: TODAY, baseline: 7.5, keyLabel: MASK, at: NOW });
  assert.deepEqual(fs.readdirSync(stateDir), ['today-spend.json'], 'no temp files left behind');

  // Second poll, same day and label: today = live total minus the baseline.
  fx.routes['/api/v1/credits'] = credits(20, 8.75);
  const second = await run(dirs, pinned({}, NOW + 600));
  assert.equal(second.json.spendToday, 1.25);
  assert.equal(second.json.spendTodaySince, NOW);
  assert.equal(second.json.usageWeekly, 1.75 + 1.25);
  assert.equal(second.json.usageMonthly, 3.75 + 1.25);
  assert.equal(second.json.remaining, 11.25);
});

test('curl gets the key only via a stdin config with the hardening options', async (t) => {
  const dirs = sandbox(t);
  serve({ credits: forbidden403, key: keyInfo({ usage: 1 }) });
  const { calls } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } });
  assert.equal(calls.length, 2);
  for (const [i, call] of calls.entries()) {
    assert.deepEqual(call.argv.slice(0, 3), ['-q', '--config', '-'], '-q first, config from stdin');
    assert.ok(call.config.includes(`header = "Authorization: Bearer ${KEY}"`));
    assert.ok(call.config.includes(`url = "${BASE()}/${['credits', 'key'][i]}"`));
    assert.match(call.config, /^proto = "=http"$/m, 'loopback hook is http only');
    assert.match(call.config, /^noproxy = "\*"$/m, 'loopback hook never goes through a proxy');
    assert.match(call.config, /^max-time = 8$/m);
    assert.match(call.config, /^connect-timeout = 4$/m);
    assert.match(call.config, /^max-filesize = 1048576$/m);
    assert.match(call.config, /^user-agent = "t1nk33r\.agents-openrouter\/1\.0"$/m);
    assert.doesNotMatch(call.config, /location|^-L/m, 'redirects are never followed');
    assert.equal(call.parent, 'timeout', 'curl runs under timeout(1)');
  }
});

test('default base is https://openrouter.ai with proto =https, proxy honoured (shim does not exec)', async (t) => {
  const dirs = sandbox(t);
  serve({});
  const { json, calls } = await run(dirs, {
    env: { OPENROUTER_API_KEY: KEY, OPENROUTER_API_BASE: undefined, CURL_SHIM_NO_EXEC: '1' },
  });
  assert.equal(calls.length, 1, 'stops after the unreachable /credits');
  assert.ok(calls[0].config.includes('url = "https://openrouter.ai/api/v1/credits"'));
  assert.match(calls[0].config, /^proto = "=https"$/m);
  assert.doesNotMatch(calls[0].config, /noproxy/, 'the real endpoint keeps the owner’s proxy');
  assert.equal(json.ok, false);
  assert.equal(json.error, 'Could not reach openrouter.ai');
  assert.equal(json.noKey, false);
});

test('a proxy in the environment never sees the loopback hook’s requests', async (t) => {
  const dirs = sandbox(t);
  serve({ credits: forbidden403, key: keyInfo({ usage: 1 }) });
  const viaProxy = `http://127.0.0.1:${proxy.port}`;
  const { json } = await run(dirs, {
    env: { OPENROUTER_API_KEY: KEY, http_proxy: viaProxy, HTTP_PROXY: viaProxy, ALL_PROXY: viaProxy, all_proxy: viaProxy },
  });
  assert.equal(json.ok, true);
  assert.equal(proxy.requests.length, 0, 'the proxy received a request (and the Bearer header)');
  assert.deepEqual(paths(), ['credits', 'key']);
});

test('inference key with a cap: no /activity, source key, needsManagementKey', async (t) => {
  const dirs = sandbox(t);
  serve({
    credits: forbidden403,
    key: keyInfo({ label: 'capped', limit: 10, limit_remaining: 6.5, limit_reset: 'monthly', usage: 3.5, usage_daily: 0.25 }),
    activity: activity([]),
  });
  const { json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } });
  assert.deepEqual(paths(), ['credits', 'key'], '/activity is skipped, not attempted');
  assert.equal(json.ok, true);
  assert.equal(json.needsManagementKey, true);
  assert.equal(json.noKey, false);
  assert.equal(json.source, 'key');
  assert.equal(json.keyKind, 'inference');
  assert.equal(json.remaining, 6.5);
  assert.equal(json.keyLimit, 10);
  assert.equal(json.keyLimitRemaining, 6.5);
  assert.equal(json.keyLimitReset, 'monthly');
  assert.equal(json.keyUsageDaily, 0.25);
  assert.equal(json.accountError, 'needs a management key');
  assert.equal(json.activityError, 'needs a management key');
  for (const k of ['funded', 'spent', 'spendToday', 'spendTodaySince', 'usageWeekly', 'usageMonthly']) {
    assert.equal(json[k], null, k);
  }
  assert.ok(!fs.existsSync(todayFile(dirs)), 'no baseline without the ledger');
});

test('uncapped free-tier key: source usage, remaining null', async (t) => {
  const dirs = sandbox(t);
  serve({ credits: forbidden403, key: keyInfo({ usage: 0.75, is_free_tier: true, usage_monthly: '9' }) });
  const { json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } });
  assert.equal(json.ok, true);
  assert.equal(json.source, 'usage');
  assert.equal(json.remaining, null);
  assert.equal(json.keyUsage, 0.75);
  assert.equal(json.keyUsageMonthly, null, 'a string is not a figure');
  assert.equal(json.freeTier, true);
  assert.equal(json.keyLimitReset, '');
});

test('a management key seen only through /key still reports keyKind management', async (t) => {
  const dirs = sandbox(t);
  serve({ credits: { status: 500, body: { error: { message: 'Internal error' } } }, key: keyInfo({ is_management_key: true, usage: 1 }) });
  const { json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } });
  assert.deepEqual(paths(), ['credits', 'key']);
  assert.equal(json.keyKind, 'management');
  assert.equal(json.needsManagementKey, false, 'only a 403 means “needs a management key”');
  assert.equal(json.accountError, 'OpenRouter returned HTTP 500');
});

test('401 stops after one request with the rejection message', async (t) => {
  const dirs = sandbox(t);
  serve({
    credits: { status: 401, body: { error: { message: 'User not found.', code: 401 } } },
    key: keyInfo({ usage: 1 }),
  });
  const { json, calls } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } });
  assert.equal(calls.length, 1);
  assert.deepEqual(paths(), ['credits']);
  assert.equal(json.ok, false);
  assert.equal(json.noKey, false);
  assert.equal(json.needsManagementKey, false);
  assert.equal(json.error, 'OpenRouter rejected the key');
  assert.equal(json.accountError, 'OpenRouter rejected the key');
  assert.match(json.hint, /openrouter\.ai\/settings\/management-keys/);
  assert.equal(json.source, 'none');
});

test('unreachable server stops with ok=false', async (t) => {
  const dirs = sandbox(t);
  const closed = http.createServer();
  await new Promise((resolve) => closed.listen(0, '127.0.0.1', resolve));
  const deadPort = closed.address().port;
  await new Promise((resolve) => closed.close(resolve));
  const { json, calls } = await run(dirs, {
    env: { OPENROUTER_API_KEY: KEY, OPENROUTER_API_BASE: `http://127.0.0.1:${deadPort}/api/v1` },
  });
  assert.equal(calls.length, 1);
  assert.equal(json.ok, false);
  assert.equal(json.error, 'Could not reach openrouter.ai');
  assert.equal(json.keyKind, 'unknown');
});

test('garbage and non-object bodies are unusable, never a crash', async (t) => {
  const dirs = sandbox(t);
  serve({ credits: { status: 200, body: 'not json at all' }, key: { status: 200, body: '[1,2]' } });
  let { json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } });
  assert.deepEqual(paths(), ['credits', 'key'], 'no /activity without a usable ledger');
  assert.equal(json.ok, false);
  assert.equal(json.error, 'OpenRouter returned an unusable reply');
  assert.equal(json.accountError, 'OpenRouter returned an unusable reply');

  serve({
    credits: { status: 200, body: { data: { total_credits: '20', total_usage: 7 } } },
    key: { status: 200, body: { data: null } },
  });
  ({ json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } }));
  assert.equal(json.ok, false, 'string figures and a null data are unusable');
  assert.equal(json.funded, null);

  serve({ credits: { status: 200, body: '"a string"' }, key: { status: 200, body: '{"data":{}} {"data":{}}' } });
  ({ json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } }));
  assert.equal(json.ok, false, 'two JSON values are not one reply');

  serve({ credits: { status: 200, body: '' }, key: keyInfo({ usage: 2 }) });
  ({ json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } }));
  assert.deepEqual(paths(), ['credits', 'key']);
  assert.equal(json.ok, true);
  assert.equal(json.source, 'usage');

  serve({ credits: credits(5, 1), key: keyInfo({}), activity: { status: 200, body: { data: 'nope' } } });
  ({ json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } }));
  assert.equal(json.ok, true);
  assert.equal(json.usageWeekly, null);
  assert.equal(json.usageMonthly, null);
  assert.equal(json.activityError, 'OpenRouter returned an unusable reply');
});

test('oversized replies (sized and chunked) are refused', async (t) => {
  const dirs = sandbox(t);
  const huge = JSON.stringify({ data: { total_credits: 1, total_usage: 0, pad: 'x'.repeat(2 * 1048576) } });
  serve({ credits: { status: 200, body: huge }, key: { status: 200, body: huge, chunked: true } });
  const { json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } });
  assert.equal(json.ok, false);
  assert.equal(json.accountError, "OpenRouter's reply was too large");
  assert.equal(json.keyError, "OpenRouter's reply was too large");
  assert.equal(json.funded, null);
});

// ── no key / static failures ─────────────────────────────────────────────────
test('no key: noKey, ok=false, zero requests; HOME unset skips the key files', async (t) => {
  const dirs = sandbox(t);
  serve({ credits: credits(1, 0) });
  let { json, calls } = await run(dirs, { env: { OPENROUTER_API_KEY: '', OPENROUTER_KEY: '  ' } });
  assert.equal(calls.length, 0);
  assert.equal(fx.requests.length, 0);
  assert.equal(json.ok, false);
  assert.equal(json.noKey, true);
  assert.equal(json.needsManagementKey, false);
  assert.equal(json.error, 'No OpenRouter API key found');
  assert.equal(json.keySource, '');
  assert.equal(json.source, 'none');

  // A key file at the would-be "/.config" fallback of an unset HOME cannot be
  // planted here, but a relative HOME must not be used as a base either.
  fs.mkdirSync(path.join(dirs.root, 'rel/.config/haseen/agents/openrouter'), { recursive: true });
  fs.writeFileSync(path.join(dirs.root, 'rel/.config/haseen/agents/openrouter/key'), `${FILE_KEY}\n`);
  const child = { HOME: 'rel', XDG_CONFIG_HOME: undefined, XDG_STATE_HOME: undefined };
  ({ json, calls } = await run(dirs, { env: child }));
  assert.equal(json.noKey, true, 'a relative HOME is not a key location');
  assert.equal(calls.length, 0);
});

test('static failures keep the shape, the real keySource and noKey=false', async (t) => {
  const dirs = sandbox(t);
  serve({ credits: credits(1, 0) });
  let { json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY, TMPDIR: path.join(dirs.root, 'missing/dir') } });
  assert.equal(json.ok, false);
  assert.equal(json.error, 'Could not create a scratch directory');
  assert.equal(json.keySource, 'OPENROUTER_API_KEY');
  assert.equal(json.noKey, false);
  assert.equal(json.needsManagementKey, false);
  assert.equal(fx.requests.length, 0);

  // jq missing, key from a file whose path needs JSON escaping.
  const odd = path.join(dirs.root, 'cfg "q" \\ dir');
  fs.mkdirSync(path.join(odd, 'haseen/agents/openrouter'), { recursive: true });
  fs.writeFileSync(path.join(odd, 'haseen/agents/openrouter/key'), `${FILE_KEY}\n`);
  const bin = minimalBin(dirs, ['bash', 'date', 'mktemp', 'rm', 'cat', 'env', 'cp', 'curl']);
  ({ json } = await run(dirs, { env: { PATH: `${dirs.shim}:${bin}`, XDG_CONFIG_HOME: odd } }));
  assert.equal(json.error, 'jq is not installed');
  assert.equal(json.keySource, path.join(odd, 'haseen/agents/openrouter/key'));
  assert.equal(json.noKey, false);
  assert.equal(fx.requests.length, 0);
});

// ── key sources ──────────────────────────────────────────────────────────────
test('key precedence: OPENROUTER_API_KEY, OPENROUTER_KEY, then the two files', async (t) => {
  const dirs = sandbox(t);
  const primary = path.join(dirs.config, 'haseen/agents/openrouter/key');
  const secondary = path.join(dirs.config, 'openrouter/key');
  fs.mkdirSync(path.dirname(primary), { recursive: true });
  fs.mkdirSync(path.dirname(secondary), { recursive: true });
  fs.writeFileSync(primary, `${FILE_KEY}\n`);
  fs.writeFileSync(secondary, `${OTHER_KEY}\n`);
  const cases = [
    [{ OPENROUTER_API_KEY: KEY, OPENROUTER_KEY: OTHER_KEY }, KEY, 'OPENROUTER_API_KEY'],
    [{ OPENROUTER_KEY: OTHER_KEY }, OTHER_KEY, 'OPENROUTER_KEY'],
    [{}, FILE_KEY, primary],
  ];
  for (const [env, expected, source] of cases) {
    serve({ credits: forbidden403, key: keyInfo({ usage: 1 }) });
    const { json } = await run(dirs, { env });
    assert.equal(json.keySource, source);
    assert.equal(fx.requests[0].auth, `Bearer ${expected}`);
  }
  // The first file holds only comments and blanks: not a hit, the second wins.
  fs.writeFileSync(primary, '# saved later\n\n   \n');
  serve({ credits: forbidden403, key: keyInfo({ usage: 1 }) });
  const { json } = await run(dirs);
  assert.equal(json.keySource, secondary);
  assert.equal(fx.requests[0].auth, `Bearer ${OTHER_KEY}`);
});

test('key file: comments, blanks, whitespace, CRLF, BOM; HOME fallback', async (t) => {
  const dirs = sandbox(t);
  const file = path.join(dirs.home, '.config/haseen/agents/openrouter/key');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const spaced = `  ${FILE_KEY.slice(0, 10)} \t${FILE_KEY.slice(10)}  `;
  for (const content of [
    `# OpenRouter key\n\n   # indented comment\n\t\n${spaced}\nsecond-line-is-ignored-entirely\n`,
    `# a\r\n\r\n${FILE_KEY}\r\n`,
    FILE_KEY,
    `\ufeff${FILE_KEY}\n`,
    `\ufeff# comment after a BOM\n${FILE_KEY}\n`,
  ]) {
    fs.writeFileSync(file, content);
    serve({ credits: forbidden403, key: keyInfo({ usage: 1 }) });
    const { json } = await run(dirs, { env: { XDG_CONFIG_HOME: undefined } });
    assert.equal(json.keySource, file, JSON.stringify(content.slice(0, 20)));
    assert.equal(fx.requests[0]?.auth, `Bearer ${FILE_KEY}`, JSON.stringify(content.slice(0, 20)));
  }
});

test('key file: an over-long line is discarded whole, never split into a key', async (t) => {
  const dirs = sandbox(t);
  const file = path.join(dirs.config, 'haseen/agents/openrouter/key');
  fs.mkdirSync(path.dirname(file), { recursive: true });

  // A 5000-character comment whose tail is a perfectly valid key.
  fs.writeFileSync(file, `#${'c'.repeat(4999 - KEY.length)}${KEY}\n`);
  serve({ credits: forbidden403, key: keyInfo({ usage: 1 }) });
  let { json, calls } = await run(dirs);
  assert.equal(calls.length, 0, 'the tail of a comment was sent as a key');
  assert.equal(json.noKey, true);

  // Exactly 4096 bytes on the first line, the real key on the next one.
  for (const first of [`#${'c'.repeat(4095)}`, `#${'c'.repeat(4094)}`, `#${'c'.repeat(8191)}`]) {
    fs.writeFileSync(file, `${first}\n${FILE_KEY}\n`);
    serve({ credits: forbidden403, key: keyInfo({ usage: 1 }) });
    ({ json } = await run(dirs));
    assert.equal(fx.requests[0]?.auth, `Bearer ${FILE_KEY}`, `after a ${first.length}-byte line`);
  }
});

test('key allowlist: unsafe or malformed keys make zero requests', async (t) => {
  const dirs = sandbox(t);
  const bad = [
    `${KEY}"`, // quote: would close the curl config string
    `${KEY}\\`, // backslash: a curl config escape
    `${KEY}\u00a0x`, // a non-ASCII space survives whitespace stripping
    'sk-or-v1-short', // 14 chars
    'a'.repeat(15),
    'a'.repeat(257),
    `${KEY}";url="http://127.0.0.1:1/x`,
    `${KEY}é`,
  ];
  for (const key of bad) {
    serve({ credits: credits(1, 0), key: keyInfo({}) });
    const { json, calls, stdout } = await run(dirs, { env: { OPENROUTER_API_KEY: key }, secrets: [key] });
    assert.equal(calls.length, 0, `no curl for ${JSON.stringify(key)}`);
    assert.equal(fx.requests.length, 0);
    assert.equal(json.ok, false);
    assert.equal(json.noKey, false);
    assert.equal(json.error, 'That is not a valid OpenRouter key');
    assert.match(json.hint, /openrouter\.ai\/settings\/management-keys/);
    assert.ok(!stdout.includes(key));
  }
  // Same rule for a key file, and it does not fall through to the next source.
  const file = path.join(dirs.config, 'haseen/agents/openrouter/key');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${KEY}'\n`);
  serve({ credits: credits(1, 0) });
  const { json, calls } = await run(dirs, { secrets: [KEY] });
  assert.equal(calls.length, 0);
  assert.equal(json.error, 'That is not a valid OpenRouter key');
  assert.equal(json.keySource, file);
});

test('key allowlist is ASCII under a UTF-8 locale too', { skip: UTF8_LOCALE ? false : 'no UTF-8 locale installed (locale -a)' }, async (t) => {
  const dirs = sandbox(t);
  for (const odd of ['\u00e9', '\u0130', '\uff21', '\u00df', '\u00aa']) {
    const key = KEY.slice(0, 30) + odd + KEY.slice(30);
    serve({ credits: credits(1, 0), key: keyInfo({}), activity: activity([]) });
    const { json, calls } = await run(dirs, { env: { OPENROUTER_API_KEY: key, LC_ALL: UTF8_LOCALE }, secrets: [key] });
    assert.equal(json.error, 'That is not a valid OpenRouter key', `${JSON.stringify(odd)} under ${UTF8_LOCALE}`);
    assert.equal(calls.length, 0);
    assert.equal(fx.requests.length, 0);
  }
});

test('whitespace inside an env key is stripped before it reaches curl', async (t) => {
  const dirs = sandbox(t);
  serve({ credits: forbidden403, key: keyInfo({ usage: 1 }) });
  const spaced = `  ${KEY.slice(0, 12)} ${KEY.slice(12, 20)}\n${KEY.slice(20)}\t`;
  const { calls } = await run(dirs, { env: { OPENROUTER_API_KEY: spaced } });
  assert.equal(fx.requests[0].auth, `Bearer ${KEY}`);
  assert.ok(calls[0].config.includes(`Bearer ${KEY}"`));
});

test('OPENROUTER_API_BASE: only a loopback http URL is honoured', async (t) => {
  const dirs = sandbox(t);
  for (const base of [
    'http://evil.example/api/v1',
    'https://127.0.0.1:1',
    `http://user:pw@127.0.0.1:${port}/api/v1`,
    `http://127.0.0.1@evil.example:${port}/api/v1`,
    `http://127.0.0.1:${port}/api/v1?x=1`,
    `http://127.0.0.1:${port}/api/v1"`,
    `http://127.0.0.2:${port}/api/v1`,
    'file:///etc/passwd',
  ]) {
    serve({ credits: credits(1, 0) });
    const { json, calls } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY, OPENROUTER_API_BASE: base } });
    assert.equal(calls.length, 0, `no curl for ${base}`);
    assert.equal(fx.requests.length, 0);
    assert.equal(json.ok, false);
    assert.equal(json.error, 'OPENROUTER_API_BASE must be a loopback URL');
  }
  serve({ credits: forbidden403, key: keyInfo({ usage: 1 }) });
  const { json } = await run(dirs, {
    env: { OPENROUTER_API_KEY: KEY, OPENROUTER_API_BASE: `http://localhost:${port}/api/v1/` },
  });
  assert.equal(json.ok, true, 'localhost with a trailing slash is accepted');
  assert.deepEqual(paths(), ['credits', 'key']);
});

// ── the shell's own environment ──────────────────────────────────────────────
test('inherited SHELLOPTS=xtrace and BASH_ENV cannot expose the key', async (t) => {
  const dirs = sandbox(t);
  const marker = path.join(dirs.root, 'hook-ran');
  const hook = path.join(dirs.root, 'hook.sh');
  fs.writeFileSync(hook, `printf '%s\\n' "$0 \${OPENROUTER_API_KEY:-}" >> ${JSON.stringify(marker)}\n`);
  serve({ credits: forbidden403, key: keyInfo({ usage: 1 }) });
  const { json } = await run(dirs, {
    env: { OPENROUTER_API_KEY: KEY, SHELLOPTS: 'xtrace', BASHOPTS: 'xpg_echo', BASH_ENV: hook, ENV: hook },
  });
  assert.equal(json.ok, true);
  assert.ok(!fs.existsSync(marker), 'BASH_ENV ran inside the helper');
});

test('caller-exported variables named like internals never carry the key to curl', async (t) => {
  const dirs = sandbox(t);
  serve({ credits: forbidden403, key: keyInfo({ label: KEY, usage: 1 }) });
  const names = ['api_key', 'key_source', 'candidate', 'file_key', 'line', 'text', 'body', 'raw',
    'message', 'key_label', 'key_limit_reset', 'key_error', 'account_error', 'error', 'base'];
  const exported = Object.fromEntries(names.map((n) => [n, 'harmless']));
  const { json, calls } = await run(dirs, { env: { ...exported, OPENROUTER_API_KEY: KEY } });
  assert.equal(json.ok, true);
  assert.equal(calls.length, 2);
  // run() asserts the key is absent from every curl environment.
});

// ── no server free text: fixed messages, enum reset, validated mask label ───
// Each form is [error-body literal, label literal, reset literal] as raw JSON.
const lit = (s) => JSON.stringify(s);
const thirds = (s) => [s.slice(0, 22), s.slice(22, 44), s.slice(44)];
const ECHO_FORMS = {
  verbatim: [KEY, KEY, KEY].map(lit),
  'case swapped': Array(3).fill(lit([...KEY].map((c) => (c === c.toLowerCase() ? c.toUpperCase() : c.toLowerCase())).join(''))),
  'in-alphabet insert': Array(3).fill(lit(KEY.replace(/(.{4})/g, '$1x'))),
  'percent-encoded': Array(3).fill(lit([...KEY].map((c) => `%${c.charCodeAt(0).toString(16)}`).join(''))),
  'JSON-escaped': Array(3).fill(`"${[...KEY].map((c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`).join('')}"`),
  'U+0890 inserted': Array(3).fill(lit(`${KEY.slice(0, 20)}\u0890${KEY.slice(20, 50)}\u0890${KEY.slice(50)}`)),
  'split across fields': thirds(KEY).map(lit),
  'echoed twice': Array(3).fill(lit(`${KEY} and again ${KEY}`)),
};

// Every 12-character window of the whole key, case-insensitively.
const windows12 = (() => {
  const k = KEY.toLowerCase();
  return Array.from({ length: k.length - 11 }, (_, i) => k.slice(i, i + 12));
})();
function assertNoWindow(text, where) {
  const lower = text.toLowerCase();
  const hit = windows12.find((w) => lower.includes(w));
  assert.equal(hit, undefined, `a 12-character piece of the key in ${where}`);
}
const raw = (status, text) => ({ status, body: text });

test('a key echoed in any form never reaches the output, the baseline or curl argv', async (t) => {
  const dirs = sandbox(t);
  for (const [name, [errLit, labelLit, resetLit]] of Object.entries(ECHO_FORMS)) {
    const errBody = `{"error":{"message":${errLit},"code":1},"message":${errLit}}`;
    const scenarios = [
      [{ credits: raw(401, errBody) },
        { error: 'OpenRouter rejected the key', accountError: 'OpenRouter rejected the key' }],
      [{ credits: raw(402, errBody), key: raw(429, errBody) },
        { error: 'Rate limited by OpenRouter', accountError: 'The OpenRouter account is out of credit',
          keyError: 'Rate limited by OpenRouter' }],
      [{ credits: credits(50, 20), activity: raw(500, errBody),
        key: raw(200, `{"data":{"label":${labelLit},"limit_reset":${resetLit},"usage":1},"error":{"message":${errLit}}}`) },
        { error: '', accountError: '', keyError: '', activityError: 'OpenRouter returned HTTP 500',
          keyLabel: MASK, keyLimitReset: '' }],
    ];
    for (const [routes, expected] of scenarios) {
      fs.rmSync(path.dirname(todayFile(dirs)), { recursive: true, force: true });
      serve(routes);
      const { json, stdout, calls } = await run(dirs, pinned());
      for (const [field, value] of Object.entries(expected)) assert.equal(json[field], value, `${name}: ${field}`);
      assert.equal(json.keyLabel, MASK, `${name}: keyLabel`);
      assertNoWindow(stdout, `${name}: stdout`);
      for (const call of calls) assertNoWindow(call.argv.join(' '), `${name}: curl argv`);
      if (fs.existsSync(todayFile(dirs))) {
        assertNoWindow(fs.readFileSync(todayFile(dirs), 'utf8'), `${name}: baseline`);
        assert.equal(readBaseline(dirs).keyLabel, MASK, `${name}: baseline label`);
      }
    }
  }
});

test('keyLabel is computed locally: public prefix (if any) plus the last 4 characters', async (t) => {
  const dirs = sandbox(t);
  const keys = [
    [KEY, `sk-or-v1-...${KEY.slice(-4)}`],
    [OTHER_KEY, 'sk-or-v1-...3210'],
    [FILE_KEY, 'sk-or-v1-...6666'],
    ['abcdefghijklmnopqrstuvwxyz0123', '...0123'],
    ['sk-or-v2-ABCDEFGHIJKLMNOP9876', '...9876'],
    ['0123456789abcdef', '...cdef'],
  ];
  for (const [key, expected] of keys) {
    fs.rmSync(path.dirname(todayFile(dirs)), { recursive: true, force: true });
    serve(ledger(30, 'server label'));
    const { json } = await run(dirs, pinned({ OPENROUTER_API_KEY: key }));
    assert.equal(json.keyLabel, expected, key);
    assert.equal(readBaseline(dirs).keyLabel, expected, key);
  }
  // No valid key: no label.
  serve({});
  const { json } = await run(dirs, { env: { OPENROUTER_API_KEY: 'short' }, secrets: [] });
  assert.equal(json.keyLabel, '');
});

test('the server’s label is ignored entirely', async (t) => {
  const dirs = sandbox(t);
  const hostile = [
    lit(KEY), lit(OTHER_MASK), lit(`${KEY.slice(0, 12)}...${KEY.slice(-3)}`), lit(MASK), lit(''),
    lit(`LONGLABEL${'q'.repeat(5000)}`), '12345678', lit('ctl\u0007fmt\u200bEND'), 'null', '{"x":1}',
  ];
  for (const labelLit of hostile) {
    fs.rmSync(path.dirname(todayFile(dirs)), { recursive: true, force: true });
    serve({
      credits: credits(50, 20),
      key: raw(200, `{"data":{"label":${labelLit},"usage":1,"is_management_key":true}}`),
      activity: activity([]),
    });
    const { json, stdout } = await run(dirs, pinned());
    assert.equal(json.keyLabel, MASK, labelLit.slice(0, 40));
    assert.equal(readBaseline(dirs).keyLabel, MASK);
    const state = fs.readFileSync(todayFile(dirs), 'utf8');
    for (const marker of ['LONGLABEL', '12345678', 'ctl', 'END', OTHER_MASK, `${KEY.slice(0, 12)}...`]) {
      assert.ok(!stdout.includes(marker), `${marker} in stdout`);
      assert.ok(!state.includes(marker), `${marker} in the baseline`);
    }
  }
});

test('keyLimitReset: only the three literal words', async (t) => {
  const dirs = sandbox(t);
  for (const reset of ['daily', 'weekly', 'monthly']) {
    serve({ credits: forbidden403, key: keyInfo({ limit_reset: reset, usage: 1 }) });
    assert.equal((await run(dirs, { env: { OPENROUTER_API_KEY: KEY } })).json.keyLimitReset, reset);
  }
  for (const reset of ['Daily', 'daily\n', ' daily', 'daily\u200b', 'yearly', '', 7, null, ['daily']]) {
    serve({ credits: forbidden403, key: keyInfo({ limit_reset: reset, usage: 1 }) });
    assert.equal((await run(dirs, { env: { OPENROUTER_API_KEY: KEY } })).json.keyLimitReset, '', JSON.stringify(reset));
  }
});

test('every message is the fixed text for its status; a server message is never shown', async (t) => {
  const dirs = sandbox(t);
  const topUp = { error: { message: 'Please top up', code: 1 }, message: 'Please top up' };
  const keyCases = [
    [401, 'OpenRouter rejected the key'],
    [402, 'The OpenRouter account is out of credit'],
    [403, 'OpenRouter refused the request'],
    [429, 'Rate limited by OpenRouter'],
    [500, 'OpenRouter returned HTTP 500'],
    [404, 'OpenRouter returned HTTP 404'],
  ];
  for (const [status, text] of keyCases) {
    serve({ credits: { status: 403, body: topUp }, key: { status, body: topUp } });
    const { json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } });
    assert.equal(json.accountError, 'needs a management key', `credits 403 (key ${status})`);
    assert.equal(json.activityError, 'needs a management key');
    assert.equal(json.keyError, text, `key ${status}`);
    assert.equal(json.error, text);
  }
  for (const [status, text] of [[402, 'The OpenRouter account is out of credit'], [429, 'Rate limited by OpenRouter'],
    [500, 'OpenRouter returned HTTP 500'], [404, 'OpenRouter returned HTTP 404']]) {
    serve({ credits: { status, body: topUp }, key: keyInfo({ usage: 1 }) });
    const { json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } });
    assert.equal(json.accountError, text, `credits ${status}`);
    assert.equal(json.needsManagementKey, false);
  }
  serve({ credits: credits(5, 1), key: keyInfo({ usage: 1 }), activity: { status: 403, body: topUp } });
  let { json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } });
  assert.equal(json.activityError, 'OpenRouter refused the request');

  serve({ credits: { status: 200, body: topUp }, key: { status: 200, body: topUp } });
  ({ json } = await run(dirs, { env: { OPENROUTER_API_KEY: KEY } }));
  assert.equal(json.accountError, 'OpenRouter returned an unusable reply');
  assert.equal(json.keyError, 'OpenRouter returned an unusable reply');
  assert.ok(!JSON.stringify(json).includes('top up'));
});

test('the scratch directory never holds the key or a raw body, even mid-transfer', async (t) => {
  const dirs = sandbox(t);
  serve({
    credits: { status: 200, body: { data: { total_credits: 9, total_usage: 1, echo: KEY } } },
    key: keyInfo({ label: `label ${KEY}`, usage: 1, echo: KEY }),
    activity: { status: 200, body: { data: [{ date: '2026-10-06', usage: 1, echo: KEY }] } },
  });
  const { json, calls } = await run(dirs, pinned({ CURL_SHIM_SNAP: '1' }));
  assert.equal(calls.length, 3);
  assert.equal(json.ok, true);
  const snaps = fs.readdirSync(dirs.log).filter((n) => n.startsWith('snap.'));
  assert.equal(snaps.length, 6, 'a snapshot before and after every transfer');
  for (const snap of snaps) {
    for (const file of filesUnder(path.join(dirs.log, snap))) {
      const text = fs.readFileSync(file, 'latin1');
      assert.deepEqual(leaks(text, KEY), [], `${snap}: ${path.basename(file)}`);
      assert.ok(!text.includes('"echo"'), `${snap}: raw body on disk in ${path.basename(file)}`);
    }
  }
});

// ── /activity calendar maths, clock pinned ───────────────────────────────────
async function sums(dirs, now, rows) {
  serve({ credits: credits(10, 1), key: keyInfo({ label: 'mg' }), activity: activity(rows) });
  const { json } = await run(dirs, pinned({}, now));
  return [json.usageWeekly, json.usageMonthly];
}

test('week starts Monday 00:00 UTC; month by YYYY-MM', async (t) => {
  const dirs = sandbox(t);
  // Monday 2026-10-05 00:00:05: nothing of this week is settled yet.
  assert.deepEqual(await sums(dirs, at(2026, 10, 5, 0, 0, 5),
    [{ date: '2026-10-04', usage: 1 }, { date: '2026-09-28', usage: 2 }, { date: '2026-10-01', usage: 4 }]), [0, 5]);
  // Sunday 2026-10-04 23:59:59: the week began Monday 2026-09-28.
  assert.deepEqual(await sums(dirs, at(2026, 10, 4, 23, 59, 59),
    [{ date: '2026-09-27', usage: 100 }, { date: '2026-09-28', usage: 1 }, { date: '2026-10-03', usage: 2 }]), [3, 2]);
  // The 1st (a Sunday): month is empty, the week reaches back into October.
  assert.deepEqual(await sums(dirs, at(2026, 11, 1),
    [{ date: '2026-10-31', usage: 7 }, { date: '2026-10-26', usage: 1 }, { date: '2026-10-25', usage: 50 }]), [8, 0]);
  // Leap day: Wed 2028-03-01, the week began Mon 2028-02-28.
  assert.deepEqual(await sums(dirs, at(2028, 3, 1, 1),
    [{ date: '2028-02-29', usage: 1 }, { date: '2028-02-28', usage: 2 }, { date: '2028-02-27', usage: 50 }]), [3, 0]);
  // Year boundary: Fri 2027-01-01, the week began Mon 2026-12-28.
  assert.deepEqual(await sums(dirs, at(2027, 1, 1, 1),
    [{ date: '2026-12-28', usage: 1 }, { date: '2026-12-27', usage: 50 }]), [1, 0]);
});

test('odd /activity rows: garbage, future and today-dated rows never count', async (t) => {
  const dirs = sandbox(t);
  const [week, month] = await sums(dirs, NOW, [
    { date: '2026-10-06', usage: 1 },
    { date: '2026-10-06T00:00:00Z', usage: 2 },
    { date: 'zzzz', usage: 1000 },
    { date: '9999-12-31', usage: 1000 },
    { date: TODAY, usage: 1000 }, // would double count with spendToday
    { date: '2026-10-08', usage: 1000 },
    { date: '', usage: 1000 },
    { date: '2026-10', usage: 1000 },
    { date: 20261006, usage: 1000 },
    { date: '2026-10-06', usage: -0.5 },
    { date: '2026-10-06', usage: null },
  ]);
  assert.equal(week, 2.5);
  assert.equal(month, 2.5);
});

// ── the today baseline ───────────────────────────────────────────────────────
const ledger = (spent, label = MASK) => ({
  credits: credits(50, spent),
  key: keyInfo({ label, is_management_key: true }),
  activity: activity([]),
});

test('baseline: same day + label diff, never negative, stale date and other account reset', async (t) => {
  const dirs = sandbox(t);
  serve(ledger(30));
  writeBaseline(dirs, { date: TODAY, baseline: 29.5, keyLabel: MASK, at: 1000 });
  let { json } = await run(dirs, pinned());
  assert.equal(json.spendToday, 0.5, 'same day, same label: difference');
  assert.equal(json.spendTodaySince, 1000);

  writeBaseline(dirs, { date: TODAY, baseline: 40, keyLabel: MASK, at: 1000 });
  ({ json } = await run(dirs, pinned()));
  assert.equal(json.spendToday, 0, 'never negative');

  writeBaseline(dirs, { date: isoDay(NOW - DAY), baseline: 10, keyLabel: MASK, at: 1000 });
  ({ json } = await run(dirs, pinned()));
  assert.equal(json.spendToday, 0, 'stale date resets');
  assert.equal(json.spendTodaySince, NOW);
  assert.deepEqual(readBaseline(dirs), { date: TODAY, baseline: 30, keyLabel: MASK, at: NOW });

  writeBaseline(dirs, { date: TODAY, baseline: 10, keyLabel: OTHER_MASK, at: 1000 });
  ({ json } = await run(dirs, pinned()));
  assert.equal(json.spendToday, 0, 'two known, different labels: another account, reset');
  assert.deepEqual(readBaseline(dirs), { date: TODAY, baseline: 30, keyLabel: MASK, at: NOW });

  writeBaseline(dirs, '{"date": "broken');
  ({ json } = await run(dirs, pinned()));
  assert.equal(json.ok, true);
  assert.equal(json.spendToday, 0, 'corrupt baseline resets');
  assert.equal(readBaseline(dirs).baseline, 30);
});

test('baseline: a /key failure keeps keyLabel and today’s spend; a later healthy poll continues it', async (t) => {
  const dirs = sandbox(t);
  writeBaseline(dirs, { date: TODAY, baseline: 10, keyLabel: MASK, at: NOW - 3600 });
  const cutOff = (req, res) => {
    res.writeHead(200, { 'content-type': 'application/json', 'content-length': '500' });
    res.write('{"data":{"label":');
    setTimeout(() => res.socket.destroy(), 20);
  };
  let spent = 12;
  for (const failing of [{ status: 500, body: { error: { message: 'Internal' } } }, { status: 200, body: 'garbage' }, cutOff]) {
    serve({ credits: credits(50, spent), key: failing, activity: activity([]) });
    const { json } = await run(dirs, pinned());
    assert.equal(json.keyLabel, MASK);
    assert.equal(json.spendToday, spent - 10, 'ledger fine, only /key failed');
    assert.equal(json.spendTodaySince, NOW - 3600);
    assert.deepEqual(readBaseline(dirs), { date: TODAY, baseline: 10, keyLabel: MASK, at: NOW - 3600 });
    spent += 1;
  }
  serve(ledger(20));
  const { json } = await run(dirs, pinned({}, NOW + 60));
  assert.equal(json.spendToday, 10, 'same baseline after the failures');
  assert.equal(json.spendTodaySince, NOW - 3600);
});

test('baseline: the same day with a different key (key file replaced) resets', async (t) => {
  const dirs = sandbox(t);
  const file = path.join(dirs.config, 'haseen/agents/openrouter/key');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${KEY}\n`);
  serve(ledger(20));
  let { json } = await run(dirs, pinned({ OPENROUTER_API_KEY: undefined }));
  assert.equal(json.keyLabel, MASK);
  serve(ledger(25));
  ({ json } = await run(dirs, pinned({ OPENROUTER_API_KEY: undefined }, NOW + 60)));
  assert.equal(json.spendToday, 5);

  fs.writeFileSync(file, `${OTHER_KEY}\n`);
  serve(ledger(27));
  ({ json } = await run(dirs, pinned({ OPENROUTER_API_KEY: undefined }, NOW + 120)));
  assert.equal(json.keyLabel, OTHER_MASK);
  assert.equal(json.spendToday, 0, 'another key: new baseline');
  assert.equal(json.spendTodaySince, NOW + 120);
  assert.deepEqual(readBaseline(dirs), { date: TODAY, baseline: 27, keyLabel: OTHER_MASK, at: NOW + 120 });
});

test('baseline: loose existing modes are tightened to 700/600 on every run', async (t) => {
  const dirs = sandbox(t);
  writeBaseline(dirs, { date: TODAY, baseline: 29, keyLabel: MASK, at: 1000 });
  fs.chmodSync(path.dirname(todayFile(dirs)), 0o755);
  fs.chmodSync(todayFile(dirs), 0o644);
  serve(ledger(30));
  const { json } = await run(dirs, pinned());
  assert.equal(json.spendToday, 1, 'reused, not rewritten');
  assert.equal(mode(path.dirname(todayFile(dirs))), 0o700);
  assert.equal(mode(todayFile(dirs)), 0o600);
});

test('baseline: a directory or symlink at the path is left alone and spendToday is null', async (t) => {
  const dirs = sandbox(t);
  serve(ledger(30));
  fs.mkdirSync(todayFile(dirs), { recursive: true });
  for (let i = 0; i < 2; i++) {
    const { json } = await run(dirs, pinned());
    assert.equal(json.ok, true);
    assert.equal(json.funded, 50);
    assert.equal(json.spendToday, null);
    assert.equal(json.spendTodaySince, null);
  }
  assert.deepEqual(fs.readdirSync(todayFile(dirs)), [], 'nothing written into the directory');
  assert.deepEqual(fs.readdirSync(path.dirname(todayFile(dirs))), ['today-spend.json'], 'no temp litter');
  fs.rmdirSync(todayFile(dirs));

  // A symlink to a file outside: neither followed for reading nor written through.
  const victim = path.join(dirs.root, 'victim');
  fs.writeFileSync(victim, JSON.stringify({ date: TODAY, baseline: 1, keyLabel: 'acct-a', at: 5 }));
  fs.symlinkSync(victim, todayFile(dirs));
  const { json } = await run(dirs, pinned());
  assert.equal(json.spendToday, null);
  assert.deepEqual(JSON.parse(fs.readFileSync(victim, 'utf8')), { date: TODAY, baseline: 1, keyLabel: 'acct-a', at: 5 });
  assert.ok(fs.lstatSync(todayFile(dirs)).isSymbolicLink());
});

test('baseline: a symlinked state directory is not used', async (t) => {
  const dirs = sandbox(t);
  const elsewhere = path.join(dirs.root, 'elsewhere');
  fs.mkdirSync(elsewhere, { mode: 0o755 });
  fs.chmodSync(elsewhere, 0o755);
  fs.mkdirSync(path.join(dirs.state, 'haseen/agents'), { recursive: true });
  fs.symlinkSync(elsewhere, path.dirname(todayFile(dirs)));
  serve(ledger(30));
  const { json } = await run(dirs, pinned());
  assert.equal(json.ok, true);
  assert.equal(json.spendToday, null);
  assert.deepEqual(fs.readdirSync(elsewhere), []);
  assert.equal(mode(elsewhere), 0o755, 'not chmodded through the link');
});

test('baseline: unwritable state or no usable HOME never fails the fetch', async (t) => {
  const dirs = sandbox(t);
  serve(ledger(30));
  const blocker = path.join(dirs.root, 'not-a-dir');
  fs.writeFileSync(blocker, '');
  let { json } = await run(dirs, pinned({ XDG_STATE_HOME: blocker }));
  assert.equal(json.ok, true, 'a failed state write never fails the fetch');
  assert.equal(json.funded, 50);
  assert.equal(json.spendToday, null);

  ({ json } = await run(dirs, pinned({ HOME: undefined, XDG_STATE_HOME: undefined })));
  assert.equal(json.ok, true);
  assert.equal(json.spendToday, null, 'no absolute state home: baseline skipped');

  ({ json } = await run(dirs, pinned({ HOME: 'relative', XDG_STATE_HOME: 'also-relative' })));
  assert.equal(json.spendToday, null);
  assert.ok(!fs.existsSync(path.join(process.cwd(), 'relative')) && !fs.existsSync(path.join(process.cwd(), 'also-relative')));
});
