#!/usr/bin/env bash
#
# verify-audit-chain.sh — Check the audit trail has not been edited
#
# Usage:
#   ./verify-audit-chain.sh [options]
#
# Options:
#   --log <path>      Raw audit entries   (default: pulled from compose)
#   --chain <path>    Chain file
#   --anchors <path>  Anchor file
#   --from-compose    Copy all three out of the running containers first.
#                     This is the default when no paths are given.
#   --quiet           Only print the verdict.
#
# WHAT IT CHECKS, AND WHAT EACH FAILURE MEANS
#
# The checks answer different questions and it is worth keeping them
# apart, because "the log is shorter than it was" and "somebody rewrote
# the log" call for different responses:
#
#   chain mismatch at N   an entry at or before N was altered, removed or
#                         inserted. Everything after N is unverifiable.
#   log longer than chain the tail was never chained. Usually the
#                         collector died mid-entry; suspicious only if it
#                         did not.
#   chain longer than log entries were deleted from the log while the
#                         chain kept its record of them.
#   anchor mismatch       the chain itself was rewritten. Somebody with
#                         write access recomputed it to cover an edit,
#                         and the anchor — which they could not reach —
#                         still remembers the real head.
#
# The last one is the only check that survives an attacker with write
# access to the audit volume. Without anchors this script detects
# corruption and careless tampering, and calls it tamper evidence, which
# would be a lie.
#
# Requirements: sha256sum (coreutils), and docker compose for
# --from-compose.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOG=""
CHAIN=""
ANCHORS=""
FROM_COMPOSE=false
QUIET=false

GENESIS="0000000000000000000000000000000000000000000000000000000000000000"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }
say()   { [[ "$QUIET" == true ]] || printf '%s\n' "$*"; }
die()   { red "ERROR: $*"; exit 2; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --log)          LOG="$2"; shift 2 ;;
        --chain)        CHAIN="$2"; shift 2 ;;
        --anchors)      ANCHORS="$2"; shift 2 ;;
        --from-compose) FROM_COMPOSE=true; shift ;;
        --quiet)        QUIET=true; shift ;;
        -h|--help)      usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

if [[ -z "$LOG" && -z "$CHAIN" ]]; then
    FROM_COMPOSE=true
fi

if [[ "$FROM_COMPOSE" == true ]]; then
    command -v docker >/dev/null 2>&1 || die "docker not found on PATH"

    COMPOSE_DIR="${REPO_ROOT}/docker/dev"
    say "Copying the trail out of the running containers..."

    docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T audit-collector \
        cat /collector/audit-socket.log > "${WORK}/log" 2>/dev/null \
        || die "Could not read the audit log from audit-collector"
    docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T audit-collector \
        cat /collector/audit-chain.log > "${WORK}/chain" 2>/dev/null \
        || die "Could not read the chain from audit-collector"
    # Anchors live in a different service on a different volume, which is
    # the entire point; a missing anchor service is a warning, not a
    # failure, because the chain checks still mean something without it.
    docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T audit-anchor \
        cat /anchors/audit-anchors.log > "${WORK}/anchors" 2>/dev/null || true

    LOG="${WORK}/log"
    CHAIN="${WORK}/chain"
    [[ -s "${WORK}/anchors" ]] && ANCHORS="${WORK}/anchors"
fi

[[ -f "$LOG" ]]   || die "No audit log at ${LOG}"
[[ -f "$CHAIN" ]] || die "No chain file at ${CHAIN}"

# awk, not `grep -c ''`: grep prints 0 and *also* exits 1 on an empty
# file, so the usual `|| echo 0` fallback appends a second zero and every
# comparison below silently stops meaning anything.
count_lines() { awk 'END {print NR}' "$1" 2>/dev/null; }

LOG_LINES="$(count_lines "$LOG")"
CHAIN_LINES="$(count_lines "$CHAIN")"

say ""
say "  entries in the log:   ${LOG_LINES}"
say "  links in the chain:   ${CHAIN_LINES}"
ANCHOR_COUNT=0
[[ -n "$ANCHORS" && -f "$ANCHORS" ]] && ANCHOR_COUNT="$(count_lines "$ANCHORS")"
say "  anchors:              ${ANCHOR_COUNT}"
say ""

if [[ "$CHAIN_LINES" -eq 0 ]]; then
    if [[ "$LOG_LINES" -eq 0 ]]; then
        say "Nothing has been collected yet — no entries, no chain."
        green "OK (empty)"
        exit 0
    fi
    red "FAIL  ${LOG_LINES} entries and no chain at all"
    printf '      The collector wrote entries without chaining them, which is\n'
    printf '      what the old append-only collector did. Verification is not\n'
    printf '      possible against this trail.\n'
    exit 1
fi

# ---------------------------------------------------------------------------
# Recompute the chain from the entries themselves
# ---------------------------------------------------------------------------
# Everything is derived from the log, then compared against what the
# collector recorded. Reading the chain and checking it is
# self-consistent would pass on any internally consistent forgery.
RECOMPUTED="${WORK}/recomputed"
: > "$RECOMPUTED"

PREV="$GENESIS"
SEQ=0
FIRST_BAD=""
FIRST_BAD_WHY=""

