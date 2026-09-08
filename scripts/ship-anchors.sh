#!/usr/bin/env bash
#
# ship-anchors.sh — Copy audit chain anchors to storage that cannot
#                   delete them
#
# Usage:
#   ./ship-anchors.sh --bucket <name> [options]
#   ./ship-anchors.sh --bucket <name> --fetch <path>
#
# Options:
#   --bucket <name>        Object-lock bucket receiving the anchors.
#   --anchors <path>       Local anchor file. Default: read out of the
#                          running audit-anchor container.
#   --prefix <p>           Key prefix within the bucket (default: anchors).
#   --cluster <name>       Second key component, so one bucket can hold
#                          the anchors of several clusters (default: the
#                          hostname).
#   --retention-days <n>   COMPLIANCE retention applied to each object
#                          (default: 365).
#   --endpoint <url>       S3 endpoint. For pointing at an emulator; a
#                          real run does not need it.
#   --fetch <path>         Download every shipped anchor into <path>, in
#                          the format verify-audit-chain.sh reads, and
#                          exit. Ships nothing. Exits non-zero if any
#                          anchor has a delete marker over it -- the file
#                          is still written, because the anchors are
#                          still intact underneath.
#   --allow-unlocked       Ship to a bucket without object lock. Refused
#                          by default; see below for what it costs.
#
# WHAT THIS IS FOR
#
# The audit-anchor service records the chain head on a volume the
# collector cannot write to, which catches a chain rewritten to be
# self-consistent. Both volumes are on one Docker daemon, so whoever
# reaches the daemon reaches both, and the evidence dies with the host.
#
# This is the other end. Each anchor becomes an object under a COMPLIANCE
# retention lock, which no credential can shorten or delete — not the
# account root, not the operator who wrote it, not an attacker holding
# the same key this script runs with.
#
# DELIBERATE BEHAVIOURS
#
#   Object lock is checked, and a bucket without it is refused.
#   Shipping an audit trail somewhere the same attacker can empty is a
#   change of address, not a change of risk. --allow-unlocked exists for
#   the reader who wants to see the mechanism without provisioning a
#   locked bucket, and it says what it gave up.
#
#   One object per anchor, not one appended file. Object lock protects
#   objects. A single file holding every anchor is rewritten by one PUT,
#   which is the exact operation the lock has to prevent — so the
#   sequence number is part of the key and each anchor is immutable on
#   arrival.
#
#   A conflicting anchor is reported, never overwritten. If the bucket
#   already holds sequence N with a different hash, the local chain was
#   rewritten after N was shipped. That is the finding this whole
#   design exists to produce, so it exits non-zero and names the
#   sequence rather than uploading over it.
#
#   Nothing here deletes. There is no cleanup path, no --force, and no
#   retention override, because a shipper that can remove an anchor is a
#   shipper an attacker can use to remove an anchor.
#
#   Versions are listed, never objects. Object lock stops a version
#   being deleted; it does not stop a delete *marker* being written over
#   the key, and a marked key is absent from list-objects-v2 and 404s on
#   head-object. So the credential that ships anchors can hide every one
#   of them without deleting anything, and a fetch built on the object
#   APIs would report "no anchors found" -- which reads as "nothing was
#   ever anchored" at exactly the moment the distinction matters. Both
#   paths below list versions and read past the marker, and --fetch
#   reports the marker as the attack it is. The IAM policy in
#   terraform/aws/audit-anchors denies s3:DeleteObject for the same
#   reason; the lock alone does not cover this.
#
# WHAT SHIPPING DOES NOT PROVE
#
# The collector still runs beside Vault. This moves the *evidence* out of
# reach, not the collection of it: an attacker on the host can still stop
# the collector, and entries never collected are never anchored. What
# they cannot do is edit what already left. See docs/audit.md.
#
# Requirements: aws, sha256sum; docker compose when --anchors is omitted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}/docker/dev"

BUCKET=""
ANCHORS=""
PREFIX="anchors"
CLUSTER=""
RETENTION_DAYS=365
ENDPOINT=""
FETCH_TO=""
ALLOW_UNLOCKED=false

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { printf '[ship-anchors] %s\n' "$*" >&2; }
warn() { printf '\033[33m[ship-anchors] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m[ship-anchors] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bucket)          BUCKET="$2"; shift 2 ;;
        --anchors)         ANCHORS="$2"; shift 2 ;;
        --prefix)          PREFIX="$2"; shift 2 ;;
        --cluster)         CLUSTER="$2"; shift 2 ;;
        --retention-days)  RETENTION_DAYS="$2"; shift 2 ;;
        --endpoint)        ENDPOINT="$2"; shift 2 ;;
        --fetch)           FETCH_TO="$2"; shift 2 ;;
        --allow-unlocked)  ALLOW_UNLOCKED=true; shift ;;
        -h|--help)         usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$BUCKET" ]] || die "--bucket is required"
