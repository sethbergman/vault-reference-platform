#!/usr/bin/env bash
#
# run-tests.sh — Tests for the Alertmanager routing tree
#
# Usage:
#   ./tests/alert-routing/run-tests.sh
#
# WHAT IS BEING TESTED
#
# Not that alerts fire — tests/alerting drives the rule file through
# promtool for that. Not that they reach Alertmanager — tests/integration
# does that against a live cluster.
#
# This covers the layer between: given an alert with these labels, which
# receiver does it go to, how is it grouped, and is it suppressed by
# something else. That layer is pure configuration, it is easy to get
# subtly wrong, and every way of getting it wrong is silent — an alert
# routed to the wrong receiver looks exactly like an alert nobody sent.
#
# Where the answer belongs to Alertmanager — which route matches a label
# set — the question is put to `amtool` rather than to a reimplementation
# of its matching rules here. A test that reimplements the thing it is
# testing agrees with itself and nothing else. Those cases need Docker
# and are skipped without it; everything else reads the config directly.
#
# THE CHECK WORTH READING
#
# "every alert in the rule file routes somewhere deliberate" is the one
# that catches real mistakes. A new alert with a misspelled severity, or
# no severity at all, matches no route, falls through to the catch-all,
# and is never paged for. Nothing else in this repository would notice.
#
# Requirements: bash, python3 with PyYAML. Docker for the amtool cases.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AM_CONFIG="${REPO_ROOT}/docker/monitoring/alertmanager.yml"
RULES="${REPO_ROOT}/docker/monitoring/rules/vault.yml"
AM_IMAGE="prom/alertmanager:v0.27.0"

