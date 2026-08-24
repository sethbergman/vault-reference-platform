#!/usr/bin/env bash
#
# snapshot.sh — Take a Raft snapshot and upload it to cloud storage
#
# Usage:
#   ./snapshot.sh --cloud aws   --bucket <name>
#   ./snapshot.sh --cloud azure --account <name> --container <name>
#   ./snapshot.sh --cloud none  --output-dir /var/backups/vault
#
# Designed to run from a systemd timer on every node. Only the active
# node actually takes a snapshot; standbys exit 0 having done nothing, so
# the timer does not report a failure on two nodes out of three every
# hour. See ansible/roles/vault_snapshots.
#
# Deliberate behaviours, each of which is a failure mode someone has hit:
#
#   Never deletes anything. Retention is a server-side lifecycle rule
#   (S3 lifecycle, Azure delete_retention_policy) precisely so that a
#   compromised node cannot destroy the backups. The AWS instance role
#   has no s3:DeleteObject — see terraform/aws/iam.tf.
#
#   Verifies before uploading. A truncated or empty snapshot uploaded on
#   schedule is worse than no snapshot at all, because it looks like a
#   backup until the day you need it.
#
#   Always removes the local copy. The previous version left every
#   snapshot in /tmp forever, which on an hourly timer fills the disk and
#   takes the node down.
#
# Authentication, in order of precedence:
#   VAULT_TOKEN                     — used as-is
#   VAULT_ROLE_ID / VAULT_SECRET_ID — AppRole login, token revoked after
#
# Requirements: vault, jq; aws (AWS), curl (Azure)

set -euo pipefail

CLOUD=""
BUCKET=""
ACCOUNT=""
CONTAINER=""
OUTPUT_DIR=""
PREFIX="snapshots"
KEEP_LOCAL=false

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cloud)      CLOUD="$2"; shift 2 ;;
        --bucket)     BUCKET="$2"; shift 2 ;;
        --account)    ACCOUNT="$2"; shift 2 ;;
        --container)  CONTAINER="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --prefix)     PREFIX="$2"; shift 2 ;;
        --keep-local) KEEP_LOCAL=true; shift ;;
        -h|--help)    usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLOUD" ]] || die "--cloud is required (aws, azure, or none)"

case "$CLOUD" in
    aws)
        [[ -n "$BUCKET" ]] || die "--bucket is required with --cloud aws"
        ;;
    azure)
        [[ -n "$ACCOUNT" ]]   || die "--account is required with --cloud azure"
        [[ -n "$CONTAINER" ]] || die "--container is required with --cloud azure"
        ;;
    none)
        [[ -n "$OUTPUT_DIR" ]] || die "--output-dir is required with --cloud none"
        ;;
    *) die "--cloud must be aws, azure, or none, got: ${CLOUD}" ;;
esac

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v vault >/dev/null 2>&1 || die "vault not found on PATH"
command -v jq    >/dev/null 2>&1 || die "jq not found on PATH"

case "$CLOUD" in
    aws)   command -v aws  >/dev/null 2>&1 || die "aws not found on PATH" ;;
    azure) command -v curl >/dev/null 2>&1 || die "curl not found on PATH" ;;
esac

# ---------------------------------------------------------------------------
# Only the active node takes snapshots
# ---------------------------------------------------------------------------
# Checked before authenticating, so a standby never logs in at all. Three
# nodes each uploading the same state every hour costs three times the
# storage and gains nothing — they are snapshots of one Raft log.
#
# `vault status` is unauthenticated and exits non-zero when sealed, which
# is not an error worth failing the timer over: a sealed node is not the
# leader either way.
STATUS_JSON="$(vault status -format=json 2>/dev/null || true)"
[[ -n "$STATUS_JSON" ]] || die "Could not reach Vault at ${VAULT_ADDR:-<VAULT_ADDR unset>}"