command -v aws >/dev/null 2>&1 || die "aws not found on PATH"

[[ "$RETENTION_DAYS" =~ ^[0-9]+$ && "$RETENTION_DAYS" -gt 0 ]] \
    || die "--retention-days must be a positive integer, got: ${RETENTION_DAYS}"

CLUSTER="${CLUSTER:-$(hostname)}"

# Built once. Every call goes through this so that --endpoint cannot be
# honoured by some requests and forgotten by others -- which would show
# up as a test passing against an emulator while the check it describes
# was answered by real AWS, or by nothing at all.
AWS_ARGS=()
[[ -n "$ENDPOINT" ]] && AWS_ARGS+=(--endpoint-url "$ENDPOINT")

aws_s3api() {
    aws "${AWS_ARGS[@]}" s3api "$@"
}

KEY_BASE="${PREFIX}/${CLUSTER}"

# ---------------------------------------------------------------------------
# Fetch: bring the shipped anchors back for verification
# ---------------------------------------------------------------------------
#
# Separate from shipping because it is the half you run during an
# incident, on a machine that is not the compromised one, with a
# read-only credential. Bundling it into the ship path would mean
# verifying with the same key that writes.

if [[ -n "$FETCH_TO" ]]; then
    log "Fetching anchors from s3://${BUCKET}/${KEY_BASE}/"

    # Versions, not objects, and the delete markers separately.
    #
    # Reading Versions[] is what makes a hidden anchor fetchable at all:
    # a marker is the newest version of the key, so the object APIs
    # report the key as gone while the locked version underneath is
    # intact and readable by version id.
    #
    # `sort -k1,1 -s` groups by key and nothing else. S3 returns versions
    # newest first within a key and a version id is opaque -- there is
    # nothing in one to sort by -- so the API's own order is the only
    # thing that says which version is oldest, and a stable sort on the
    # key alone preserves it. A plain `sort` would order by version id
    # and pick an arbitrary version to call the original.
    KEYS="${WORK}/keys"
    aws_s3api list-object-versions \
        --bucket "$BUCKET" --prefix "${KEY_BASE}/" \
        --query 'Versions[].[Key,VersionId]' --output text 2>/dev/null \
        | grep -v '^None' | grep . | sort -k1,1 -s > "$KEYS" || true

    MARKERS="${WORK}/markers"
    aws_s3api list-object-versions \
        --bucket "$BUCKET" --prefix "${KEY_BASE}/" \
        --query 'DeleteMarkers[].Key' --output text 2>/dev/null \
        | tr '\t' '\n' | grep -v '^None$' | grep . | sort -u > "$MARKERS" || true

    if [[ ! -s "$KEYS" ]]; then
        die "no anchors found under s3://${BUCKET}/${KEY_BASE}/"
    fi

    # The OLDEST version of each key: the anchor as originally shipped.
    # A second version of one key cannot have come from this script --
    # it reports a conflicting sequence rather than writing over one --
    # so a newer version is somebody else's write, and preferring it
    # would let whoever can write to the bucket decide what counts as
    # the original.
    #
    # Oldest is the last line of each key's group, the list being
    # newest-first, so each group is emitted when the next one starts.
    : > "$FETCH_TO"
    COUNT=0
    PREV_KEY=""
    PREV_VID=""

    emit_oldest() {
        [[ -n "$PREV_KEY" ]] || return 0
        aws_s3api get-object --bucket "$BUCKET" --key "$PREV_KEY" \
            --version-id "$PREV_VID" "${WORK}/obj" >/dev/null 2>&1 \
            || die "could not read s3://${BUCKET}/${PREV_KEY} version ${PREV_VID}"
        cat "${WORK}/obj" >> "$FETCH_TO"
        COUNT=$((COUNT + 1))
    }

    while read -r key vid; do
        [[ -n "$key" && -n "$vid" ]] || continue
        if [[ "$key" != "$PREV_KEY" ]]; then
            emit_oldest
            PREV_KEY="$key"
        fi
        PREV_VID="$vid"
    done < "$KEYS"
    emit_oldest

    log "Wrote ${COUNT} anchor(s) to ${FETCH_TO}"

    if [[ -s "$MARKERS" ]]; then
        MARKED="$(wc -l < "$MARKERS" | tr -d ' ')"
        printf '\033[31m