while IFS= read -r line; do
    SEQ=$((SEQ + 1))

    ENTRY_HASH="$(printf '%s\n' "$line" | sha256sum | cut -d' ' -f1)"
    CHAIN_HASH="$(printf '%s%s' "$PREV" "$ENTRY_HASH" | sha256sum | cut -d' ' -f1)"
    printf '%s %s %s\n' "$SEQ" "$ENTRY_HASH" "$CHAIN_HASH" >> "$RECOMPUTED"

    if [[ -z "$FIRST_BAD" && "$SEQ" -le "$CHAIN_LINES" ]]; then
        RECORDED="$(sed -n "${SEQ}p" "$CHAIN")"
        R_SEQ="$(cut -d' ' -f1 <<< "$RECORDED")"
        R_ENTRY="$(cut -d' ' -f2 <<< "$RECORDED")"
        R_CHAIN="$(cut -d' ' -f3 <<< "$RECORDED")"

        if [[ "$R_SEQ" != "$SEQ" ]]; then
            FIRST_BAD="$SEQ"
            FIRST_BAD_WHY="sequence numbers do not line up (chain says ${R_SEQ})"
        elif [[ "$R_ENTRY" != "$ENTRY_HASH" ]]; then
            FIRST_BAD="$SEQ"
            FIRST_BAD_WHY="the entry does not hash to what the chain recorded — it was altered or replaced"
        elif [[ "$R_CHAIN" != "$CHAIN_HASH" ]]; then
            FIRST_BAD="$SEQ"
            FIRST_BAD_WHY="the entry is intact but its link is wrong — an entry before it was removed or inserted"
        fi
    fi

    PREV="$CHAIN_HASH"
done < "$LOG"

FAILED=false

if [[ -n "$FIRST_BAD" ]]; then
    FAILED=true
    red "FAIL  the chain diverges at entry ${FIRST_BAD}"
    printf '      %s\n' "$FIRST_BAD_WHY"
    printf '      Entries after %s cannot be trusted either: each link covers\n' "$FIRST_BAD"
    printf '      the one before it, so everything downstream inherits the break.\n'
    say ""
fi

if [[ "$LOG_LINES" -gt "$CHAIN_LINES" ]]; then
    FAILED=true
    red "FAIL  $((LOG_LINES - CHAIN_LINES)) entries at the end are not chained"
    printf '      The collector recorded them and stopped before linking them.\n'
    printf '      A crash between the two writes does this and is benign; so\n'
    printf '      does appending entries by hand, which is not.\n'
    say ""
elif [[ "$CHAIN_LINES" -gt "$LOG_LINES" ]]; then
    FAILED=true
    red "FAIL  the chain has $((CHAIN_LINES - LOG_LINES)) links with no entry behind them"
    printf '      Entries were deleted from the log. The chain still carries\n'
    printf '      their hashes, which is how this is visible at all.\n'
    say ""
fi

# ---------------------------------------------------------------------------
# Anchors: the check a rewritten chain cannot pass
# ---------------------------------------------------------------------------
if [[ -n "$ANCHORS" && -f "$ANCHORS" && -s "$ANCHORS" ]]; then
    ANCHOR_BAD=0
    ANCHOR_OK=0
    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        A_SEQ="$(awk '{print $2}' <<< "$a")"
        A_HASH="$(awk '{print $3}' <<< "$a")"
        [[ -n "$A_SEQ" && -n "$A_HASH" ]] || continue

        if [[ "$A_SEQ" -gt "$LOG_LINES" ]]; then
            ANCHOR_BAD=$((ANCHOR_BAD + 1))
            red "FAIL  an anchor records entry ${A_SEQ}, but the log now holds only ${LOG_LINES}"
            printf '      The trail was truncated after it was anchored.\n'
            continue
        fi

        R_HASH="$(sed -n "${A_SEQ}p" "$RECOMPUTED" | cut -d' ' -f3)"
        if [[ "$R_HASH" == "$A_HASH" ]]; then
            ANCHOR_OK=$((ANCHOR_OK + 1))
        else
            ANCHOR_BAD=$((ANCHOR_BAD + 1))
            red "FAIL  the anchor for entry ${A_SEQ} does not match the trail"
            printf '      anchored: %s\n' "$A_HASH"
            printf '      now:      %s\n' "$R_HASH"
            printf '      The chain was rewritten to be self-consistent over edited\n'
            printf '      entries. The anchor was written where the collector cannot\n'
            printf '      reach, so it still carries the original head.\n'
        fi
    done < "$ANCHORS"

    if [[ "$ANCHOR_BAD" -gt 0 ]]; then
        FAILED=true
        say ""
    else
        say "  ${ANCHOR_OK} anchor(s) agree with the trail"
    fi
else
    amber "  no anchors available"
    printf '      Without them this run detects corruption and careless edits,\n'
    printf '      but not an attacker who rewrote the chain to match. Start the\n'
    printf '      audit-anchor service, or point --anchors at its file.\n'
    say ""
fi

if [[ "$FAILED" == true ]]; then
    red "The audit trail does not verify."
    exit 1
fi

green "OK — ${LOG_LINES} entries, chain intact$([[ -n "$ANCHORS" && -s "$ANCHORS" ]] && printf ' and anchored')."
exit 0
