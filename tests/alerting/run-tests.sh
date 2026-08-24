#!/usr/bin/env bash
#
# run-tests.sh — Tests for the Vault alerting rules
#
# Usage:
#   ./tests/alerting/run-tests.sh
#
# Runs in a couple of seconds. No Prometheus server, no cluster.
#
# Two layers:
#
#   promtool test rules   feeds synthetic series into the real rule file
#                         and asserts which alerts fire. This is where
#                         the absence behaviour is actually proven: a
#                         series that stops existing must produce an
#                         alert, and the threshold rule that looks like
#                         it covers that case demonstrably does not.
#
#   structural checks     invariants promtool cannot express — that every
#                         freshness alert has a paired absent() alert,
#                         that every alert carries a runbook, and that
#                         the rule file is actually loaded by the
#                         Prometheus config.
#
# Requirements: promtool (from the Prometheus distribution), python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RULES="${REPO_ROOT}/docker/monitoring/rules/vault.yml"
RULE_TESTS="${SCRIPT_DIR}/vault_test.yml"
PROM_CONFIG="${REPO_ROOT}/docker/monitoring/prometheus.yml"

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { red "ERROR: python3 not found on PATH"; exit 1; }
command -v promtool >/dev/null 2>&1 || {
    red "ERROR: promtool not found on PATH."
    red "It ships with the Prometheus distribution:"
    red "  https://prometheus.io/download/"
    exit 1
}

[[ -f "$RULES" ]]      || { red "ERROR: no rule file at ${RULES}"; exit 1; }
[[ -f "$RULE_TESTS" ]] || { red "ERROR: no rule tests at ${RULE_TESTS}"; exit 1; }

# ---------------------------------------------------------------------------
printf '\n=== The rules parse ===\n'
# ---------------------------------------------------------------------------
if promtool check rules "$RULES" >/tmp/promtool-check.out 2>&1; then
    ok "promtool check rules"
else
    bad "promtool check rules" "$(sed 's/^/        /' /tmp/promtool-check.out)"
fi

if promtool check config "$PROM_CONFIG" >/tmp/promtool-config.out 2>&1; then
    ok "promtool check config"
else
    # The config references rule files by their in-container path, which
    # does not exist here. That is expected; anything else is not.
    if grep -qi "rule_files\|no such file" /tmp/promtool-config.out; then
        ok "promtool check config (rule paths are container-absolute)"
    else
        bad "promtool check config" "$(sed 's/^/        /' /tmp/promtool-config.out)"
    fi
fi

# ---------------------------------------------------------------------------
printf '\n=== The rules do what they claim ===\n'
# ---------------------------------------------------------------------------
# The real work. Each case in vault_test.yml drives synthetic series
# through the rule file and asserts exactly which alerts fire.
if promtool test rules "$RULE_TESTS" >/tmp/promtool-test.out 2>&1; then
    ok "promtool test rules (all cases)"
    # Surface the case names so a green run still shows what was covered.
    grep -E '^\s+(SUCCESS|Unit Testing)' /tmp/promtool-test.out 2>/dev/null | head -3 || true
else
    bad "promtool test rules" "$(sed 's/^/        /' /tmp/promtool-test.out)"
fi

# ---------------------------------------------------------------------------
printf '\n=== Every freshness alert has an absence alert ===\n'
# ---------------------------------------------------------------------------
# The invariant this whole rule file exists for, and the one promtool
# cannot state: a threshold expression over a metric that stops being
# reported produces no result and never fires. Pairing it with absent()
# is what makes the silence audible.
#
# Checked structurally so a future rule added without its pair fails
# here, rather than being discovered during the incident it was meant to
# catch.
STRUCT_OUT="$(python3 - "$RULES" <<'PY'
import sys, re, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
alerts = {r["alert"]: r for g in doc.get("groups", []) for r in g.get("rules", []) if "alert" in r}
guarded = set()
for r in alerts.values():
    guarded.update(re.findall(r"absent\(\s*([a-zA-Z_:][a-zA-Z0-9_:]*)", r["expr"]))
failures = []
for name, r in alerts.items():
    expr = r["expr"]
    if "time()" in expr and not expr.strip().startswith("absent("):
        metrics = [m for m in re.findall(r"\b([a-z_][a-z0-9_]*)\b", expr)
                   if m not in {"time", "absent", "sum", "rate", "by", "job", "instance"}]
        if not any(m in guarded for m in metrics):
            failures.append(f"{name}: freshness check with no absent() guard")
    ann = r.get("annotations", {})
    if not ann.get("runbook"):
        failures.append(f"{name}: no runbook annotation")
    if not ann.get("summary"):
        failures.append(f"{name}: no summary annotation")
    if not r.get("labels", {}).get("severity"):
        failures.append(f"{name}: no severity label")
print(len(alerts))
for f in failures:
    print(f)
PY
)"

