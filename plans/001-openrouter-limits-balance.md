# OpenRouter balance in the Limits rail

## Status

DONE 2026-10-12. The source is prepared on top of GitHub baseline `dfe6166`.
`bash tests/run.sh`, shell syntax checks, shellcheck and redacted gitleaks
scans pass.

## Problem and outcome

The Limits rail received the DeepSeek service, but did not receive OpenRouter.
The panel now passes its existing OpenRouter service to Limits
(`Panel.qml:463`). The rail shows its amount, labels a key cap, keeps stale
figures marked stale, and shows offline when a failed check has no balance
(`LimitsTab.qml:129`). A refresh uses the existing service, so the rail adds
no timer, credential reader or helper process.

The balance belongs beside the other provider balance in the on-demand
Limits panel. No new bar element or default plugin is introduced.

## Source dependencies

The published repository predates the merged panel. Its required source is
imported from plugin commit `08dc960`. OpenRouter and the Spend files required
by the existing test runner come from source commit `0cc20c7`. Only plugin
source files are imported from Git objects, with OpenRouter paths adapted to
the existing haseen directory contract. No live settings, key files, ledgers,
backups or private repository history are included.

MIT attribution is retained in `LICENSE` and the component headers. The
OpenRouter provenance is recorded in `UPSTREAM.md`.

## Verification

- `node --test tests/limits-balances.test.mjs`: reproduced the missing row
  before the change; passes with the shared service, painted text, zero and
  negative balances, stale data, key-cap scope, unavailable figures and refresh.
- `bash tests/run.sh`: passes the merged plugin's collector, migration,
  model, fixture-server and QML checks.
- `shellcheck -x --severity=warning` and `bash -n`: pass for shell sources.
- `gitleaks git --redact` and `gitleaks dir --redact`: no leaks. One synthetic
  masked label in a model fixture is annotated with `gitleaks:allow`.
- Privacy checks: fixture home paths use `/test-home/`, not a real home path.

## Rejected options

- Publishing the installed working tree wholesale would include unrelated
  changes and backup files. The publication uses selected source history.
- Fetching a second balance in the rail would duplicate the service's network
  request and state. Both tabs share the existing view.
- Showing zero for an unavailable balance would misrepresent the account.
  Missing data remains absent or is labelled offline after a failure.

## Operational limit

An API key rejected by OpenRouter must be replaced through the existing
OpenRouter tab. A display change cannot make a rejected credential valid.
