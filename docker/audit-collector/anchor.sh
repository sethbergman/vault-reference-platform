#!/bin/sh
#
# anchor.sh — Periodically record the chain head somewhere the collector
#             cannot reach
#
# WHY THIS EXISTS
#
# A hash chain detects edits by whoever cannot recompute it. It does
# nothing against whoever can: an attacker with write access to the chain
# file removes the entries recording what they did, recomputes every hash
# from that point, and the result verifies perfectly. The chain is
# internally consistent and completely false.
#
# What breaks that is a copy of the head hash held somewhere the attacker
# does not control. Once the head for sequence N is written down
# elsewhere, any later rewrite of entries at or before N produces a
# different head, and the two disagree. The attacker cannot fix the
# disagreement without also reaching the anchors.
#
# So this runs as its own service, with the audit volume mounted
# READ-ONLY and its anchors on a separate volume the collector cannot
# write to. That is a real separation on one host, and it is not the same
# thing as a separate host — see docs/audit.md, which says so plainly and
# describes what a production anchor should be instead (object-lock
# storage, or a different account entirely).
#
# Anchoring is periodic, not per-entry. Entries written since the last
# anchor are protected by the chain but not yet by an anchor, so the
# interval is the window in which a thorough attacker can still rewrite
# history undetected. Shorter is safer and noisier.

set -u

COLLECT_DIR="${COLLECT_DIR:-/collector}"
ANCHOR_DIR="${ANCHOR_DIR:-/anchors}"
INTERVAL="${ANCHOR_INTERVAL:-15}"

CHAIN="${COLLECT_DIR}/audit-chain.log"
ANCHORS="${ANCHOR_DIR}/audit-anchors.log"

mkdir -p "$ANCHOR_DIR"

LAST_ANCHORED=""

while :; do
    if [ -s "$CHAIN" ]; then
        HEAD="$(tail -n 1 "$CHAIN" 2>/dev/null || true)"
        SEQ="$(printf '%s' "$HEAD" | cut -d' ' -f1)"
        HASH="$(printf '%s' "$HEAD" | cut -d' ' -f3)"

        # Only when it has moved. Re-anchoring an unchanged head would
        # fill the file with duplicates and make the useful question —
        # "what was the head at each point in time" — harder to answer.
        if [ -n "$SEQ" ] && [ "$SEQ" != "$LAST_ANCHORED" ]; then
            printf '%s %s %s\n' \
                "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SEQ" "$HASH" >> "$ANCHORS"
            LAST_ANCHORED="$SEQ"
        fi
    fi
    sleep "$INTERVAL"
done
