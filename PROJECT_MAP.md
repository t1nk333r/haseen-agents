# Agents plugin

## [TECH_STACK]

Quickshell QML, JavaScript models, Bash collectors and Python fleet helpers.
`bash tests/run.sh` runs the fixture and offscreen QML checks.

## [SYSTEM_FLOW]

`Panel.qml` owns the services and passes their views to the tab components.
`OpenRouterService.qml` calls `bin/openrouter-credits` and owns refresh state.
The OpenRouter tab and Limits rail read the same view.

## [ARCHITECTURE]

`OpenRouterModel.js` determines amounts, account versus key scope, age,
low balance and failure state. The Limits row adds no polling or key access.
Runtime files live under the haseen config, state and cache directories.
`bin/agents-migrate` copies older owned runtime files without removing them.

## [ORPHANS & PENDING]

No code is deprecated by the balance row. A rejected key must be replaced
through the OpenRouter tab before a live balance can be returned.
The publication and its source dependencies are recorded in
`plans/001-openrouter-limits-balance.md`.