# Not `.sealed // true`. jq's // treats false as empty, so that form
# returns true for an unsealed node and this script would exit 0 having
# done nothing — on every node, every hour, forever.
SEALED="$(jq -r 'if has("sealed") then .sealed else true end' <<< "$STATUS_JSON")"

if [[ "$SEALED" == "true" ]]; then
    log "Node is sealed; nothing to snapshot."
    exit 0
fi

# Leadership comes from sys/leader's is_self, not from ha_mode.
#
# `vault status` prints "HA Mode: active", but ha_mode is a field the CLI
# renders for its *text* output — it is not in the JSON. Reading it there
# yields nothing, every node concludes it is not the leader, and no
# snapshot is ever taken anywhere. That is precisely what happened, and
# it looked like success: three green timers, zero backups.
#
# sys/leader is unauthenticated, like sys/health and sys/seal-status, so
# this still runs before any login.
IS_SELF="$(jq -r 'if has("is_self") then .is_self else empty end' <<< "$STATUS_JSON")"

if [[ -z "$IS_SELF" ]]; then
    LEADER_JSON="$(vault read -format=json sys/leader 2>/dev/null || true)"
    # No `//` here either. `.data.is_self // .is_self` looks right and is
    # wrong for the one case that matters: is_self is *false* on a
    # standby, jq's // treats false as empty, so it falls through to null
    # and every standby reads as indeterminate — then takes a snapshot.
    # Same trap as the sealed check above, one screen apart.
    IS_SELF="$(jq -r '
        if (.data | type) == "object" and (.data | has("is_self"))
        then .data.is_self
        elif has("is_self") then .is_self
        else empty end' <<< "${LEADER_JSON:-{\}}" 2>/dev/null || true)"
fi

case "$IS_SELF" in
    true)
        : # this node is the leader; carry on
        ;;
    false)
        log "Node is a standby; the leader takes the snapshot."
        exit 0
        ;;
    *)
        # Indeterminate. Proceed anyway, deliberately: the cost of a
        # redundant snapshot is some storage, and the cost of skipping is
        # no backup at all. This check exists to avoid waste, not to gate
        # correctness, so it fails towards taking one.
        log "WARNING: could not determine leadership from sys/leader."
        log "Taking a snapshot anyway — a redundant snapshot beats none."
        ;;
esac

# ---------------------------------------------------------------------------
# Authenticate
# ---------------------------------------------------------------------------
LOGIN_TOKEN=""

if [[ -n "${VAULT_TOKEN:-}" ]]; then
    log "Using VAULT_TOKEN from the environment."
elif [[ -n "${VAULT_ROLE_ID:-}" && -n "${VAULT_SECRET_ID:-}" ]]; then
    log "Logging in with AppRole..."
    LOGIN_JSON="$(vault write -format=json auth/approle/login \
        role_id="${VAULT_ROLE_ID}" secret_id="${VAULT_SECRET_ID}" 2>/dev/null)" \
        || die "AppRole login failed"
    LOGIN_TOKEN="$(jq -r '.auth.client_token' <<< "$LOGIN_JSON")"
    [[ -n "$LOGIN_TOKEN" && "$LOGIN_TOKEN" != "null" ]] || die "AppRole login returned no token"
    export VAULT_TOKEN="$LOGIN_TOKEN"
else
    die "No credentials: set VAULT_TOKEN, or VAULT_ROLE_ID and VAULT_SECRET_ID"
fi

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------
# A snapshot is the whole of Vault's storage. It is encrypted, but it is
# still the most sensitive file this host will ever hold, so it lands in
# a private directory rather than a world-readable /tmp path.
umask 077
WORK="$(mktemp -d)"

