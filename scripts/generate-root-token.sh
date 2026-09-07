#!/usr/bin/env bash
#
# generate-root-token.sh — Mint a new root token from a quorum of
#                          recovery keys
#
# Usage:
#   ./generate-root-token.sh --keys-file <path>
#   ./generate-root-token.sh --key <share> --key <share> --key <share>
#
# Example, on the local dev profile:
#   ./generate-root-token.sh --keys-file docker/dev/.recovery-keys.json
#
# What it does:
#   1. Cancels any generate-root attempt already in progress.
#   2. Starts one, keeping the one-time password it returns.
#   3. Feeds recovery key shares until the attempt completes.
#   4. Decodes the result with the OTP and prints the token on stdout.
#
# Log messages go to stderr; the token is the only thing on stdout, so
# NEW_ROOT=$(./generate-root-token.sh --keys-file ...) works.
#
# WHY THIS EXISTS
#
# It is the other half of revoke-root-token.sh. Retiring the root token
# is only reasonable if getting one back is a known procedure rather than
# an emergency, and the ceremony is fiddly enough -- a nonce, an OTP, one
# call per share, a decode step -- that doing it from memory during an
# incident is how people decide to keep the root token instead.
#
# WITH AUTO-UNSEAL, THESE ARE RECOVERY KEYS, NOT UNSEAL KEYS
#
# A cluster with a seal stanza unseals itself; `operator init` returns
# recovery keys instead, and they exist for exactly this and for rekey.
# scripts/bootstrap-dev-cluster.sh writes them to
# docker/dev/.recovery-keys.json -- it used to discard them, which made
# revoking the root token a one-way door.
#
# In a real deployment the shares are split between people and this
# script takes --key repeatedly, one share per holder, rather than
# reading a file that contains a quorum by itself. --keys-file exists
# because the dev profile has no second person.
#
# Requirements: vault CLI, jq, VAULT_ADDR. No token: that is the point.

set -euo pipefail

KEYS_FILE=""
KEYS=()
VAULT_ADDR="${VAULT_ADDR:-}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keys-file)   KEYS_FILE="$2"; shift 2 ;;
        --key)         KEYS+=("$2"); shift 2 ;;
        --vault-addr)  VAULT_ADDR="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
[[ -n "$VAULT_ADDR" ]] || die "VAULT_ADDR is not set"
export VAULT_ADDR

# The ceremony authenticates with key shares, not with a token. A token
# left in the environment does nothing here, and unsetting it stops a
# stale one from making an unrelated error look like a key problem.
unset VAULT_TOKEN

if [[ -n "$KEYS_FILE" ]]; then
    [[ ${#KEYS[@]} -eq 0 ]] || die "--keys-file and --key are alternatives, not both"
    [[ -f "$KEYS_FILE" ]] || die "no such file: ${KEYS_FILE}"
    mapfile -t KEYS < <(jq -r '.recovery_keys_b64[]' "$KEYS_FILE" 2>/dev/null)
    [[ ${#KEYS[@]} -gt 0 ]] || die "no recovery_keys_b64 found in ${KEYS_FILE}"
fi

[[ ${#KEYS[@]} -gt 0 ]] || die "supply shares with --key, or a file with --keys-file"

# ---------------------------------------------------------------------------
# Step 1: start clean
# ---------------------------------------------------------------------------
# An attempt left half-finished by someone else -- or by a previous run
# of this script that died -- makes every share below fail with a nonce
# mismatch, which reads as "the keys are wrong".
vault operator generate-root -cancel >/dev/null 2>&1 || true

INIT_JSON="$(vault operator generate-root -init -format=json 2>&1)" \
    || die "could not start a generate-root attempt: ${INIT_JSON}"

NONCE="$(jq -r '.nonce // empty' <<< "$INIT_JSON")"
OTP="$(jq -r '.otp // empty' <<< "$INIT_JSON")"
[[ -n "$NONCE" && -n "$OTP" ]] || die "generate-root -init did not return a nonce and OTP: ${INIT_JSON}"

log "Started a generate-root attempt (nonce ${NONCE})."

# ---------------------------------------------------------------------------
# Step 2: feed shares until it completes
# ---------------------------------------------------------------------------
ENCODED=""
USED=0
for KEY in "${KEYS[@]}"; do
    [[ -n "$KEY" ]] || continue
    OUT="$(vault operator generate-root -nonce="$NONCE" -format=json "$KEY" 2>&1)" || {
        vault operator generate-root -cancel >/dev/null 2>&1 || true
        die "a recovery key share was rejected: ${OUT}"
    }
    USED=$((USED + 1))
    if [[ "$(jq -r '.complete // false' <<< "$OUT")" == "true" ]]; then
        ENCODED="$(jq -r '.encoded_token // empty' <<< "$OUT")"
        break
    fi
done

if [[ -z "$ENCODED" ]]; then
    vault operator generate-root -cancel >/dev/null 2>&1 || true
    die "ran out of shares after ${USED} without reaching the threshold"
fi

log "Threshold reached after ${USED} shares."

# ---------------------------------------------------------------------------
# Step 3: decode
# ---------------------------------------------------------------------------
# The encoded token is useless without the OTP from step 1, which is why
# the OTP never leaves this process: it is what stops a share holder who
# watched the ceremony from walking away with the token.
NEW_ROOT="$(vault operator generate-root -decode="$ENCODED" -otp="$OTP" -format=json 2>&1 | jq -r '.token // empty')"
[[ -n "$NEW_ROOT" ]] || die "the encoded token could not be decoded with the OTP"

if ! VAULT_TOKEN="$NEW_ROOT" vault token lookup -format=json 2>/dev/null \
        | jq -e '.data.policies | index("root")' >/dev/null 2>&1; then
    die "a token was produced but it does not carry the root policy"
fi

log "A new root token has been generated and verified."
log "Revoke it when the task that needed it is done:"
log "  ./scripts/revoke-root-token.sh --verify-with <a non-root token>"

printf '%s\n' "$NEW_ROOT"
