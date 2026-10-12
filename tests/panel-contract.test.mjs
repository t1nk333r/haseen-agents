// Contract suite for the merged plugin (plan 128).
//
// These are the source rules that fail silently when broken: an id that
// survives in an IPC target, a bar mark that stops being a kit component, a
// hex colour that ignores the theme, a connector backend that starts a shell,
// a DeepSeek state path that points at the old plugin, a settings key nothing
// reads. Text-wording assertions are deliberately not here — the four parents
// pinned their own labels and this suite replaces those with behaviour.
//
// Sources are comment-stripped first, so a provenance note can never satisfy a
// check (and never breaks one) — except for the manifest, which is JSON and is
// read as data.
//
// The one place the merge itself breaks a rule the plan states literally: the
// manifest `description` the plan specifies contains the three merged ids as
// prose. Item 3 therefore allows them there, and nowhere else.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs"
import { execFileSync } from "node:child_process"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const PLUGIN = join(dirname(fileURLToPath(import.meta.url)), "..")
const read = (rel) => readFileSync(join(PLUGIN, rel), "utf8")

// Remove /* */ and // comments without touching string literals (file://,
// https://, "\\u000b") or the few regex literals in the sources.
function stripComments(src) {
  let out = ""
  let quote = ""
  for (let i = 0; i < src.length; i++) {
    const c = src[i]
    if (quote) {
      out += c
      if (c === "\\") { out += src[++i] ?? ""; continue }
      if (c === quote) quote = ""
      continue
    }
    if (c === '"' || c === "'") { quote = c; out += c; continue }
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; out += "\n"; continue }
    if (c === "/" && src[i + 1] === "*") { i += 2; while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++; i++; continue }
    out += c
  }
  return out
}

const MANIFEST = JSON.parse(read("manifest.json"))
const QML = readdirSync(PLUGIN).filter((f) => f.endsWith(".qml")).sort()
const qml = Object.fromEntries(QML.map((f) => [f, stripComments(read(f))]))
const allQml = QML.map((f) => qml[f]).join("\n")
const codeFiles = [...QML]
  .concat(readdirSync(PLUGIN).filter((f) => f.endsWith(".js")))
  .concat(["bin/spend-status", "bin/spend-status-enrich.py", "bin/fleet-snapshot", "bin/fleet-focus",
    "bin/agents-update", "bin/omarchy-agent-usage-omp", "bin/codex",
    "bin/openrouter-credits", "bin/openrouter-save-key",
    "tests/agents/omp-collector.test.sh"])
  .concat(readdirSync(join(PLUGIN, "tests/fleet")).filter((f) => /\.(mjs|py)$/.test(f)).map((f) => `tests/fleet/${f}`))
  .concat(readdirSync(join(PLUGIN, "tests/deepseek")).filter((f) => f.endsWith(".js")).map((f) => `tests/deepseek/${f}`))
  .concat(readdirSync(join(PLUGIN, "tests/openrouter")).filter((f) => /\.(m?js)$/.test(f)).map((f) => `tests/openrouter/${f}`))