%s shipped anchor(s) have a delete marker over them.

Object lock refused the deletion, so the anchors above were recovered by
version id and are intact. Writing the marker is not an accident and not
a retention policy expiring: something asked S3 to remove an anchor.

Whoever holds the shipping credential is the shortest explanation. The
IAM policy in terraform/aws/audit-anchors denies s3:DeleteObject exactly
so this cannot happen quietly -- if these markers exist, that policy is
not attached to whatever wrote them.

Marked keys:
\033[0m\n' "$MARKED" >&2
        sed 's/^/       /' "$MARKERS" >&2
    fi

    log "Verify with: ./scripts/verify-audit-chain.sh --anchors ${FETCH_TO} ..."

    # Non-zero when a marker was found, and the file is written either
    # way. A fetch that recovered the anchors and reported the attempt to
    # erase them only on stderr would still exit 0 -- so a scheduled
    # verification would record a success, and the one event the anchors
    # exist to surface would be the one nothing reacts to.
    [[ -s "$MARKERS" ]] && exit 1
    exit 0
fi

# ---------------------------------------------------------------------------
# Where the local anchors come from
# ---------------------------------------------------------------------------

if [[ -z "$ANCHORS" ]]; then
    command -v docker >/dev/null 2>&1 \
        || die "docker not found on PATH, and --anchors was not given"

    ANCHORS="${WORK}/anchors"
    docker compose -f "${COMPOSE_DIR}/docker-compose.yml" exec -T audit-anchor \
        cat /anchors/audit-anchors.log > "$ANCHORS" 2>/dev/null \
        || die "could not read anchors from the audit-anchor container.
       Start it with --with-audit, or pass --anchors <path>."
fi

[[ -f "$ANCHORS" ]] || die "anchor file not found: ${ANCHORS}"
[[ -s "$ANCHORS" ]] || die "anchor file is empty: ${ANCHORS}
       Nothing has been anchored yet. ANCHOR_INTERVAL is the wait."

# ---------------------------------------------------------------------------
# The bucket has to be able to refuse a delete
# ---------------------------------------------------------------------------

LOCK_STATUS=""
LOCKED=true
if LOCK_OUT="$(aws_s3api get-object-lock-configuration --bucket "$BUCKET" 2>&1)"; then
    case "$LOCK_OUT" in
        *Enabled*) LOCK_STATUS="Enabled" ;;
    esac
fi

if [[ "$LOCK_STATUS" != "Enabled" ]]; then
    LOCKED=false
    if [[ "$ALLOW_UNLOCKED" == true ]]; then
        warn "s3://${BUCKET} has no object lock, and --allow-unlocked was given."
        warn "Anchors shipped there can be deleted by anything holding this"
        warn "credential, which is the property that made shipping worth doing."
        warn "This demonstrates the mechanism. It does not protect the trail."
    else
        die "s3://${BUCKET} does not have object lock enabled.

       An anchor exists to be readable after someone edits the trail. In
       a bucket without object lock, whoever holds this credential can
       delete the anchors as easily as they edited the entries, and the
       shipping accomplished nothing.

       Object lock can only be enabled when a bucket is created, so this
       is not a setting to go and change. Create one with
       terraform/aws/audit-anchors, or pass --allow-unlocked if you are
       demonstrating the mechanism and know what it leaves out."
    fi
fi

# ---------------------------------------------------------------------------
# Ship
# ---------------------------------------------------------------------------

RETAIN_UNTIL="$(date -u -d "+${RETENTION_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v "+${RETENTION_DAYS}d" '+%Y-%m-%dT%H:%M:%SZ')"

# Retention is not an option on a bucket without object lock -- S3
# rejects the request outright rather than storing the anchor unprotected
# -- so --allow-unlocked has to mean shipping without it. Which is the
# honest shape: there is no partial version of this guarantee, and a run
# that quietly dropped the flags while still printing "retention
# COMPLIANCE" would be the reassuring lie this whole script exists
# against.
PUT_LOCK_ARGS=()
if [[ "$LOCKED" == true ]]; then
    PUT_LOCK_ARGS=(--object-lock-mode COMPLIANCE
                   --object-lock-retain-until-date "$RETAIN_UNTIL")
fi

log "Shipping anchors from ${ANCHORS}"
log "  to        s3://${BUCKET}/${KEY_BASE}/"
if [[ "$LOCKED" == true ]]; then
    log "  retention COMPLIANCE until ${RETAIN_UNTIL}"
else
    log "  retention NONE — these anchors are deletable"
fi

SHIPPED=0
SKIPPED=0
UNPARSEABLE=0
CONFLICTS=0

