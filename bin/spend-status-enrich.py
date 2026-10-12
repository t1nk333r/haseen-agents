#!/usr/bin/env python3
"""Enrich CodeBurn's status JSON with per-model token usage, the local currency,
and, when asked, an OMP-free Spend figure.

Reads the JSON `codeburn status --format menubar-json` wrote on stdin and writes
it back with these additions, so the panel can show what each model actually
moved rather than only what it cost, what that spend is worth locally, what this
run had to price itself, and (when asked) OMP's absence:

  modelTokens    per-model rows for the same period -- name, calls, cost and all
                 four token classes -- taken from `codeburn models --format
                 json`. That listing, unlike `report`, names the PROVIDER behind
                 every row, which is what makes the OMP exclusion exact at model
                 level. Rows sharing a display name across providers ("Opus 5"
                 is both claude and omp here) are summed, matching the panel's
                 name-keyed join.

  localCurrency  code, symbol and USD rate for the operator's timezone, so the
                 panel can show a second price column.

  autoPriced     one row per model CodeBurn reported usage for but had no rate
                 for, with the table entry it was priced from. See price_missing().

  ompExcluded    true when OMP's contribution was subtracted, which is what
                 bin/spend-status does unless it was started with --include-omp
                 (the Spend tab passes that by default, an overview of what the
                 usage would have cost at API rates; its spendExcludeOmp setting
                 turns the exclusion back on). When excluding, bin/spend-status
                 reads `codeburn status --provider omp` before the main read and
                 points CODEBURN_OMP_STATUS_FILE at it; exclude_omp() takes
                 cost, calls, sessions, tokens and activities off the payload
                 and rebuilds topModels without OMP. OMP is a subscription
                 harness, so its API-rate cost is a would-be figure, not money
                 out of pocket.

  ompExcludedTotals  with ompExcluded: what was taken off (cost, calls and
                 sessions), so a period with nothing left can say how much.

The rate is only given for currencies with a fixed one. A floating rate written
into this file would be a lie the next morning, so anything else stays USD and
says why; ~/.config/codeburn/local-currency.json ({"code": "EUR", "rate": 0.92})
overrides either way.

Takes the period as argv[1] and the CodeBurn runner in CODEBURN_RUNNER. Never
fails the pipeline: any problem leaves the JSON exactly as it arrived.
"""

import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
PLUGIN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_JS = os.path.join(PLUGIN, "DeepSeekModel.js")
OVERRIDE = os.path.join(HOME, ".config", "codeburn", "local-currency.json")
TOKEN_KEYS = ("inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens")
DEBUG = os.environ.get("CODEBURN_ENRICH_DEBUG") == "1"
# Set by bin/spend-status when it re-reads the status after a pricing pass: what
# that pass filled in belongs to the poll that noticed the gap, not to the read
# that follows it.
CARRIED = os.environ.get("CODEBURN_AUTO_PRICED", "")
# Path to the OMP-only status bin/spend-status read before the main one, or "".
OMP_STATUS_FILE = os.environ.get("CODEBURN_OMP_STATUS_FILE", "")

# Currencies whose rate is fixed by law or by a hard peg. Everything else is
# deliberately absent: a floating rate hardcoded here would rot silently.
PEGGED = {
    "Asia/Riyadh": ("SAR", "SAR", 3.75),
    "Asia/Dubai": ("AED", "AED", 3.6725),
    "Asia/Qatar": ("QAR", "QAR", 3.64),
    "Asia/Kuwait": ("KWD", "KWD", 0.306),
    "Asia/Bahrain": ("BHD", "BHD", 0.376),
    "Asia/Muscat": ("OMR", "OMR", 0.3845),
    "Asia/Amman": ("JOD", "JOD", 0.709),
    "Asia/Baghdad": ("IQD", "IQD", 1310.0),
    "Asia/Hong_Kong": ("HKD", "HK$", 7.8),
}