test("1 · one bar widget, one entry point, one IPC handler", () => {
  assert.equal(MANIFEST.id, "t1nk33r.agents")
  assert.deepEqual(MANIFEST.kinds, ["bar-widget"])
  assert.deepEqual(MANIFEST.entryPoints, { barWidget: "Panel.qml" })
  assert.ok(!existsSync(join(PLUGIN, "BarWidget.qml")), "no BarWidget.qml wrapper in the merged plugin")
  assert.match(qml["Panel.qml"], /moduleName:\s*"t1nk33r\.agents"/)
  assert.match(qml["Panel.qml"], /ipcTarget:\s*"t1nk33r\.agents"/)
  assert.match(qml["Panel.qml"], /manageIpc:\s*false/)
  assert.equal((allQml.match(/IpcHandler\s*\{/g) || []).length, 1, "exactly one IpcHandler")
  // The three merged ids must have no IPC target left anywhere.
  for (const old of ["t1nk33r.deepseek", "t1nk33r.codeburn", "t1nk33r.fleet-shepherd"])
    assert.ok(!allQml.includes(`ipcTarget: "${old}"`), `no ipcTarget for ${old}`)
})

test("2 · every IPC method the panel promises exists", () => {
  const p = qml["Panel.qml"]
  for (const method of ["open", "close", "show", "hide", "toggle", "refresh", "next", "tab", "setPeriod"])
    assert.match(p, new RegExp(`function ${method}\\(`), `IpcHandler.${method}`)
  assert.match(p, /function tab\(name: string\): string \{[\s\S]{0,120}return "unknown tab"/)
})

test("3 · no merged id survives as an identifier", () => {
  const forbidden = ["t1nk33r.deepseek", "t1nk33r.codeburn", "t1nk33r.fleet-shepherd",
    "io.github.joshuaswarren", "io.github.shirak-semonian", "io.github.caffeinatedtech"]
  for (const file of codeFiles) {
    const src = file.endsWith(".qml") ? qml[file] : stripComments(read(file))
    for (const id of forbidden)
      assert.ok(!src.includes(id), `${file} still names ${id}`)
  }
  // `omarchy.agents` is the one allowed occurrence, and only as clonedFrom.
  for (const file of codeFiles) {
    const src = file.endsWith(".qml") ? qml[file] : stripComments(read(file))
    assert.ok(!src.includes("omarchy.agents"), `${file} names omarchy.agents outside the manifest`)
  }
  assert.equal(MANIFEST.omarchy.clonedFrom, "omarchy.agents")
  // The description is prose, and the only place the merged ids may appear.
  const manifestText = read("manifest.json")
  const prose = MANIFEST.description
  for (const id of ["t1nk33r.deepseek", "t1nk33r.codeburn", "t1nk33r.fleet-shepherd"])
    assert.ok(prose.includes(id), `description records the merge of ${id}`)
  assert.ok(manifestText.split(prose).length === 2, "the ids appear in the description only")
})

test("4 · the panel is the kit's KeyboardPanel, not a hand-rolled window", () => {
  const p = qml["Panel.qml"]
  assert.match(p, /KeyboardPanel\s*\{/)
  assert.match(p, /anchorItem:\s*button/)
  assert.match(p, /open:\s*root\.opened/)
  assert.match(p, /focusTarget:\s*keyCatcher/)
  assert.match(p, /contentWidth:\s*panel\.fittedContentWidth\(/)
  assert.match(p, /contentHeight:\s*panel\.fittedContentHeight\(/)
  assert.ok(!/PanelWindow\s*\{/.test(allQml), "no hand-rolled PanelWindow")
  assert.ok(!/WlrKeyboardFocus\.Exclusive/.test(allQml), "no exclusive keyboard grab")
  assert.ok(!/Quickshell\.Wayland/.test(allQml), "no Wayland import in a plugin")
  assert.ok(!/implicitHeight:\s*\d{3}/.test(allQml), "no fixed pixel heights")
})

test("5 · theming comes from the theme, never from a literal", () => {
  for (const file of QML) {
    const src = qml[file]
    const sizes = src.match(/font\.pixelSize:\s*[^\n]+/g) || []
    for (const line of sizes)
      assert.match(line, /font\.pixelSize:\s*Style\.(font|bar)\./, `${file}: ${line}`)
    assert.ok(!/font\.family:\s*"/.test(src), `${file} hardcodes a font family`)
    assert.ok(!/"#[0-9a-fA-F]{3,8}"/.test(src), `${file} hardcodes a colour`)
    assert.ok(!/property var data\b/.test(src), `${file} shadows Item's default property`)
  }
})

test("6 · every private-use glyph is painted by OpticalGlyph or an icon button", () => {
  const pua = /[\u{E000}-\u{F8FF}\u{F0000}-\u{FFFFD}]/u
  const escaped = /\\u([0-9a-fA-F]{4})/g
  for (const file of QML) {
    const lines = read(file).split("\n")
    lines.forEach((line, i) => {
      const literal = pua.test(line)
      let escape = false
      for (const m of line.matchAll(escaped)) {
        const cp = parseInt(m[1], 16)
        if (cp >= 0xe000 && cp <= 0xf8ff) escape = true
      }
      if (!literal && !escape) return
      if (/^\s*(\/\/|\*)/.test(line)) return
      const previous = i > 0 ? lines[i - 1].trim() : ""
      const ok = line.includes("iconText:") || previous.endsWith("OpticalGlyph {")
      assert.ok(ok, `${file}:${i + 1} paints a glyph outside OpticalGlyph/iconText: ${line.trim()}`)
    })
  }
})

test("7 · keys: j/k the rail, Ctrl+j/Ctrl+k the pane, 1-5 and [ ] the tabs", () => {
  const p = qml["Panel.qml"]
  assert.match(p, /"1"[\s\S]{0,40}setTab\("limits"\)/)
  assert.match(p, /"2"[\s\S]{0,40}setTab\("spend"\)/)
  assert.match(p, /"3"[\s\S]{0,40}setTab\("fleet"\)/)
  assert.match(p, /"4"[\s\S]{0,40}setTab\("deepseek"\)/)
  assert.match(p, /text === "\["[\s\S]{0,40}cycleTab\(-1\)/)
  assert.match(p, /text === "\]"[\s\S]{0,40}cycleTab\(1\)/)
  // Vertical motion is the rail, horizontal motion is the pane.
  assert.match(p, /onMoveRequested:[\s\S]{0,220}dy !== 0\) root\.active\.moveRail\(dy\)[\s\S]{0,120}dx !== 0\) root\.active\.movePane\(dx\)/)
  // The owner's pair for the pane, plus the PgUp/PgDn shortcuts.
  assert.match(p, /text === "\\n"\) root\.active\.movePane\(1\)/)
  assert.match(p, /text === "\\u000b"\) root\.active\.movePane\(-1\)/)
  assert.match(p, /sequence: "PgDown"/)
  assert.match(p, /sequence: "PgUp"/)
  assert.match(p, /blocked:\s*fleetTab\.filterHasFocus/)
  assert.match(p, /onTabRequested:[\s\S]{0,80}switchPanel\(direction\)/)
  const close = p.slice(p.indexOf("onCloseRequested:"), p.indexOf("onCloseRequested:") + 260)
  assert.ok(close.indexOf("fleetTab.clearFilter()") > -1 && close.indexOf("root.close()") > close.indexOf("fleetTab.clearFilter()"),
    "Esc clears the fleet filter before it closes")
  // x/X is claimed by PanelKeyCatcher as deleteRequested before its printable
  // branch, so it never arrives as a textKey; the Fleet tab still has to start
  // its filter with it, because the README promises any printable does.
  assert.match(p, /onDeleteRequested: if \(root\.tab === "fleet"\) fleetTab\.beginFilter\("x"\)/)
})

test("8 · every tab is rail + pane and scrolls only the pane", () => {
  for (const file of ["LimitsTab.qml", "SpendTab.qml", "FleetTab.qml", "DeepSeekTab.qml"]) {
    const src = qml[file]
    assert.match(src, /readonly property int railWidth: Style\.space\(/, `${file} has no rail`)
    assert.match(src, /Row \{/, `${file} is not a two-column layout`)
    assert.match(src, /function moveRail\(delta\)/, `${file} has no rail movement`)
    assert.match(src, /function movePane\(delta\)/, `${file} has no pane movement`)
    assert.match(src, /implicitContentHeight/, `${file} does not size the tab host`)
    assert.match(src, /readonly property string heroTitle/)
    assert.match(src, /readonly property Component heroIcon/)
    assert.match(src, /function refresh\(\)/)
    assert.match(src, /function activate\(\)/)
    const scrolls = /Flickable \{/.test(src) || /ListView \{/.test(src)
    assert.ok(scrolls, `${file} has nothing that scrolls`)
    // A ListView inside a Flickable is the combination the fleet panel's
    // contract suite forbids: two scroll owners fight for the same gesture.
    assert.ok(!(/Flickable \{/.test(src) && /ListView \{/.test(src)),
      `${file} nests a ListView inside a Flickable`)
  }
  assert.match(qml["LimitsTab.qml"], /RailList \{/)
  assert.match(qml["SpendTab.qml"], /RailList \{/)
  assert.match(qml["FleetTab.qml"], /RailList \{/)
  // The rail paints the provider the pane is reading. Binding the raw
  // selectedProviderId painted *nothing* as selected while the pane showed
  // providers[0] — the id only becomes non-empty once the user drives the
  // rail, and providerIndex resolves the empty id to 0 — so the one provider
  // on screen looked unselected.
  assert.match(qml["LimitsTab.qml"],
    /value: root\.providers\.length > 0 \? root\.providers\[root\.providerIndex\]\.providerId : ""/)
})

test("9 · fleet keeps its helper contract", () => {
  const f = qml["FleetService.qml"]
  assert.match(f, /\["python3", root\.helper, "--cache-ttl", String\(root\.cacheTtl\)\]/)
  assert.match(f, /argv\.push\("--stale-ok"\)/)
  assert.match(f, /argv\.push\("--refresh"\)/)
  assert.match(f, /raw\.length > 4194304/)
  assert.ok(!/FileView\s*\{/.test(f), "the fleet snapshot never reads a file directly")
  assert.ok(!/bash",\s*"-c/.test(f), "no shell string")
  assert.ok(!/\["ssh"/.test(f), "QML never starts ssh itself")
  // A successful raise focuses the connector's terminal, and this panel — a
  // KeyboardPanel, i.e. an Overlay layer surface — is painted above it, so
  // the raise is invisible until the panel gets out of the way. The service
  // is the only half that knows the focus helper exited 0.
  assert.match(f, /signal connectorRaised\(\)/)
  assert.match(qml["Panel.qml"], /onConnectorRaised:\s*root\.close\(\)/)

  const t = qml["FleetTab.qml"]
  assert.match(t, /ListView\s*\{/)
  assert.match(t, /model: root\.visibleConnectors/)
  assert.match(t, /currentIndex: root\.cursorIndex/)
  assert.match(t, /positionViewAtIndex\(currentIndex, ListView\.Contain\)/)
  assert.match(t, /delegate: CursorSurface\s*\{/)
  assert.ok(!/color:.*containsMouse/.test(t), "rows paint from hasCursor, not the mouse")

  const helper = read("bin/fleet-snapshot")
  assert.ok(helper.includes('CACHE_DIRNAME = "t1nk33r.agents"'))
  assert.ok(helper.includes("shell=False"))
  assert.ok(helper.includes("BatchMode=yes"))
  assert.ok(helper.includes("StrictHostKeyChecking=yes"))
  for (const bad of ["StrictHostKeyChecking=no", "accept-new", "UserKnownHostsFile=/dev/null", "shell=True"])
    assert.ok(!helper.includes(bad), `fleet-snapshot must not use ${bad}`)
})

test("10 · DeepSeek keeps its key file, its ledger and its new state path", () => {
  const s = qml["DeepSeekService.qml"]
  assert.ok(s.includes('base + "/deepspend/config.json"'), "the key file stays where it is")
  assert.ok(s.includes("/haseen/agents/deepseek/usage.state"))
  assert.ok(s.includes("/haseen/agents/deepseek/alerts.state"))
  assert.ok(s.includes("/haseen/agents/deepseek/alerts.gate"))
  assert.ok(!s.includes("/t1nk33r.deepseek/"), "no old state path")
  assert.ok(!s.includes("/deepspend/alerts"), "alerts never live beside the key")
  assert.ok(s.includes("recordUsage(result.balance)"))
  assert.ok(s.includes("usageRecord(root.usage"))
  assert.ok(s.includes("usageToText(root.usage)"))
  assert.match(s, /whaleSource: root\.peak/)
  assert.ok(existsSync(join(PLUGIN, "assets/deepseek-peak.svg")))
  assert.ok(existsSync(join(PLUGIN, "assets/deepseek-offpeak.svg")))

  const t = qml["DeepSeekTab.qml"]
  assert.ok(t.includes('label: "Daily usage"'))
  assert.ok(t.includes('label: "Total usage"'))
  assert.ok(t.includes("platform.deepseek.com/usage"))

  const exports = execFileSync("node", ["-e",
    `const P=require(${JSON.stringify(join(PLUGIN, "Pricing.js"))});` +
    `const ok=["isPeakAt","nextChange","formatLocal"].every(n=>typeof P[n]==="function");` +
    `process.stdout.write(ok?"ok":"missing")`], { encoding: "utf8" })
  assert.equal(exports, "ok", "omp-peak-guard still requires Pricing.js by path")
})

test("11 · the OpenRouter settings the manifest declares are the ones the code reads", () => {
  const s = qml["OpenRouterService.qml"]
  // No setting may make the plugin run a command to fetch a key.
  assert.ok(!JSON.stringify(MANIFEST).includes("keyCommand"))
  for (const key of ["openrouterRefreshIntervalSec", "openrouterLowBalance"]) {
    assert.ok(key in MANIFEST.barWidget.defaults, `${key} has a default`)
    assert.ok(MANIFEST.barWidget.schema.some((e) => e.key === key), `${key} is in the schema`)
    assert.ok(s.includes(`"${key}"`), `OpenRouterService reads ${key}`)
  }
  const options = (key) => MANIFEST.barWidget.schema.find((e) => e.key === key).options
  assert.ok(options("barBadge").includes("openrouter"))
  assert.ok(options("defaultTab").includes("openrouter"))
})

test("12 · the bar mark is one slot with a badge setting and a tooltip", () => {
  const p = qml["Panel.qml"]
  assert.match(p, /WidgetButton\s*\{/)
  assert.match(p, /OpticalGlyph\s*\{\n\s*text: "󱚣"/)
  assert.match(p, /active:\s*root\.alarming/)
  assert.match(p, /tooltipText:\s*root\.barTooltip/)
  assert.ok(!/dimmed\s*:/.test(p), "the mark never dims")
  assert.match(p, /visible:\s*!button\.vertical && root\.badgeText !== ""/)
  assert.match(p, /setting\("barBadge"/)
  assert.match(p, /setting\("defaultTab"/)
  // (No count of tooltip lines: that pinned an incidental source detail.)
  assert.match(p, /Timer \{[\s\S]{0,120}running: root\.opened/)
})

test("12a · a file that names a theme singleton imports it", () => {
  // Color/Style/Border/Util come from qs.Commons, and a file that names one
  // without importing it fails at runtime as a ReferenceError — the binding
  // quietly becomes undefined, which is invisible in a QML error that only
  // reaches the shell's log file. Both halves of this plugin's split (a tab and
  // its service) name them, so the import belongs on both.
  for (const file of QML) {
    const src = read(file)
    const uses = /\b(Color|Style|Border|Util)\./.test(src)
    if (!uses) continue
    assert.ok(/^import qs\.Commons$/m.test(src), `${file} names a qs.Commons singleton without importing it`)
  }
})

test("12b · every local import resolves", () => {
  // qmllint reports a missing script import as a Warning, so an Error-only
  // gate misses it — and a script that fails to load takes the whole panel
  // component with it (the bar slot goes empty and the IPC target never
  // appears). Found that way once; this is the assertion that would have.
  for (const file of QML) {
    for (const m of read(file).matchAll(/^import\s+"([^"]+)"/gm)) {
      assert.ok(existsSync(join(PLUGIN, m[1])), `${file} imports a missing ${m[1]}`)
    }
  }
})

test("13 · the merged plugin ships every file the layout promises", () => {
  const files = ["manifest.json", "Panel.qml", "UsageService.qml", "Agent.qml", "LimitsTab.qml",
    "SpendService.qml", "SpendTab.qml", "FleetService.qml", "FleetTab.qml", "FleetModel.js",
    "DeepSeekService.qml", "DeepSeekTab.qml", "DeepSeekModel.js", "Pricing.js", "RailList.qml",
    "bin/agents-update", "bin/omarchy-agent-usage-omp", "bin/codex", "bin/spend-status",
    "bin/spend-status-enrich.py", "bin/fleet-snapshot", "bin/fleet-focus",
    "assets/claude.svg", "assets/codex.svg", "assets/codex-light.svg", "assets/fireworks.svg",
    "assets/omp.svg", "assets/omp-light.svg", "assets/deepseek-peak.svg", "assets/deepseek-offpeak.svg",
    "connectors.example.json", "docs/fleet/DESIGN.md", "docs/fleet/REQUIREMENTS.md",
    "tests/run.sh", "tests/panel-contract.test.mjs", "tests/agents/omp-collector.test.sh",
    "tests/fleet/model.test.mjs", "tests/fleet/test_snapshot.py", "tests/fleet/test_streams.py",
    "tests/fleet/fixtures/connectors_ok.json", "tests/deepseek/model.test.js",
    "tests/deepseek/pricing.test.js", "tests/deepseek/usage.test.js",
    "OpenRouterService.qml", "OpenRouterTab.qml", "OpenRouterModel.js",
    "bin/openrouter-credits", "bin/openrouter-save-key", "tests/openrouter/model.test.js",
    "tests/openrouter/credits.test.mjs", "tests/openrouter/save-key.test.mjs",
    "README.md", "UPSTREAM.md", "LICENSE", ".gitignore"]
  for (const file of files)
    assert.ok(existsSync(join(PLUGIN, file)), `missing ${file}`)
  assert.ok(statSync(join(PLUGIN, "tests/run.sh")).mode & 0o111, "tests/run.sh is executable")
  for (const helper of ["bin/spend-status", "bin/spend-status-enrich.py", "bin/fleet-snapshot",
    "bin/openrouter-credits", "bin/openrouter-save-key"])
    assert.ok(statSync(join(PLUGIN, helper)).mode & 0o111, `${helper} is executable`)
})
