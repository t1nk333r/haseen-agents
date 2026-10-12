// bin/openrouter-save-key: stdin in, one JSON line out, key file mode 600 in a
// mode 700 directory, replaced atomically. All keys here are fake.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.resolve(here, '../../bin/openrouter-save-key');
const ALPHA = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-';
const KEY = `sk-or-v1-${ALPHA}`;
const OLD_KEY = `sk-or-v1-${[...ALPHA].reverse().join('')}`;
const REAL_JQ = execFileSync('bash', ['-c', 'command -v jq']).toString().trim();

const UTF8_LOCALE = (() => {
  try {
    const all = execFileSync('locale', ['-a']).toString().split('\n');
    return ['en_US.UTF-8', 'en_US.utf8', 'C.UTF-8', 'C.utf8']
      .find((l) => all.includes(l)) ?? all.find((l) => /utf-?8/i.test(l)) ?? null;
  } catch { return null; }
})();

function sandbox(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'or-save-key-test-'));
  const dirs = { root, home: path.join(root, 'home'), config: path.join(root, 'config') };
  fs.mkdirSync(dirs.home);
  t.after(() => {
    try { fs.chmodSync(root, 0o700); } catch {}
    fs.rmSync(root, { recursive: true, force: true });
  });
  return dirs;
}

// Every 16-character window of the key's secret part.
const leaks = (text, key) => {
  const body = key.slice(9);
  const found = [];
  for (let i = 0; i + 16 <= body.length; i++) if (text.includes(body.slice(i, i + 16))) found.push(i);
  return found;
};

