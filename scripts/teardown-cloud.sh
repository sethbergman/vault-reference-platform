#!/usr/bin/env bash
#
# teardown-cloud.sh — Destroy a cloud profile, including the parts
#                     `terraform destroy` cannot
#
# Usage:
#   ./teardown-cloud.sh --cloud aws|azure [options]
#
# Options:
#   --cloud <aws|azure>  Required.
#   --dir <path>         Terraform directory (default: terraform/<cloud>)
#   --yes                Do not prompt. Intended for scripted teardown.
#   --plan-only          Show what would be destroyed and stop.
#
# WHY THIS EXISTS
#
# `terraform destroy` on these profiles fails, and it fails *after*
# destroying some things — which leaves a half-torn-down deployment
# quietly costing money while looking like it was cleaned up.
#
# AWS: the snapshot bucket has versioning enabled and no force_destroy.
# Once Vault has written a single snapshot, destroy fails with
# BucketNotEmpty. Versioning means deleting the objects is not enough
# either; the delete markers and noncurrent versions have to go too.
#
# Azure: nothing blocks destroy, but the Key Vault does not actually go
# away. purge_protection_enabled is on and cannot be turned off, so the
# vault is soft-deleted for soft_delete_retention_days — 90 by default —
# and cannot be purged before then by anyone, including you. That is
# deliberate (see terraform/azure/main.tf) and it is worth knowing before
# you run this rather than after.
#
# WHAT SURVIVES ON PURPOSE
#
# This script does not try to defeat those protections. It empties what
# is safe to empty, runs destroy, and then reports what is still there
# and why — because a teardown that silently leaves things behind is how
# a test deployment becomes a line item.
#
# Requirements: terraform, and the CLI for the chosen cloud (aws or az).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLOUD=""
TF_DIR=""
ASSUME_YES=false
PLAN_ONLY=false

log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
step() { printf '\n[%s] === %s ===\n' "$(date -u '+%H:%M:%S')" "$*" >&2; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cloud)     CLOUD="$2"; shift 2 ;;
        --dir)       TF_DIR="$2"; shift 2 ;;
        --yes)       ASSUME_YES=true; shift ;;
        --plan-only) PLAN_ONLY=true; shift ;;
        -h|--help)   usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLOUD" ]] || die "--cloud is required (aws or azure)"
case "$CLOUD" in
    aws|azure) ;;
    *) die "--cloud must be aws or azure, got: ${CLOUD}" ;;
esac

[[ -n "$TF_DIR" ]] || TF_DIR="${REPO_ROOT}/terraform/${CLOUD}"
[[ -d "$TF_DIR" ]] || die "No Terraform directory at ${TF_DIR}"

command -v terraform >/dev/null 2>&1 || die "terraform not found on PATH"

tf() { terraform -chdir="$TF_DIR" "$@"; }

# ---------------------------------------------------------------------------
# Is there anything to destroy?
# ---------------------------------------------------------------------------
if ! tf state list >/dev/null 2>&1; then
    log "No Terraform state in ${TF_DIR} — nothing to tear down."
    log "If you applied from somewhere else, point --dir at it."
    exit 0
fi

RESOURCE_COUNT="$(tf state list 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "${RESOURCE_COUNT:-0}" == "0" ]]; then
    log "State exists but holds no resources — nothing to tear down."
    exit 0
fi

log "State holds ${RESOURCE_COUNT} resource(s) in ${TF_DIR}."

if [[ "$PLAN_ONLY" == true ]]; then
    step "What would be destroyed"
    tf plan -destroy -no-color 2>&1 | tail -40 >&2
    log ""
    log "Plan only — nothing was destroyed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------
if [[ "$ASSUME_YES" == false ]]; then
    log ""
    log "About to destroy ${RESOURCE_COUNT} resource(s) in ${CLOUD}."
    log "This is not reversible, and snapshots in the destroyed storage go with it."
    printf 'Type the cloud name to continue: ' >&2
    read -r CONFIRM
    [[ "$CONFIRM" == "$CLOUD" ]] || die "Not confirmed — nothing was destroyed."
fi

