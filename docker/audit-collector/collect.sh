#!/bin/sh
#
# collect.sh — Receive audit entries and hash-chain them as they arrive
#
# socat runs one copy of this per connection and pipes the audit stream
# to stdin. Vault's socket device holds a single connection open, so in
# practice there is one; a reconnect starts another, which is why every
# append is taken under a lock.
#
# WHAT THIS ADDS OVER `socat ... OPEN:file,append`
#
# The previous collector appended bytes. Anyone able to write to the
# volume could remove the record of what they did and nothing would ever
# indicate it — the log would simply be shorter, and a shorter log is
# indistinguishable from a quieter day.
#
# Each entry now also produces a line in a parallel chain file:
#
#   <seq> <sha256(entry)> <sha256(previous_chain_hash + entry_hash)>
#
# Removing, altering or inserting an entry breaks the chain from that
# point on, and scripts/verify-audit-chain.sh reports the first sequence
# number where the recomputation diverges.
#
# WHAT IT DOES NOT ADD
#
# Chaining alone stops a careless attacker, not a thorough one: whoever
# can rewrite the log can recompute the chain over their edited version
# and it will verify. That is what the anchors are for — see anchor.sh.
# Without them this is a corruption detector, not tamper evidence.
#
# The audit log itself is written exactly as before: raw entries, one per
# line, no added fields. Anything already consuming it is unaffected, and
# the integrity data lives beside it rather than inside it.

set -u

COLLECT_DIR="${COLLECT_DIR:-/collector}"
LOG="${COLLECT_DIR}/audit-socket.log"
CHAIN="${COLLECT_DIR}/audit-chain.log"
LOCK="${COLLECT_DIR}/.chain.lock"

# mkdir, not flock. flock lives in util-linux, and when it is absent the
# shell prints "command not found" and carries straight on into the
# critical section — the appends still happen, unserialised, and nothing
# in the collected output says so. That is precisely the silent
# degradation this file exists to rule out, and it is what the first
# version of this script did on a host without util-linux. mkdir is
# atomic everywhere and always present.
lock_acquire() {
    i=0
    while ! mkdir "$LOCK" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 100 ]; then
            # Five seconds. Vault holds a single connection, so real
            # contention means a reconnect overlapped, or a previous
            # collector was killed mid-entry and left the directory
            # behind. Say so on stderr and continue: dropping an audit
            # entry to protect the ordering is the worse trade, and a
            # forked chain is something verification reports rather than
            # something it hides.
            printf 'collect.sh: lock timeout, proceeding unserialised\n' >&2
            return 0
        fi
        sleep 0.05
    done
    return 0
}

lock_release() {
    rmdir "$LOCK" 2>/dev/null || true
}

# The chain has to start somewhere. A fixed, published value means the
# first entry's hash is reproducible by anyone verifying, rather than
# depending on a secret only the collector knows.
GENESIS="0000000000000000000000000000000000000000000000000000000000000000"

sha() {
    # Reads stdin, prints the bare hex digest.
    sha256sum | cut -d' ' -f1
}

while IFS= read -r line; do
    # Vault sends one JSON object per line. A blank line carries no
    # entry, so chaining it would add a link representing nothing.
    [ -n "$line" ] || continue

    # Serialise the read-modify-write. Two connections appending at once
    # would otherwise both read the same head and produce two entries
    # claiming the same predecessor — a chain that forks is a chain that
    # cannot be verified.
    lock_acquire
    (
        ENTRY_HASH="$(printf '%s\n' "$line" | sha)"

        if [ -s "$CHAIN" ]; then
            LAST="$(tail -n 1 "$CHAIN")"
            PREV_SEQ="$(printf '%s' "$LAST" | cut -d' ' -f1)"
            PREV_HASH="$(printf '%s' "$LAST" | cut -d' ' -f3)"
            SEQ=$((PREV_SEQ + 1))
        else
            PREV_HASH="$GENESIS"
            SEQ=1
        fi

        CHAIN_HASH="$(printf '%s%s' "$PREV_HASH" "$ENTRY_HASH" | sha)"

        # The entry lands first. If the container dies between these two
        # writes, verification reports a log longer than its chain —
        # which is a visible, explainable state. The reverse order would
        # claim an entry that was never recorded.
        printf '%s\n' "$line" >> "$LOG"
        printf '%s %s %s\n' "$SEQ" "$ENTRY_HASH" "$CHAIN_HASH" >> "$CHAIN"
    )
    lock_release
done