cleanup() {
    local rc=$?
    # Unconditional: on success, on upload failure, on interrupt. A
    # snapshot left behind on an hourly timer fills the disk within days.
    if [[ "$KEEP_LOCAL" == true ]]; then
        log "Leaving ${WORK} in place (--keep-local)."
    else
        rm -rf "$WORK"
    fi
    # Tokens we minted are ours to clean up. A token per hour, never
    # revoked, is a slowly growing pile of live credentials.
    if [[ -n "$LOGIN_TOKEN" ]]; then
        vault token revoke -self >/dev/null 2>&1 || true
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
# The node name is in the filename so that a snapshot can be traced back
# to the leader that took it — useful when reconstructing what happened
# around a failover.
NODE="$(hostname -s 2>/dev/null || hostname)"
NAME="vault-${TIMESTAMP}-${NODE}.snap"
SNAPSHOT="${WORK}/${NAME}"

# ---------------------------------------------------------------------------
# Take it
# ---------------------------------------------------------------------------
log "Taking a Raft snapshot..."
vault operator raft snapshot save "$SNAPSHOT" >/dev/null \
    || die "Snapshot failed"

[[ -f "$SNAPSHOT" ]] || die "Snapshot command succeeded but produced no file"

SIZE="$(wc -c < "$SNAPSHOT" | tr -d '[:space:]')"
[[ "$SIZE" -gt 0 ]] || die "Snapshot is zero bytes — refusing to upload it"

# ---------------------------------------------------------------------------
# Verify it before trusting it
# ---------------------------------------------------------------------------
# `snapshot inspect` reads the archive's metadata and index. It is the
# difference between "a file was produced" and "a file that Vault could
# restore from was produced". Requires Vault 1.11 or newer; this repo
# pins 1.17.
log "Verifying the snapshot..."
vault operator raft snapshot inspect "$SNAPSHOT" >/dev/null 2>&1 \
    || die "Snapshot failed verification — refusing to upload it"

log "Snapshot verified (${SIZE} bytes)."

# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------
case "$CLOUD" in
    aws)
        DEST="s3://${BUCKET}/${PREFIX}/${NAME}"
        log "Uploading to ${DEST}..."
        # Credentials come from the instance role. Server-side encryption
        # and versioning are enforced on the bucket, not requested here,
        # so a caller cannot opt out of them.
        aws s3 cp "$SNAPSHOT" "$DEST" --only-show-errors \
            || die "Upload to ${DEST} failed"
        log "Uploaded ${DEST}"
        ;;

    azure)
        # The node has no Azure CLI — cloud-init installs curl and jq and
        # nothing else, and a Vault node is the last place to start adding
        # package footprint. The blob REST API with a managed-identity
        # bearer token needs neither.
        log "Requesting a managed-identity token..."
        TOKEN_JSON="$(curl -sS --max-time 10 -H "Metadata: true" \
            "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F" \
            2>/dev/null)" || die "Could not reach the instance metadata service"

        ACCESS_TOKEN="$(jq -r '.access_token // empty' <<< "$TOKEN_JSON")"
        [[ -n "$ACCESS_TOKEN" ]] || die "Instance metadata returned no access token"

        DEST="https://${ACCOUNT}.blob.core.windows.net/${CONTAINER}/${PREFIX}/${NAME}"
        log "Uploading to ${DEST}..."

        HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "x-ms-blob-type: BlockBlob" \
            -H "x-ms-version: 2021-08-06" \
            -H "Content-Type: application/octet-stream" \
            --data-binary "@${SNAPSHOT}" \
            "$DEST" 2>/dev/null)" || die "Upload to ${DEST} failed"

        # curl exits 0 on a 403 as happily as on a 201, so the status code
        # is the only thing that actually says the blob was written.
        [[ "$HTTP_CODE" == "201" ]] \
            || die "Upload to ${DEST} returned HTTP ${HTTP_CODE}, expected 201"
        log "Uploaded ${DEST}"
        ;;

    none)
        mkdir -p "$OUTPUT_DIR"
        cp "$SNAPSHOT" "${OUTPUT_DIR}/${NAME}" || die "Could not write to ${OUTPUT_DIR}"
        log "Wrote ${OUTPUT_DIR}/${NAME}"
        log "No retention policy applies to a local directory — prune it yourself."
        ;;
esac