# ---------------------------------------------------------------------------
# Clear what blocks destroy
# ---------------------------------------------------------------------------
if [[ "$CLOUD" == "aws" ]]; then
    step "Emptying the snapshot bucket"
    # Versioning is on, so `aws s3 rm --recursive` is not enough: it
    # writes delete markers and leaves noncurrent versions behind, and
    # destroy still fails with BucketNotEmpty. Both have to go.
    if ! command -v aws >/dev/null 2>&1; then
        log "WARNING: aws CLI not found; skipping bucket cleanup."
        log "         terraform destroy will fail on BucketNotEmpty if the"
        log "         bucket holds any snapshot."
    else
        BUCKET="$(tf output -raw vault_snapshot_bucket 2>/dev/null || true)"
        if [[ -z "$BUCKET" ]]; then
            log "No vault_snapshot_bucket output; nothing to empty."
        else
            log "Bucket: ${BUCKET}"
            WORK="$(mktemp -d)"
            trap 'rm -rf "$WORK"' EXIT

            # Both lists matter. `aws s3 rm --recursive` only writes
            # delete markers, which are themselves objects, so the bucket
            # is still not empty and destroy still fails.
            #
            # delete-objects takes at most 1000 keys per call. A test
            # deployment will not reach that, but a long-lived one will,
            # so the loop pages until the listing comes back empty rather
            # than assuming one pass is enough.
            for what in Versions DeleteMarkers; do
                while :; do
                    aws s3api list-object-versions --bucket "$BUCKET" --max-items 1000 \
                        --output json \
                        --query "{Objects: ${what}[].{Key:Key,VersionId:VersionId}}" \
                        > "${WORK}/batch.json" 2>/dev/null || break

                    # An empty listing renders as {"Objects": null}.
                    if grep -q '"Objects": null' "${WORK}/batch.json" 2>/dev/null; then
                        break
                    fi
                    if ! grep -q '"Key"' "${WORK}/batch.json" 2>/dev/null; then
                        break
                    fi

                    N="$(grep -c '"Key"' "${WORK}/batch.json" || true)"
                    log "  deleting ${N} ${what}..."
                    aws s3api delete-objects --bucket "$BUCKET" \
                        --delete "file://${WORK}/batch.json" >/dev/null 2>&1 \
                        || { log "  WARNING: delete-objects failed; destroy will likely fail"; break; }
                done
            done
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Destroy
# ---------------------------------------------------------------------------
step "terraform destroy"
if tf destroy -auto-approve -no-color 2>&1 | tail -30 >&2; then
    log "Destroy completed."
else
    die "Destroy failed. Nothing further was attempted — re-run once the cause is fixed, and check the console for partially destroyed resources."
fi

# ---------------------------------------------------------------------------
# What is still there
# ---------------------------------------------------------------------------
step "What survives, and why"

if [[ "$CLOUD" == "aws" ]]; then
    log "KMS keys: scheduled for deletion, not deleted. There are two,"
    log "and only one of them matters."
    log ""
    log "  <cluster>-vault-autounseal   30 day window"
    log "    The seal key. Vault sealed every snapshot's keyring with it,"
    log "    and the snapshot bucket is encrypted with it. If this key is"
    log "    allowed to delete, every snapshot ever taken with it becomes"
    log "    permanently unreadable -- including snapshots from clusters"
    log "    you tore down months ago. Cancel the deletion if any backup"
    log "    is still meant to be restorable."
    log ""
    log "  <cluster>-vault-data          7 day window"
    log "    Node root volumes only. Those volumes are gone already. There"
    log "    is nothing to recover and nothing to cancel."
    log ""
    log "  Cancel with:"
    log "    aws kms cancel-key-deletion --key-id <key-id>"
else
    log "Key Vault: soft-deleted, and it cannot be purged."
    log "  purge_protection_enabled is on and cannot be turned off, so the"
    log "  vault is retained for soft_delete_retention_days (90 by"
    log "  default) and nobody — including you — can purge it earlier."
    log ""
    log "  That is deliberate: losing the auto-unseal key makes every Raft"
    log "  snapshot permanently undecryptable. It also means each apply of"
    log "  this profile leaves a soft-deleted vault behind for 90 days."
    log "  They count against the subscription's Key Vault quota."
    log ""
    log "  The name carries a random suffix, so re-applying still works."
fi

log ""
log "Check the console before you walk away. A destroy that reported"
log "success can still leave resources it never had in state — anything"
log "created by hand, or by a partial apply that was interrupted."