ALERT_COUNT="$(head -1 <<< "$STRUCT_OUT")"
STRUCT_FAILURES="$(tail -n +2 <<< "$STRUCT_OUT")"

if [[ "${ALERT_COUNT:-0}" -ge 8 ]]; then
    ok "the rule file defines ${ALERT_COUNT} alerts"
else
    bad "the rule file defines a plausible number of alerts" "found ${ALERT_COUNT:-0}"
fi

if [[ -z "$STRUCT_FAILURES" ]]; then
    ok "every freshness alert is paired with an absent() alert"
    ok "every alert has a summary, a severity and a runbook"
else
    while IFS= read -r line; do
        [[ -n "$line" ]] && bad "structural check" "$line"
    done <<< "$STRUCT_FAILURES"
fi

# ---------------------------------------------------------------------------
printf '\n=== Every alert is tested both ways ===\n'
# ---------------------------------------------------------------------------
# An alert only ever asserted SILENT is indistinguishable from one that
# can never fire. An alert only ever asserted FIRING is indistinguishable
# from one stuck permanently on. Both need a case.
#
# This was not true when the rules were first written: VaultNodeSealed
# had no test at all, and VaultCertificateProbeMissing was only ever
# asserted quiet — in a rule file whose entire subject is things that
# fail by staying silent.
COVERAGE="$(python3 - "$RULES" "$RULE_TESTS" <<'PY'
import sys, yaml
rules = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
tests = yaml.safe_load(open(sys.argv[2], encoding="utf-8"))
defined = [r["alert"] for g in rules.get("groups", []) for r in g.get("rules", []) if "alert" in r]
fires, quiet = set(), set()
for case in tests.get("tests", []):
    for a in case.get("alert_rule_test", []):
        (fires if (a.get("exp_alerts") or []) else quiet).add(a["alertname"])
for name in defined:
    if name not in fires:
        print(f"{name}: never asserted to fire — it may be incapable of firing")
    if name not in quiet:
        print(f"{name}: never asserted to stay quiet — it may be permanently on")
PY
)"

if [[ -z "$COVERAGE" ]]; then
    ok "every alert has both a firing and a silent test case"
else
    while IFS= read -r line; do
        [[ -n "$line" ]] && bad "alert coverage" "$line"
    done <<< "$COVERAGE"
fi

# ---------------------------------------------------------------------------
printf '\n=== Runbook pointers lead somewhere ===\n'
# ---------------------------------------------------------------------------
# Asserting an alert *has* a runbook annotation is the same weak check as
# asserting a metric name is spelled like a metric. Eight of these
# originally pointed at a document that did not mention a single alert by
# name, so following the link at 3am landed on a general operations page.
#
# The annotation has to resolve to a file, and that file has to name the
# alert it was sent for.
RUNBOOKS="$(python3 - "$RULES" "$REPO_ROOT" <<'PY'
import sys, os, yaml
rules = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
root = sys.argv[2]
for g in rules.get("groups", []):
    for r in g.get("rules", []):
        if "alert" not in r:
            continue
        name = r["alert"]
        target = r.get("annotations", {}).get("runbook", "")
        path = os.path.join(root, target.split("#")[0])
        if not target:
            print(f"{name}: no runbook annotation")
        elif not os.path.isfile(path):
            print(f"{name}: runbook {target} does not exist")
        elif name not in open(path, encoding="utf-8").read():
            print(f"{name}: {target} exists but never mentions {name}")
PY
)"

if [[ -z "$RUNBOOKS" ]]; then
    ok "every alert's runbook exists and names that alert"
else
    while IFS= read -r line; do
        [[ -n "$line" ]] && bad "runbook check" "$line"
    done <<< "$RUNBOOKS"
fi

# ---------------------------------------------------------------------------
printf '\n=== Prometheus actually loads these rules ===\n'
# ---------------------------------------------------------------------------
# A rule file nothing loads is the same as no rule file, and the mistake
# is invisible: everything parses, the tests pass, and no alert exists.
CONFIG_TEXT="$(cat "$PROM_CONFIG")"
if [[ "$CONFIG_TEXT" == *"rule_files:"* ]]; then
    ok "prometheus.yml declares rule_files"
else
    bad "prometheus.yml declares rule_files"
fi

if [[ "$CONFIG_TEXT" == *"alertmanagers:"* ]]; then
    ok "and an alertmanager to send them to"
else
    bad "and an alertmanager to send them to" "rules that fire and reach nobody are not alerting"
fi

# The absence rules depend on these two jobs existing. Without the
# pushgateway job nothing reports snapshot success; without the tls job
# nothing reports certificate expiry.
for job in pushgateway vault-tls; do
    if [[ "$CONFIG_TEXT" == *"job_name: ${job}"* ]]; then
        ok "prometheus scrapes ${job}"
    else
        bad "prometheus scrapes ${job}" "an absence alert has nothing to observe without it"
    fi
done

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    red "FAILED"
    exit 1
fi
green "All ${PASS} assertions passed."
