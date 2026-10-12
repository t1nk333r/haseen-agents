import { readFileSync } from "node:fs"
import vm from "node:vm"
import test from "node:test"
import assert from "node:assert/strict"

// Exercise the service's actual JavaScript methods, without a compositor.
const qml = readFileSync(new URL("../../UsageService.qml", import.meta.url), "utf8")
const usedMethods = ["safeDeviceId", "cloneValue", "numberValue", "dateString",
  "recentDateStrings", "emptyTokenBucket", "combineNumber", "combineObjectNumbers",
  "aggregateSnapshots", "providerSnapshot", "syncedStatsFor"]
const methods = usedMethods.map((name) => {
  const match = qml.match(new RegExp(`^  function ${name}\\([^\\n]*\\) \\{[\\s\\S]*?^  \\}`, "m"))
  if (!match) throw new Error(`UsageService method not found: ${name}`)
  return match[0]
}).join("\n")
function service() {
  const context = vm.createContext({ syncRevision: 0, aggregateData: null })
  vm.runInContext(methods, context)
  // The tests explicitly enable sync; all aggregation/export methods are real.
  context.syncConfigured = () => true
  return context
}
function record(tokens, source) {
  return {
    id: "claude", name: source ? "Claude (OMP)" : "Claude Code",
    statsSource: source, ready: true, hasLocalStats: true,
    todayTotalTokens: tokens, totalPrompts: tokens / 10,
    totalSessions: 1, activeDays: 1,
    todayTokensByModel: { "claude-opus-5-5": tokens },
    modelUsage: { "claude-opus-5-5": { inputTokens: tokens, outputTokens: 2 } }
  }
}

test("Claude sync combines native OMP devices without admitting Claude Code history", () => {
  const ctx = service()
  const inputs = [
    { deviceId: "native-a", providers: { claude: ctx.providerSnapshot(record(20, "omp:anthropic")) } },
    { deviceId: "legacy", providers: {
      claude: ctx.providerSnapshot(record(900, undefined)),
      codex: { todayTotalTokens: 7, totalSessions: 1 }
    } },
    { deviceId: "native-b", providers: { claude: ctx.providerSnapshot(record(30, "omp:anthropic")) } }
  ]
  const result = ctx.aggregateSnapshots(inputs)
  assert.equal(result.providers.claude.todayTotalTokens, 50)
  assert.equal(result.providers.claude.totalPrompts, 5)
  assert.equal(result.providers.claude.todayTokensByModel["claude-opus-5-5"], 50)
  assert.equal(result.providers.claude.modelUsage["claude-opus-5-5"].inputTokens, 50)
  assert.equal(result.providers.claude.deviceCount, 2)
  assert.equal(result.providers.codex.todayTotalTokens, 7)
  ctx.aggregateData = result
  assert.equal(ctx.syncedStatsFor("claude").todayTotalTokens, 50)
})

test("a previously saved unmarked Claude aggregate cannot override local native history", () => {
  const ctx = service()
  ctx.aggregateData = { providers: { claude: { todayTotalTokens: 900 }, codex: { todayTotalTokens: 7 } } }
  assert.equal(ctx.syncedStatsFor("claude"), null)
  assert.equal(ctx.syncedStatsFor("codex").todayTotalTokens, 7)
  ctx.aggregateData = ctx.aggregateSnapshots([
    { deviceId: "legacy", providers: { claude: ctx.providerSnapshot(record(900, undefined)) } }
  ])
  assert.equal(ctx.syncedStatsFor("claude"), null)
})