def log(message):
    if DEBUG:
        print("codeburn-enrich: " + message, file=sys.stderr)


def local_currency():
    """(code, symbol, rate, source) for the operator's timezone, or USD."""
    if os.path.exists(OVERRIDE):
        try:
            with open(OVERRIDE) as handle:
                data = json.load(handle)
            if data.get("rate"):
                return (
                    str(data.get("code", "USD")),
                    str(data.get("symbol", data.get("code", "$"))),
                    float(data["rate"]),
                    "override",
                )
        except (ValueError, OSError) as exc:
            log("override unreadable: %s" % exc)

    timezone = ""
    try:
        timezone = subprocess.run(
            ["timedatectl", "show", "-p", "Timezone", "--value"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError) as exc:
        log("timedatectl failed: %s" % exc)
    if timezone in PEGGED:
        code, symbol, rate = PEGGED[timezone]
        return code, symbol, rate, "fixed rate for " + timezone
    return "USD", "$", 1.0, "no fixed rate for " + (timezone or "unknown timezone")


def model_rows(runner, period):
    """CodeBurn's per-provider model rows for the period, or [] on failure.

    `codeburn models --format json` is the listing that carries the provider
    behind each row -- the report does not -- so it is what lets the OMP
    exclusion filter model rows instead of guessing at names.
    """
    try:
        result = subprocess.run(
            runner + ["models", "--period", period, "--format", "json"],
            capture_output=True, text=True, timeout=300,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log("models failed: %s" % exc)
        return []
    if result.returncode != 0:
        log("models exited %s: %s" % (result.returncode, result.stderr.strip()[:200]))
        return []
    try:
        rows = json.loads(result.stdout)
    except ValueError as exc:
        log("models JSON unreadable: %s" % exc)
        return []
    return rows if isinstance(rows, list) else []


def merge_model_rows(rows):
    """Display-name rows for the panel: costs, calls and tokens summed.

    Two providers can carry the same display name -- "Opus 5" is this host's
    claude and omp both -- and the panel joins its rows by name, so they have
    to become one row before it sees them.
    """
    merged = {}
    order = []
    for row in rows:
        row = row or {}
        name = str(row.get("modelDisplayName") or row.get("model") or "").strip()
        if not name:
            continue
        entry = merged.get(name)
        if entry is None:
            entry = {"name": name, "cost": 0.0, "calls": 0}
            for key in TOKEN_KEYS:
                entry[key] = 0
            merged[name] = entry
            order.append(name)
        entry["cost"] += float(row.get("costUSD") or 0)
        entry["calls"] += int(row.get("calls") or 0)
        for key in TOKEN_KEYS:
            entry[key] += int(row.get(key) or 0)
    out = []
    for name in order:
        entry = merged[name]
        entry["totalTokens"] = sum(entry[key] for key in TOKEN_KEYS)
        out.append(entry)
    out.sort(key=lambda row: -row["cost"])
    return out


# ---------------------------------------------------------------- OMP exclusion
#
# The Spend tab does not use OMP's data: oh-my-pi runs Claude and Codex
# subscriptions, so its API-rate cost ($11.3k of a $13.4k month here) is a
# would-be figure, not money out of pocket, and it hid everything else. CodeBurn
# cannot filter a provider out of the status payload -- and 0.9.24 forbids
# --provider together with --scope combined -- so bin/spend-status reads
# `codeburn status --provider omp` FIRST (monotone within a period, so the OMP
# figures can never be larger than the main read's) and the functions here take
# it back off. The wrapper skips that read when ~/.omp/agent/sessions does not
# exist; nothing to exclude.
def load_omp_status():
    """The `current` block of the OMP-only status, or None."""
    if not OMP_STATUS_FILE:
        return None
    try:
        with open(OMP_STATUS_FILE) as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        log("omp status unreadable: %s" % exc)
        return None
    current = data.get("current") if isinstance(data, dict) else None
    return current if isinstance(current, dict) else None


def omp_detail(current):
    for detail in current.get("providerDetails") or []:
        if isinstance(detail, dict) and detail.get("id") == "omp":
            return detail
    return None


def subtract_number(block, key, amount):
    """block[key] = max(0, block[key] - amount); a non-number is left alone."""
    try:
        before = float(block.get(key) or 0)
    except (TypeError, ValueError):
        return
    try:
        left = max(0.0, before - float(amount or 0))
    except (TypeError, ValueError):
        block[key] = before
        return
    # CodeBurn emits whole counters as integers; keep them that way so the
    # payload stays the shape every consumer already parses.
    block[key] = int(left) if left.is_integer() else left


def as_number(value):
    """value as a float; 0.0 for None or anything that is not a number."""
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def subtract_models(current, omp):
    """The status model list minus OMP's, by display name (fallback path).

    Used only when `codeburn models` cannot be read: it is the same name-wise
    arithmetic as the activities, so an OMP-only model drops out and a shared
    name keeps the other provider's share.
    """
    counter = {str(row.get("name")): row for row in (omp.get("topModels") or [])
               if isinstance(row, dict) and row.get("name")}
    out = []
    for row in current.get("topModels") or []:
        if not isinstance(row, dict):
            continue
        hit = counter.get(str(row.get("name")))
        if hit:
            subtract_number(row, "cost", hit.get("cost"))
            subtract_number(row, "calls", hit.get("calls"))
        if float(row.get("cost") or 0) > 0 or float(row.get("calls") or 0) > 0:
            out.append(row)
    out.sort(key=lambda row: -float(row.get("cost") or 0))
    current["topModels"] = out


def exclude_omp(status, omp):
    """Take OMP's contribution off `status`; False when it had none.

    Totals come from the main payload's own providerDetails entry where one
    exists (same read, so exact); cache tokens and activities come from the
    OMP-only read, the only places they are attributable, and every subtraction
    is clamped at zero -- the pre-read-first ordering is what keeps the clamp
    from ever biting.
    """
    current = status.get("current") or {}
    detail = omp_detail(current)
    used = float(omp.get("cost") or 0) > 0 or int(omp.get("calls") or 0) > 0
    if detail is None and not used:
        return False
    if detail is not None and not detail.get("hasUsage") and not used:
        return False

    totals = detail if detail is not None else omp
    # What is about to come off, kept so a pane with nothing left can say how
    # much the exclusion removed. Recorded only once every step has succeeded.
    taken = {
        "cost": as_number(totals.get("cost")),
        "calls": int(as_number(totals.get("calls"))),
        "sessions": int(as_number(totals.get("sessions"))),
    }
    for key in ("cost", "calls", "sessions", "inputTokens", "outputTokens"):
        subtract_number(current, key, totals.get(key))
    for key in ("cacheReadTokens", "cacheWriteTokens"):
        subtract_number(current, key, omp.get(key))
    # CodeBurn's own cache-hit ratio, recomputed from the figures left standing.
    # With none left (a period of nothing but OMP) the ratio CodeBurn reported was
    # OMP's own, so it is zeroed rather than left standing beside empty totals.
    cache_read = float(current.get("cacheReadTokens") or 0)
    input_tokens = float(current.get("inputTokens") or 0)
    if cache_read + input_tokens > 0:
        current["cacheHitPercent"] = 100.0 * cache_read / (cache_read + input_tokens)
    else:
        current["cacheHitPercent"] = 0.0

    current["providerDetails"] = [
        row for row in (current.get("providerDetails") or [])
        if not (isinstance(row, dict) and row.get("id") == "omp")
    ]
    providers = current.get("providers")
    if isinstance(providers, dict):
        providers.pop("omp", None)

    counter = {str(row.get("name")): row for row in (omp.get("topActivities") or [])
               if isinstance(row, dict) and row.get("name")}
    activities = []
    for row in current.get("topActivities") or []:
        if not isinstance(row, dict):
            continue
        hit = counter.get(str(row.get("name")))
        if hit:
            subtract_number(row, "cost", hit.get("cost"))
            subtract_number(row, "turns", hit.get("turns"))
        if float(row.get("cost") or 0) > 0 or float(row.get("turns") or 0) > 0:
            activities.append(row)
    activities.sort(key=lambda row: -float(row.get("cost") or 0))
    current["topActivities"] = activities
    # With no call or session left, nothing but OMP existed in this period, so
    # any cache tokens and activity still standing are OMP's own growth between
    # the two reads (the OMP-only read comes first, the main read seconds later,
    # and OMP does not pause in between). Clear them rather than report them as
    # someone else's usage.
    if as_number(current.get("calls")) <= 0 and as_number(current.get("sessions")) <= 0:
        current["cacheReadTokens"] = 0
        current["cacheWriteTokens"] = 0
        current["cacheHitPercent"] = 0.0
        current["topActivities"] = []
    status["ompExcludedTotals"] = taken
    return True


# ---------------------------------------------------------------- auto-pricing
#
# CodeBurn prices the models it knows. A provider model name it has never seen
# arrives with usage and no rate: the period then reads short by whatever that
# model moved, and nothing says so (measured 2026-09-19: a day that cost $13.51
# showed $9.10 while 108.6M tokens of `deepseek-v4.1-flash` sat unpriced).
#
# DeepSeek publishes one rate table and this plugin already carries it for the
# DeepSeek tab's token estimate -- TOKEN_MODELS in DeepSeekModel.js, taken from
# api-docs.deepseek.com/pricing. An unpriced model is therefore matched to that
# table by *family and tier* (`deepseek-v4.1-flash` is the flash tier of the
# deepseek family, which is `deepseek-flash` there) and priced with its rates as
# a local price-override, so the next read prices it. The table is read out of
# the module rather than copied here, so the two cannot drift apart.
#
# Deliberately not done:
#   * no rate is invented for a model the table cannot place. Those keep their
#     unpriced row and the panel shows what it always showed.
#   * DeepSeek's off-peak half price is not modelled: CodeBurn has no off-peak
#     schedule, so an override is peak-priced and off-peak hours read at double
#     here. The DeepSeek tab measures the account instead and is the honest
#     figure for money actually charged.
def deepseek_rates():
    """TOKEN_MODELS from DeepSeekModel.js, or {} when node cannot read it."""
    try:
        result = subprocess.run(
            ["node", "-e", "process.stdout.write(JSON.stringify(require(%s).TOKEN_MODELS))"
             % json.dumps(MODEL_JS)],
            capture_output=True, text=True, timeout=20,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log("rate table unreadable: %s" % exc)
        return {}
    if result.returncode != 0 or not result.stdout.strip():
        log("rate table exit %s: %s" % (result.returncode, result.stderr.strip()[:200]))
        return {}
    try:
        rates = json.loads(result.stdout)
    except ValueError as exc:
        log("rate table JSON unreadable: %s" % exc)
        return {}
    return rates if isinstance(rates, dict) else {}


def tokens_of(name):
    """A model name's family and tier: ("deepseek", "flash") for deepseek-v4.1-flash."""
    parts = [p for p in re.split(r"[-_/. ]+", str(name or "").strip().lower()) if p]
    if not parts:
        return "", ""
    return parts[0], parts[-1]


def rate_for(model, rates):
    """The table entry for a model name, by family *and* tier, or None."""
    family, tier = tokens_of(model)
    if not family or not tier:
        return None
    for entry in rates.values():
        if isinstance(entry, dict) and tokens_of(entry.get("label")) == (family, tier):
            return entry
    return None


def number(value):
    """A rate the way price-override wants it: 0.3, not 0.30000000000000004."""
    try:
        return "%g" % float(value)
    except (TypeError, ValueError):
        return ""


def price_missing(status, runner):
    """Price what CodeBurn could not, and report what was priced. See above."""
    unpriced = (status.get("current") or {}).get("unpricedModels") or []
    if not unpriced:
        return []
    rates = deepseek_rates()
    if not rates:
        return []

    priced = []
    for row in unpriced:
        row = row or {}
        model = str(row.get("model") or "").strip()
        entry = rate_for(model, rates)
        if not entry:
            log("unpriced and not in the rate table, left alone: %s" % model)
            continue
        rates_argv = ["--input", number(entry.get("inputMissPeak")),
                      "--output", number(entry.get("outputPeak")),
                      "--cache-read", number(entry.get("inputCacheHitPeak"))]
        if not all(rates_argv[1::2]):
            log("rate table entry for %s is incomplete, left alone" % model)
            continue
        try:
            result = subprocess.run(runner + ["price-override", model] + rates_argv,
                                    capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as exc:
            log("price-override failed for %s: %s" % (model, exc))
            continue
        if result.returncode != 0:
            log("price-override exited %s for %s: %s" % (
                result.returncode, model, result.stderr.strip()[:200]))
            continue
        log("priced %s from the published DeepSeek table as %s" % (model, entry.get("label")))
        priced.append({
            "model": model,
            "from": entry.get("label"),
            "rates": {
                "input": entry.get("inputMissPeak"),
                "output": entry.get("outputPeak"),
                "cacheRead": entry.get("inputCacheHitPeak"),
            },
            "calls": row.get("calls"),
            "tokens": row.get("tokens"),
        })
    return priced


def carried_rows():
    """The rows a previous read of this poll already priced, or []."""
    if not CARRIED:
        return []
    try:
        rows = json.loads(CARRIED)
    except ValueError:
        return []
    return rows if isinstance(rows, list) else []


def main():
    period = sys.argv[1] if len(sys.argv) > 1 else "today"
    runner = os.environ.get("CODEBURN_RUNNER", "").split() or ["codeburn"]

    raw = sys.stdin.read()
    try:
        status = json.loads(raw)
    except ValueError as exc:
        log("status JSON unreadable: %s" % exc)
        sys.stdout.write(raw)
        return

    rows = model_rows(runner, period)
    omp = load_omp_status()
    excluded = False
    if omp is not None:
        try:
            excluded = exclude_omp(status, omp)
        except Exception as exc:  # never fail the pipeline over this
            log("OMP exclusion skipped: %s" % exc)
            excluded = False

    if rows:
        visible = [row for row in rows
                   if not (excluded and str((row or {}).get("provider") or "") == "omp")]
        merged = merge_model_rows(visible)
        status["modelTokens"] = merged
        if excluded:
            (status.get("current") or {})["topModels"] = [
                {"name": row["name"], "cost": row["cost"], "calls": row["calls"]}
                for row in merged
            ]
    elif excluded:
        subtract_models(status.get("current") or {}, omp)
    if excluded:
        status["ompExcluded"] = True

    code, symbol, rate, source = local_currency()
    status["localCurrency"] = {"code": code, "symbol": symbol, "rate": rate, "source": source}

    try:
        priced = carried_rows() + price_missing(status, runner)
    except Exception as exc:  # never fail the pipeline over this
        log("auto-pricing skipped: %s" % exc)
        priced = carried_rows()
    if priced:
        status["autoPriced"] = priced

    current = status.get("current") or {}
    log("period %s: %d model(s), calls %s, cost %.2f, currency %s@%s, priced %d%s" % (
        period, len(status.get("modelTokens") or []), current.get("calls", "?"),
        float(current.get("cost") or 0), code, rate, len(priced),
        ", OMP excluded" if excluded else ""))

    sys.stdout.write(json.dumps(status))


if __name__ == "__main__":
    main()