PASS=0
FAIL=0
SKIP=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()   { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

[[ -f "$AM_CONFIG" ]] || { red "ERROR: missing ${AM_CONFIG}"; exit 1; }
[[ -f "$RULES" ]]     || { red "ERROR: missing ${RULES}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { red "ERROR: python3 not found"; exit 1; }

HELPER="${SCRIPT_DIR}/query.py"
[[ -f "$HELPER" ]] || { red "ERROR: missing ${HELPER}"; exit 1; }

# ask <question> — put a question to the config via the python helper.
# The helper holds the YAML reading so this file holds only assertions.
ask() { python3 "$HELPER" "$AM_CONFIG" "$RULES" "$1" 2>&1; }

assert_ask() {
    local label="$1" question="$2" want="$3"
    local got
    got="$(ask "$question")"
    if [[ "$got" == "$want" ]]; then
        ok "$label"
    else
        bad "$label" "expected '${want}', got '${got}'"
    fi
}

# ---------------------------------------------------------------------------
printf '\n=== Every alert routes somewhere deliberate ===\n'
# ---------------------------------------------------------------------------
# The failure this prevents: an alert whose severity is misspelled, or
# absent, matches no route and lands in the catch-all. It fires, it is
# grouped, it is delivered, and nobody is paged.
assert_ask "every alert in the rule file carries a severity" \
    alerts-without-severity "none"

assert_ask "and every severity used has a route of its own" \
    severities-without-route "none"

# ---------------------------------------------------------------------------
printf '\n=== Critical pages, warning does not ===\n'
# ---------------------------------------------------------------------------
# These are the settings that make a page a page. Left at the defaults, a
# critical alert waits to be grouped and then never repeats, which is a
# ticket wearing the word "critical".
assert_ask "critical has no group_wait — a page should not wait for company" \
    critical-group-wait "0s"

assert_ask "critical repeats until someone acts on it" \
    critical-repeat-interval "15m"

assert_ask "warning does not repeat through the night" \
    warning-repeat-interval "12h"

# ---------------------------------------------------------------------------
printf '\n=== Grouping collapses an incident into one notification ===\n'
# ---------------------------------------------------------------------------
# Grouping by instance is the classic mistake: three nodes sealing at
# once is one incident, and it would page three times.
assert_ask "grouping is not per-instance" group-by-has-instance "False"
assert_ask "and groups by alertname"      group-by-has-alertname "True"

# ---------------------------------------------------------------------------
printf '\n=== Inhibition names alerts that exist ===\n'
# ---------------------------------------------------------------------------
# An inhibit rule matching an alertname no rule produces is inert. It
# suppresses nothing, raises no error, and reads in review as though the
# noise problem had been handled.
assert_ask "every inhibit rule references a real alert" \
    inhibit-unknown-alertnames "none"

assert_ask "and nothing inhibits itself" \
    inhibit-self-referential "none"

# ---------------------------------------------------------------------------
printf '\n=== Every route points at a receiver that exists ===\n'
# ---------------------------------------------------------------------------
assert_ask "no route names a receiver that was never defined" \
    routes-to-undefined-receivers "none"

# The previous config had `webhook_configs: []` — a receiver that parses,
# validates, and silently delivers nowhere.
assert_ask "and every receiver actually delivers somewhere" \
    receivers-with-no-destination "none"

# ---------------------------------------------------------------------------
printf '\n=== Alertmanager agrees (amtool) ===\n'
# ---------------------------------------------------------------------------
# Which route matches a label set is Alertmanager's question to answer,
# so it is asked rather than modelled.
if ! command -v docker >/dev/null 2>&1; then
    skip "amtool cases" "docker not available; CI runs these"
elif ! docker info >/dev/null 2>&1; then
    skip "amtool cases" "docker is installed but not running; CI runs these"
else
    amtool_run() {
        docker run --rm -v "${REPO_ROOT}/docker/monitoring:/cfg:ro" \
            --entrypoint amtool "$AM_IMAGE" "$@" 2>&1
    }

    OUT="$(amtool_run check-config /cfg/alertmanager.yml)"
    if [[ "$OUT" == *"SUCCESS"* || "$OUT" == *"Found:"* ]]; then
        ok "the config is valid Alertmanager configuration"
    else
        bad "the config is valid Alertmanager configuration" "$(head -3 <<< "$OUT")"
    fi

    # amtool prints the matching receiver. Take the last non-empty line
    # rather than literally the last line: a trailing newline or a stray
    # warning would otherwise turn every assertion below into a failure
    # that says nothing about routing. ROUTE_RAW keeps the full output so
    # a failure can show what was actually printed.
    ROUTE_RAW=""
    route_for() {
        ROUTE_RAW="$(amtool_run config routes test \
            --config.file=/cfg/alertmanager.yml "$@")"
        printf '%s' "$ROUTE_RAW" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -1
    }

    R="$(route_for severity=critical alertname=VaultQuorumLost)"
    if [[ "$R" == "page" ]]; then
        ok "a critical alert routes to the pager path"
    else
        bad "a critical alert routes to the pager path" "amtool printed: ${ROUTE_RAW}"
    fi

    R="$(route_for severity=warning alertname=VaultCertificateProbeMissing)"
    if [[ "$R" == "ticket" ]]; then
        ok "a warning routes to the ticket path"
    else
        bad "a warning routes to the ticket path" "amtool printed: ${ROUTE_RAW}"
    fi

    R="$(route_for alertname=SomethingWithNoSeverity)"
    if [[ "$R" == "default" ]]; then
        ok "an alert with no severity falls through to the catch-all"
    else
        bad "an alert with no severity falls through to the catch-all" "amtool printed: ${ROUTE_RAW}"
    fi

    # The reason the rule-file checks above are worth having: a typo in a
    # severity is not an error anywhere. It is simply not a page.
    R="$(route_for severity=crticial alertname=VaultQuorumLost)"
    if [[ "$R" == "default" ]]; then
        ok "a misspelled severity is silently not paged"
    else
        bad "a misspelled severity is silently not paged" "amtool printed: ${ROUTE_RAW}"
    fi
fi

printf '\n'
printf 'passed: %d   failed: %d   skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]] || exit 1
green "All alert routing tests passed."
