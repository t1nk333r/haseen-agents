import { test } from "node:test"
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, symlinkSync, rmSync } from "node:fs"
import { dirname, join } from "node:path"
import { tmpdir } from "node:os"
import { fileURLToPath } from "node:url"

const plugin = join(dirname(fileURLToPath(import.meta.url)), "..")

test("Limits receives the existing OpenRouter service", () => {
  const panel = readFileSync(join(plugin, "Panel.qml"), "utf8")
  const limits = panel.slice(panel.indexOf("LimitsTab {"), panel.indexOf("SpendTab {"))
  assert.match(limits, /openrouter:\s*openrouter/, "Limits must share the panel's OpenRouter view")
})

test("Limits paints known OpenRouter balances and refreshes the shared service", () => {
  const scratch = mkdtempSync(join(tmpdir(), "agents-limits-"))
  try {
    symlinkSync(plugin, join(scratch, "Plugin"))
    for (const module of ["Commons", "Ui"])
      symlinkSync(`/usr/share/omarchy/shell/${module}`, join(scratch, module))
    for (const dir of ["home", "config", "state", "cache", "run"])
      mkdirSync(join(scratch, dir), { mode: 0o700 })
    writeFileSync(join(scratch, "shell.qml"), `
import QtQuick
import Quickshell
import "Plugin" as Plugin
ShellRoot {
  QtObject {
    id: router
    property var view: ({status: "live", data: {source: "account", remaining: 12.5, fetchedAt: 1000}})
    property int refreshCount: 0
    property real lowBalance: 5
    function refreshNow() { refreshCount++ }
  }
  Plugin.LimitsTab { id: tab; width: 1000; height: 560; nowMs: 1000000 }
  function check(condition, message) {
    if (!condition) throw new Error(message)
  }
  function glance(item) {
    if (item.objectName === "openrouterGlance") return item
    for (var i = 0; i < item.children.length; i++) {
      var found = glance(item.children[i])
      if (found) return found
    }
    return null
  }
  // haseen:ui-timeout
  Timer { interval: 1; running: true; onTriggered: {
    try {
      if ("openrouter" in tab) tab.openrouter = router
      check(typeof tab.openrouterLine === "string" && tab.openrouterLine.indexOf("$12.50") >= 0,
        "Limits is missing the OpenRouter balance despite a valid shared service view")
      var row = glance(tab)
      check(row !== null && row.visible, "OpenRouter balance row must be visible")
      check(row.children[0].text === tab.openrouterLine, "Paint the shared balance in the row")
      check(tab.openrouterLine.indexOf("OpenRouter") >= 0, "Name the provider")
      check(tab.openrouterLine.indexOf("just now") >= 0, "Show the last read age")
      router.view = {status: "live", data: {source: "account", remaining: 0, fetchedAt: 1000}}
      check(tab.openrouterLine.indexOf("$0.00") >= 0 && row.visible, "Zero is a balance")
      check(tab.openrouterWarn, "Zero is a low balance")
      router.view = {status: "stale", data: {source: "account", remaining: -2.5, fetchedAt: 1000}}
      check(tab.openrouterLine.indexOf("-$2.50") >= 0 && row.visible, "Keep an overdrawn balance")
      check(tab.openrouterLine.indexOf("stale") >= 0 && tab.openrouterWarn, "Mark retained figures stale")
      router.view = {status: "live", data: {source: "key", remaining: 7, fetchedAt: 1000}}
      check(tab.openrouterLine.indexOf("key cap") >= 0, "A key cap must not claim account credit")
      router.view = {status: "live", data: {source: "usage", remaining: null, fetchedAt: 1000}}
      check(tab.openrouterLine === "" && !row.visible, "Spend without a balance must not draw a credit")
      for (var status of ["loading", "nokey"]) {
        router.view = {status: status, data: null}
        check(tab.openrouterLine === "" && !row.visible, "Hide a missing balance: " + status)
      }
      router.view = {status: "offline", data: null, error: "OpenRouter rejected the key"}
      check(row.visible && tab.openrouterLine.indexOf("offline") >= 0 && tab.openrouterWarn,
        "A failed check must explain the missing balance")
      check(tab.openrouterTooltip.indexOf("rejected the key") >= 0, "Expose the failure reason on hover")
      tab.refresh()
      check(router.refreshCount === 1, "Limits refresh must refresh the shared OpenRouter service")
      console.log("LIMITS_BALANCES_OK")
      Qt.quit()
    } catch (e) {
      console.error("LIMITS_BALANCES_FAIL: " + e.message)
      Qt.quit()
    }
  } }
}`)
    const output = execFileSync("/usr/bin/qs", ["-p", scratch], {
      encoding: "utf8", timeout: 15000,
      env: { ...process.env, HOME: join(scratch, "home"), XDG_CONFIG_HOME: join(scratch, "config"),
        XDG_STATE_HOME: join(scratch, "state"), XDG_CACHE_HOME: join(scratch, "cache"),
        XDG_RUNTIME_DIR: join(scratch, "run"), QT_QPA_PLATFORM: "offscreen", QT_QUICK_BACKEND: "software",
        QT_QPA_PLATFORMTHEME: "", QT_NO_XDG_DESKTOP_PORTAL: "1", DBUS_SESSION_BUS_ADDRESS: "unix:path=/nonexistent",
        WAYLAND_DISPLAY: "", DISPLAY: "", HYPRLAND_INSTANCE_SIGNATURE: "" },
      stdio: ["ignore", "pipe", "pipe"]
    })
    assert.match(output, /LIMITS_BALANCES_OK/, output)
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
})