// `input === null` closes stdin without writing anything (EOF at once).
async function save(dirs, input, env = {}) {
  const fullEnv = { PATH: process.env.PATH, HOME: dirs.home, XDG_CONFIG_HOME: dirs.config, ...env };
  for (const [name, value] of Object.entries(fullEnv)) if (value === undefined) delete fullEnv[name];
  const started = Date.now();
  const child = spawn(SCRIPT, [], { env: fullEnv, stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (d) => { stdout += d; });
  child.stderr.on('data', (d) => { stderr += d; });
  child.stdin.on('error', () => {});
  if (input !== null) child.stdin.write(input);
  child.stdin.end();
  const code = await new Promise((resolve) => child.on('close', resolve));
  assert.equal(code, 0, 'always exits 0');
  assert.equal(stderr, '', 'nothing on stderr');
  for (const key of [KEY, OLD_KEY]) assert.deepEqual(leaks(stdout, key), [], 'no piece of a key on stdout');
  const lines = stdout.trim().split('\n');
  assert.equal(lines.length, 1, `one JSON line, got: ${stdout}`);
  return { json: JSON.parse(lines[0]), stdout, elapsed: Date.now() - started };
}

const keyPath = (dirs) => path.join(dirs.config, 'haseen/agents/openrouter/key');
const mode = (p) => fs.statSync(p).mode & 0o777;

// The credits helper's rule: first line neither blank nor a comment.
const storedKey = (file) => fs.readFileSync(file, 'utf8').split('\n')
  .map((l) => l.replace(/\s/g, '')).find((l) => l && !l.startsWith('#'));

function filesUnder(dir) {
  return fs.readdirSync(dir, { recursive: true, withFileTypes: true })
    .filter((e) => e.isFile())
    .map((e) => path.join(e.parentPath ?? e.path, e.name));
}

test('saves a pasted key: mode 600 file in a mode 700 dir, key never printed', async (t) => {
  const dirs = sandbox(t);
  const { json } = await save(dirs, `  ${KEY.slice(0, 9)} ${KEY.slice(9)}\t\r\n`);
  assert.deepEqual(json, { ok: true, path: keyPath(dirs) });
  assert.equal(mode(path.dirname(keyPath(dirs))), 0o700);
  assert.equal(mode(keyPath(dirs)), 0o600);
  const lines = fs.readFileSync(keyPath(dirs), 'utf8').split('\n');
  assert.ok(lines[0].startsWith('#') && lines[1].startsWith('#'), 'two comment lines first');
  assert.equal(lines[2], KEY);
  assert.equal(storedKey(keyPath(dirs)), KEY);
});

test('a final line without a newline is accepted; HOME fallback; relative XDG ignored', async (t) => {
  const dirs = sandbox(t);
  const expected = path.join(dirs.home, '.config/haseen/agents/openrouter/key');
  for (const xdg of [undefined, 'relative/cfg']) {
    const { json } = await save(dirs, KEY, { XDG_CONFIG_HOME: xdg });
    assert.deepEqual(json, { ok: true, path: expected });
    assert.equal(storedKey(expected), KEY);
  }
});

test('HOME unset (or relative) and no absolute XDG_CONFIG_HOME: "HOME is not set"', async (t) => {
  const dirs = sandbox(t);
  for (const home of [undefined, 'relative-home']) {
    const { json } = await save(dirs, `${KEY}\n`, { HOME: home, XDG_CONFIG_HOME: undefined });
    assert.deepEqual(json, { ok: false, error: 'HOME is not set' });
  }
  assert.ok(!fs.existsSync(path.join(process.cwd(), 'relative-home')));
});

test('only the first line is read', async (t) => {
  const dirs = sandbox(t);
  const { json } = await save(dirs, `${KEY}\n${OLD_KEY}\n`);
  assert.equal(json.ok, true);
  assert.equal(storedKey(keyPath(dirs)), KEY);
});

test('replaces an existing key atomically and tightens the directory', async (t) => {
  const dirs = sandbox(t);
  const dir = path.dirname(keyPath(dirs));
  fs.mkdirSync(dir, { recursive: true, mode: 0o755 });
  fs.chmodSync(dir, 0o755);
  fs.writeFileSync(keyPath(dirs), `${OLD_KEY}\n`, { mode: 0o644 });
  const before = fs.statSync(keyPath(dirs)).ino;
  const { json } = await save(dirs, `${KEY}\n`);
  assert.equal(json.ok, true);
  assert.notEqual(fs.statSync(keyPath(dirs)).ino, before, 'renamed into place, not rewritten');
  assert.equal(mode(keyPath(dirs)), 0o600);
  assert.equal(mode(dir), 0o700);
  assert.equal(storedKey(keyPath(dirs)), KEY);
  assert.deepEqual(fs.readdirSync(dir), ['key'], 'no temp file left behind');
});

test('rejects empty, short and unsafe input without writing or echoing it', async (t) => {
  const dirs = sandbox(t);
  const cases = [
    ['\n', 'No key given'],
    ['   \t \n', 'No key given'],
    ['sk-or-v1-short\n', 'That is not a valid OpenRouter key'],
    [`${KEY}"\n`, 'That is not a valid OpenRouter key'],
    [`${KEY}\\\n`, 'That is not a valid OpenRouter key'],
    [`${KEY}'\n`, 'That is not a valid OpenRouter key'],
    [`${KEY}\u00a0\n`, 'That is not a valid OpenRouter key'],
    [`${'a'.repeat(257)}\n`, 'That is not a valid OpenRouter key'],
    [`${'A'.repeat(4096)}${KEY}\n`, 'That is not a valid OpenRouter key'],
  ];
  for (const [input, error] of cases) {
    const { json, stdout } = await save(dirs, input);
    assert.deepEqual(json, { ok: false, error }, JSON.stringify(input.slice(0, 40)));
    const trimmed = input.trim();
    if (trimmed) assert.ok(!stdout.includes(trimmed), 'input not echoed');
    assert.ok(!fs.existsSync(keyPath(dirs)), 'nothing written');
  }
});

test('the allowlist is ASCII under a UTF-8 locale too', { skip: UTF8_LOCALE ? false : 'no UTF-8 locale installed (locale -a)' }, async (t) => {
  const dirs = sandbox(t);
  for (const odd of ['\u00e9', '\u0130', '\uff21', '\u00df', '\u00aa']) {
    const { json } = await save(dirs, `${KEY.slice(0, 30)}${odd}${KEY.slice(30)}\n`, { LC_ALL: UTF8_LOCALE });
    assert.deepEqual(json, { ok: false, error: 'That is not a valid OpenRouter key' }, `${JSON.stringify(odd)} under ${UTF8_LOCALE}`);
    assert.ok(!fs.existsSync(keyPath(dirs)));
  }
});

test('a rejected key leaves an existing key untouched', async (t) => {
  const dirs = sandbox(t);
  fs.mkdirSync(path.dirname(keyPath(dirs)), { recursive: true });
  fs.writeFileSync(keyPath(dirs), `${OLD_KEY}\n`, { mode: 0o600 });
  const { json } = await save(dirs, 'bad"key"value"here\n');
  assert.equal(json.ok, false);
  assert.equal(storedKey(keyPath(dirs)), OLD_KEY);
});

test('a directory or symlink at the key path is refused, nothing written anywhere', async (t) => {
  const dirs = sandbox(t);
  const dir = path.dirname(keyPath(dirs));
  fs.mkdirSync(keyPath(dirs), { recursive: true });
  let { json } = await save(dirs, `${KEY}\n`);
  assert.deepEqual(json, { ok: false, error: 'The key path is not a regular file' });
  assert.deepEqual(fs.readdirSync(keyPath(dirs)), [], 'nothing moved into the directory');
  fs.rmdirSync(keyPath(dirs));

  const victimFile = path.join(dirs.root, 'victim');
  const victimDir = path.join(dirs.root, 'victim-dir');
  fs.writeFileSync(victimFile, 'precious');
  fs.mkdirSync(victimDir);
  for (const target of [victimFile, victimDir, path.join(dirs.root, 'dangling')]) {
    fs.symlinkSync(target, keyPath(dirs));
    ({ json } = await save(dirs, `${KEY}\n`));
    assert.deepEqual(json, { ok: false, error: 'The key path is not a regular file' }, target);
    assert.ok(fs.lstatSync(keyPath(dirs)).isSymbolicLink(), 'the link is left alone');
    fs.unlinkSync(keyPath(dirs));
  }
  assert.equal(fs.readFileSync(victimFile, 'utf8'), 'precious');
  assert.deepEqual(fs.readdirSync(victimDir), []);
  assert.ok(!fs.existsSync(path.join(dirs.root, 'dangling')));
  assert.deepEqual(fs.readdirSync(dir), [], 'no temp file left behind');
  for (const file of filesUnder(dirs.root)) {
    assert.deepEqual(leaks(fs.readFileSync(file, 'latin1'), KEY), [], `key leaked into ${file}`);
  }
});

test('a symlinked key directory is refused and not chmodded', async (t) => {
  const dirs = sandbox(t);
  const elsewhere = path.join(dirs.root, 'elsewhere');
  fs.mkdirSync(elsewhere);
  fs.chmodSync(elsewhere, 0o755);
  fs.mkdirSync(path.join(dirs.config, 'haseen/agents'), { recursive: true });
  fs.symlinkSync(elsewhere, path.join(dirs.config, 'haseen/agents/openrouter'));
  const { json } = await save(dirs, `${KEY}\n`);
  assert.equal(json.ok, false);
  assert.match(json.error, /^Refusing a key directory that is a symlink or not yours: /);
  assert.deepEqual(fs.readdirSync(elsewhere), []);
  assert.equal(mode(elsewhere), 0o755);
});

test('closed stdin fails fast instead of waiting for the timeout', async (t) => {
  const dirs = sandbox(t);
  const { json, elapsed } = await save(dirs, null);
  assert.deepEqual(json, { ok: false, error: 'No key given' });
  assert.ok(elapsed < 5000, `took ${elapsed} ms`);
  assert.ok(!fs.existsSync(keyPath(dirs)));
});

test('an unwritable location is reported, not crashed on', async (t) => {
  const dirs = sandbox(t);
  const blocker = path.join(dirs.root, 'blocker');
  fs.writeFileSync(blocker, '');
  let { json } = await save(dirs, `${KEY}\n`, { XDG_CONFIG_HOME: blocker });
  assert.equal(json.ok, false);
  assert.match(json.error, /^Could not create /);

  fs.mkdirSync(dirs.config);
  fs.chmodSync(dirs.config, 0o500);
  ({ json } = await save(dirs, `${KEY}\n`));
  assert.equal(json.ok, false);
  assert.match(json.error, /^Could not create /);
});

test('no child process inherits a key from the environment', async (t) => {
  const dirs = sandbox(t);
  const shim = path.join(dirs.root, 'shim');
  const capture = path.join(dirs.root, 'jq-env');
  fs.mkdirSync(shim);
  fs.writeFileSync(path.join(shim, 'jq'), `#!/usr/bin/bash -p\nenv >> ${JSON.stringify(capture)}\nexec ${JSON.stringify(REAL_JQ)} "$@"\n`, { mode: 0o755 });
  const { json } = await save(dirs, `${KEY}\n`, {
    PATH: `${shim}:${process.env.PATH}`, OPENROUTER_API_KEY: OLD_KEY, OPENROUTER_KEY: OLD_KEY,
    key: 'harmless', raw: 'harmless', tmp: 'harmless',
  });
  assert.equal(json.ok, true);
  const seen = fs.readFileSync(capture, 'utf8');
  assert.ok(!seen.includes(OLD_KEY), 'an env key reached jq');
  assert.ok(!seen.includes(KEY), 'the saved key reached jq');
});

test('inherited SHELLOPTS=xtrace and BASH_ENV cannot expose the key', async (t) => {
  const dirs = sandbox(t);
  const marker = path.join(dirs.root, 'hook-ran');
  const hook = path.join(dirs.root, 'hook.sh');
  fs.writeFileSync(hook, `printf '%s\\n' "$0" >> ${JSON.stringify(marker)}\n`);
  const { json } = await save(dirs, `${KEY}\n`, { SHELLOPTS: 'xtrace', BASH_ENV: hook, ENV: hook });
  assert.equal(json.ok, true);
  assert.ok(!fs.existsSync(marker), 'BASH_ENV ran inside the helper');
});
