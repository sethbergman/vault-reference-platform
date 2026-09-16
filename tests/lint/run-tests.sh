#!/usr/bin/env bash
#
# run-tests.sh — Repo-wide invariants no other tool has an opinion about
#
# Usage:
#   ./tests/lint/run-tests.sh
#
# WHAT THIS IS FOR
#
# Each check here exists because the pattern it rejects shipped in this
# repository and was found by reading rather than by any test. They are
# cheap, they are repo-wide, and they fail the build with an explanation
# rather than leaving the next person to rediscover the same thing.
#
# The first was about shell, which is what this suite was named for.
# Prose drifts the same way and the second check is about that, so the
# scope is the invariant rather than the language it is written in.
#
# Requirements: bash, python3, and a checkout carrying its tags

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2"; return 0; }

command -v python3 >/dev/null 2>&1 || { red "ERROR: python3 not found"; exit 1; }

cd "$REPO_ROOT" || exit 1

# ---------------------------------------------------------------------------
printf '\n=== Trap handlers do not end in a bare conditional ===\n'
# ---------------------------------------------------------------------------
# A cleanup function whose last command is a false test returns 1, and
# bash applies that to the script's exit status from an EXIT trap. A run
# that did everything right then reports failure, and an explicit
# `exit 0` does not save it:
#
#     cleanup() { [[ -n "$D" && -d "$D" ]] && rm -rf "$D"; }
#     trap cleanup EXIT
#     exit 0            # -> exits 1 when $D is empty
#
# Both trap handlers in this repository had that shape. Neither was
# reachable, because nothing exited 0 before the directory was created —
# which is precisely why it would have been found by an operator adding a
# "nothing to do" path, rather than by CI.
if OUT="$(python3 "${SCRIPT_DIR}/check_trap_exit.py" 2>&1)"; then
    ok "no trap handler returns the result of a bare test"
else
    bad "no trap handler returns the result of a bare test" "$OUT"
fi

# ---------------------------------------------------------------------------
printf '
=== The README names the release the roadmap actually ships ===
'
# ---------------------------------------------------------------------------
# README.md carries one sentence naming the newest shipped release, and
# nothing checked it: at v0.18 it still said v0.14. Four PRs had updated
# the roadmap table directly beside it and left the sentence alone, which
# is the failure docs/README.md is generated to avoid — a hand-maintained
# claim that stops being true silently. One sentence is not worth
# generating, so it is asserted instead.
#
# The checker also requires the roadmap table to be no older than the
# newest git tag, which is why this suite now wants a checkout with tags.
if OUT="$(python3 "${SCRIPT_DIR}/check_version_claim.py" 2>&1)"; then
    ok "README, roadmap and tags agree on the newest release"
else
    bad "README, roadmap and tags agree on the newest release" "$OUT"
fi

printf '\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
green "All lint invariants hold."
