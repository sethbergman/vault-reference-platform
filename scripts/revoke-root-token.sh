#!/usr/bin/env bash
#
# revoke-root-token.sh — Give up the root token, once something else can
#                        administer the cluster
#
# Usage:
#   ./revoke-root-token.sh --verify-with <non-root-token> [options]
#
# Example:
#   SECRET_ID=$(./rotate-secret-id.sh --role admin)
#   TOKEN=$(vault write -field=token auth/approle/login \
#       role_id=... secret_id="$SECRET_ID")
#   ./revoke-root-token.sh --verify-with "$TOKEN"
#
# What it does:
#   1. Checks the token in --verify-with works and is NOT a root token.
#   2. Checks it carries a policy of its own, so it is a token somebody
#      configured rather than merely a token that authenticates.
#   3. Revokes the root token in VAULT_TOKEN.
#   4. Confirms the root token no longer works.
#
# WHY THIS EXISTS
#
# `vault operator init` mints a root token because a new cluster has no
# other way in. Once auth methods are configured it is a standing
# credential that answers to no policy, expires at no time, and appears
# in every shell history that ever exported it. Vault's own guidance is
# to revoke it and generate a new one on demand.
#
# This repository was silent on that, which for a security reference is
# not neutral -- it reads as "keep it", which is a recommendation nobody
# meant to make.
#
# WHY IT REFUSES WITHOUT --verify-with
#
# Revoking root when nothing else can administer the cluster is a
# lock-out, and the fix is a quorum of recovery-key holders in a room.
# Requiring a working non-root token first turns "I think AppRole is
# configured" into "here is a token that proves it".
#
# The check is deliberately two-part. A token that exists is not the same
# as a token that can do anything, and `token lookup-self` succeeds for a
# token with no policies at all.
#
# The second part used to read sys/health, which is unauthenticated and
# therefore answered for any token at all. It checked nothing, which a
# review caught before this shipped.
#
# GETTING BACK IN
#
# You can always mint a new root token with a quorum of recovery keys:
# scripts/generate-root-token.sh does the ceremony. That is the point --
# root becomes something you generate for a task and revoke afterwards,
# rather than something that sits in a password manager forever.
#
# Requirements:
#   - vault CLI on PATH, VAULT_ADDR set
#   - VAULT_TOKEN set to the root token being revoked

set -euo pipefail

VERIFY_TOKEN=""
FORCE=false
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify-with) VERIFY_TOKEN="$2"; shift 2 ;;
        --vault-addr)  VAULT_ADDR="$2"; shift 2 ;;
        --vault-token) VAULT_TOKEN="$2"; shift 2 ;;
        --force)       FORCE=true; shift ;;
        -h|--help)     usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
[[ -n "$VAULT_ADDR" ]]  || die "VAULT_ADDR is not set"
[[ -n "$VAULT_TOKEN" ]] || die "VAULT_TOKEN is not set — it must be the root token to revoke"

export VAULT_ADDR VAULT_TOKEN

# ---------------------------------------------------------------------------
# Step 0: is the token we are about to revoke actually root?
# ---------------------------------------------------------------------------
SELF="$(vault token lookup -format=json 2>/dev/null)" \
    || die "VAULT_TOKEN does not work, so there is nothing here to revoke"

if ! jq -e '.data.policies | index("root")' <<< "$SELF" >/dev/null 2>&1; then
    die "VAULT_TOKEN is not a root token. This script exists to retire the root token specifically; revoking an ordinary token is 'vault token revoke'."
fi

# ---------------------------------------------------------------------------
# Step 1: prove there is another way in
# ---------------------------------------------------------------------------
if [[ "$FORCE" != true ]]; then
    [[ -n "$VERIFY_TOKEN" ]] || die "--verify-with <token> is required: a working non-root token, so that revoking root is not a lock-out. Use --force only if you hold a quorum of recovery keys and mean to be locked out until you use them."

    VERIFY_JSON="$(VAULT_TOKEN="$VERIFY_TOKEN" vault token lookup -format=json 2>/dev/null)" \
        || die "the --verify-with token does not work, so revoking root would leave no way in"

    if jq -e '.data.policies | index("root")' <<< "$VERIFY_JSON" >/dev/null 2>&1; then
        die "the --verify-with token is itself a root token, which proves nothing about life after root"
    fi

    # Existing is not the same as useful. A token with no policies passes
    # lookup-self and can do nothing at all.
    #
    # This used to check `vault read sys/health`, which proves nothing:
    # sys/health is unauthenticated -- bootstrap-dev-cluster.sh polls it
    # with plain curl and no token at all -- so it answers for an expired
    # token, a revoked one, or one entitled to nothing. It passed exactly
    # when the lookup above already had: a guard that could not fail,
    # standing in front of the one outcome it exists to prevent.
    #
    # A policy of its own is the weakest honest signal. It does not prove
    # the token can do the specific thing needed next -- nothing here can
    # know what that is -- but it separates a token someone configured
    # from one that merely authenticates.
    NON_DEFAULT="$(jq -r '[.data.policies[]? | select(. != "default")] | length' <<< "$VERIFY_JSON")"
    [[ "${NON_DEFAULT:-0}" -gt 0 ]] \
        || die "the --verify-with token carries no policy beyond 'default', so it can administer nothing and revoking root would lock you out"

    log "Note: this proves the token is live and carries a policy of its"
    log "      own. It does not prove that policy grants what you will"
    log "      need tomorrow -- check that before you rely on it."

    log "Verified: a non-root token works and can reach the cluster."
    log "  policies: $(jq -r '.data.policies | join(", ")' <<< "$VERIFY_JSON")"
fi

# ---------------------------------------------------------------------------
# Step 2: revoke
# ---------------------------------------------------------------------------
log "Revoking the root token..."
vault token revoke -self || die "the revoke call failed"

# ---------------------------------------------------------------------------
# Step 3: confirm it is actually gone
# ---------------------------------------------------------------------------
# A revoke that reported success and left the token working is the
# failure this repository is arranged around. Ask.
if vault token lookup >/dev/null 2>&1; then
    die "the root token still works after being revoked"
fi

log "The root token is revoked and no longer valid."
log ""
log "To get a root token back, you need a quorum of recovery keys:"
log "  ./scripts/generate-root-token.sh"
log ""
log "That is the intended shape: root is generated for a task and revoked"
log "afterwards, rather than kept."