while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    # <timestamp> <seq> <hash>, written by docker/audit-collector/anchor.sh
    A_TS="$(printf '%s' "$line" | cut -d' ' -f1)"
    A_SEQ="$(printf '%s' "$line" | cut -d' ' -f2)"
    A_HASH="$(printf '%s' "$line" | cut -d' ' -f3)"

    # The sequence has to be a number, and not only because a corrupt
    # anchor file is worth reporting: it is about to go through
    # printf '%012d', which fails on anything else -- and under
    # `set -e` a failed command substitution ends the run on a printf
    # error message that says nothing about the anchor file.
    #
    # Counted separately from SKIPPED. Lumping them together would
    # report a corrupt line as "already present", which is the opposite
    # of what it means.
    if [[ -z "$A_HASH" || ! "$A_SEQ" =~ ^[0-9]+$ ]]; then
        warn "skipping unparseable anchor line: ${line}"
        UNPARSEABLE=$((UNPARSEABLE + 1))
        continue
    fi

    # Zero-padded so a plain lexical list comes back in sequence order.
    # Without it anchor 10 sorts before anchor 9, and --fetch hands
    # verify-audit-chain.sh a file that is out of order in a way nothing
    # downstream would notice.
    KEY="$(printf '%s/%012d.anchor' "$KEY_BASE" "$A_SEQ")"

    # Not head-object. A delete marker over the key makes head-object
    # 404, which reads as "never shipped" -- so a rewritten chain whose
    # anchors had been marked would ship again as a fresh anchor, and the
    # conflict this script exists to report would be resolved silently in
    # favour of whoever wrote the marker.
    # [-1] rather than [0]: the list is newest first, and the version to
    # compare a local anchor against is the one shipped first.
    EXISTING_VID="$(aws_s3api list-object-versions \
        --bucket "$BUCKET" --prefix "$KEY" \
        --query "Versions[?Key=='${KEY}'] | [-1].VersionId" \
        --output text 2>/dev/null || true)"

    if [[ -n "$EXISTING_VID" && "$EXISTING_VID" != "None" ]]; then
        aws_s3api get-object --bucket "$BUCKET" --key "$KEY" \
            --version-id "$EXISTING_VID" "${WORK}/existing" >/dev/null 2>&1 \
            || die "sequence ${A_SEQ} exists at ${KEY} but could not be read"

        EXISTING_HASH="$(cut -d' ' -f3 < "${WORK}/existing" | head -n 1)"

        if [[ "$EXISTING_HASH" == "$A_HASH" ]]; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        CONFLICTS=$((CONFLICTS + 1))
        printf '\033[31m[ship-anchors] CONFLICT at sequence %s\033[0m\n' "$A_SEQ" >&2
        printf '       shipped earlier: %s\n' "$EXISTING_HASH" >&2
        printf '       local chain now: %s\n' "$A_HASH" >&2
        continue
    fi

    printf '%s %s %s\n' "$A_TS" "$A_SEQ" "$A_HASH" > "${WORK}/anchor"

    aws_s3api put-object \
        --bucket "$BUCKET" --key "$KEY" \
        --body "${WORK}/anchor" \
        "${PUT_LOCK_ARGS[@]+"${PUT_LOCK_ARGS[@]}"}" \
        >/dev/null \
        || die "failed to ship sequence ${A_SEQ} to s3://${BUCKET}/${KEY}"

    SHIPPED=$((SHIPPED + 1))
done < "$ANCHORS"

log "Shipped ${SHIPPED}, already present ${SKIPPED}."
if [[ "$UNPARSEABLE" -gt 0 ]]; then
    warn "${UNPARSEABLE} line(s) in ${ANCHORS} could not be parsed and were not shipped."
    warn "The anchor format is '<timestamp> <sequence> <hash>'. Something"
    warn "other than docker/audit-collector/anchor.sh has written to it."
fi

if [[ "$CONFLICTS" -gt 0 ]]; then
    printf '\033[31m
%s anchor(s) disagree with what was already shipped.

The chain file now hashes differently at a sequence that was anchored
earlier. A chain does not change retroactively on its own: entries at or
before that sequence were altered, removed or inserted, and the chain was
recomputed to match.

Nothing was overwritten. Run verify-audit-chain.sh against the shipped
anchors to find the first sequence that diverges:

    ./scripts/ship-anchors.sh --bucket %s --fetch /tmp/shipped-anchors
    ./scripts/verify-audit-chain.sh --anchors /tmp/shipped-anchors
\033[0m\n' "$CONFLICTS" "$BUCKET" >&2
    exit 1
fi
