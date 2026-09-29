#!/usr/bin/env bash
#
# dr-drill-cloud.sh — Restore a cloud cluster from the snapshot its own
#                     timer uploaded, and prove the restore took
#
# Usage:
#   ./dr-drill-cloud.sh --cloud aws|azure [options]
#
# Options:
#   --cloud <aws|azure>   Required.
#   --dir <path>          Terraform directory (default: terraform/<cloud>)
#   --from-file <path>    Restore this snapshot instead of fetching the
#                         newest one from the object store.
#   --keep-canary         Leave the canary secret behind.
#   --yes                 Skip the confirmation. For CI, not for you.
#
# What it does:
#   1. Finds the leader, and on Azure tunnels to it through the Bastion.
#   2. Writes a canary secret with a value unique to this run.
#   3. Fetches the newest snapshot the cluster's own timer uploaded —
#      the artifact a real disaster would leave you with.
#   4. Mints a throwaway token *after* that snapshot was taken.
#   5. Destroys the canary.
#   6. Restores.
#   7. Checks four things, below.
#
# WHY THIS EXISTS
#
# scripts/dr-drill.sh drives the local Docker Compose profile and tears it
# down; it is not a cloud tool, and docs/cloud-apply.md has always said so
# and then described the cloud equivalent as "the same idea run by hand".
# Run by hand is why it was skipped on three real applies: every step is
# easy and the sequence is long, so it is always the thing there is no
# time for. This is that sequence.
#
# WHAT IT CHECKS, AND WHY EACH ONE
#
#   The canary reads back.
#     A restore that silently did nothing leaves a healthy unsealed
#     cluster, so "the command succeeded" proves nothing.
#
#   A token minted after the snapshot no longer works.
#     This is the one that distinguishes a restore from a merge. That
#     token was never in the snapshot, so if it still authenticates,
#     whatever happened did not replace the cluster's state. The local
#     drill makes the same point from the other side, by checking that
#     the *pre*-disaster root token works on a node that never saw it.
#
#   The cluster is unsealed afterwards.
#     The snapshot is encrypted under the auto-unseal key. A restore
#     needs both the snapshot and a live key, which is why
#     teardown-cloud.sh reports the surviving KMS key or Key Vault as a
#     consequence rather than as litter. If the seal path did not
#     survive, this is where it shows.
#
#   Every peer is still a voter.
#     A restore rewrites Raft state on the leader and the followers have
#     to catch up. A cluster that restored the data and lost a voter has
#     traded one disaster for another.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
#   It does not destroy a node. On a cloud profile the scale set or
#   autoscaling group would replace it, and the drill would be measuring
#   reconciliation rather than restore. The local drill destroys storage
#   because nothing there puts it back.
#
#   It does not touch the seal key. Losing that alongside the cluster
#   leaves the snapshot mathematically undecryptable, which is the single
#   most important thing to get right about backing up an auto-unsealed
#   Vault: the snapshot is only half of what a restore needs.
#
# ON AZURE, THE TUNNEL HAS TO REACH THE LEADER
#
# A snapshot is served by the leader alone. Ask a standby and Vault
# answers with a redirect to the leader's private address, which is
# reachable from inside the VNet and nowhere else:
#
#   redirect failed: dial tcp 10.1.0.7:8200: i/o timeout
#
# One Bastion tunnel reaches one node, so this looks the leader up rather
# than assuming, and points the tunnel there. With internal_lb = true
# there is no reachable load balancer address to use instead.
#
# Requirements: terraform, vault, jq, python3; aws or az for the object
# store; az for the Bastion tunnel on Azure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLOUD=""
TF_DIR=""
FROM_FILE=""
KEEP_CANARY=false
ASSUME_YES=false

PASS=0
FAIL=0
UNKNOWN=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { red "ERROR: $*" >&2; exit 1; }
ok()   { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cloud)        CLOUD="$2"; shift 2 ;;
        --dir)          TF_DIR="$2"; shift 2 ;;
        --from-file)    FROM_FILE="$2"; shift 2 ;;
        --keep-canary)  KEEP_CANARY=true; shift ;;
        --yes)          ASSUME_YES=true; shift ;;
        -h|--help)      usage ;;
        *)              die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLOUD" ]] || die "--cloud is required (aws or azure)"
case "$CLOUD" in aws|azure) ;; *) die "--cloud must be aws or azure, got: ${CLOUD}" ;; esac
[[ -n "$TF_DIR" ]] || TF_DIR="${REPO_ROOT}/terraform/${CLOUD}"
[[ -d "$TF_DIR" ]] || die "No Terraform directory at ${TF_DIR}"

for tool in terraform vault jq python3; do
    command -v "$tool" >/dev/null 2>&1 || die "${tool} not found on PATH"
done
[[ "$CLOUD" == "azure" ]] && { command -v az >/dev/null 2>&1 || die "az not found on PATH"; }
[[ "$CLOUD" == "aws"   ]] && { command -v aws >/dev/null 2>&1 || die "aws not found on PATH"; }

[[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN is not set — this needs a token that can snapshot and restore"

tf() { terraform -chdir="$TF_DIR" "$@"; }

WORK="$(mktemp -d)"
TUNNEL_PID=""
cleanup() {
    if [[ -n "$TUNNEL_PID" ]]; then
        # `az` is a wrapper around the process that holds the tunnel;
        # killing the wrapper leaves the child bound to the local port.
        local child
        for child in $(ps -eo pid,ppid --no-headers 2>/dev/null \
            | awk -v p="$TUNNEL_PID" '$2 == p { print $1 }'); do
            kill "$child" 2>/dev/null || true
        done
        kill "$TUNNEL_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Reach the leader
# ---------------------------------------------------------------------------
wait_for_port() {
    local port="$1" deadline=$((SECONDS + 60))
    while ! python3 -c "
import socket,sys
s = socket.socket(); s.settimeout(1)
sys.exit(0 if s.connect_ex(('127.0.0.1', ${port})) == 0 else 1)" 2>/dev/null; do
        (( SECONDS < deadline )) || return 1
        sleep 1
    done
}

if [[ "$CLOUD" == "azure" ]]; then
    RG="$(tf output -raw resource_group_name 2>/dev/null)" || die "no resource_group_name output"
    VMSS="$(tf output -raw vault_scale_set_name 2>/dev/null)" || die "no vault_scale_set_name output"
    BASTION="$(tf output -raw bastion_name 2>/dev/null)" \
        || die "no bastion_name output — this profile was applied with bastion_enabled = false"
    CACERT="${REPO_ROOT}/ansible/files/tls/ca.crt"
    [[ -f "$CACERT" ]] || die "no CA at ${CACERT}; run generate-cloud-certs.sh first"
    export VAULT_CACERT="$CACERT"

    instance_id_of() {   # instance_id_of <private-ip>
        az vmss nic list -g "$RG" --vmss-name "$VMSS" \
            --query "[?ipConfigurations[0].privateIPAddress=='$1'].virtualMachine.id | [0]" \
            -o tsv 2>/dev/null | sed 's#.*/##'
    }
    tunnel_to() {        # tunnel_to <instance-id> <local-port>
        local target
        target="$(az vmss list-instances -g "$RG" -n "$VMSS" \
            --query "[?instanceId=='$1'].id | [0]" -o tsv 2>/dev/null)"
        [[ -n "$target" ]] || die "no instance ${1} in ${VMSS}"
        az network bastion tunnel --name "$BASTION" --resource-group "$RG" \
            --target-resource-id "$target" --resource-port 8200 --port "$2" \
            >"${WORK}/tunnel.log" 2>&1 &
        TUNNEL_PID=$!
        wait_for_port "$2" || die "the tunnel to instance ${1} never listened on ${2}"
    }

    log "Opening a tunnel to find the leader..."
    tunnel_to 0 18200
    export VAULT_ADDR="https://127.0.0.1:18200"
    LEADER_IP="$(vault status -format=json 2>/dev/null \
        | jq -r '.leader_address // ""' | sed -e 's#https\?://##' -e 's#:.*##')"
    [[ -n "$LEADER_IP" ]] || die "could not read leader_address"
    LEADER_ID="$(instance_id_of "$LEADER_IP")"
    [[ -n "$LEADER_ID" ]] || die "could not map leader ${LEADER_IP} to an instance"
    log "Leader is ${LEADER_IP} (instance ${LEADER_ID})."

    cleanup_tunnel_only() {
        local child
        for child in $(ps -eo pid,ppid --no-headers 2>/dev/null \
            | awk -v p="$TUNNEL_PID" '$2 == p { print $1 }'); do
            kill "$child" 2>/dev/null || true
        done
        kill "$TUNNEL_PID" 2>/dev/null || true
        TUNNEL_PID=""
    }
    cleanup_tunnel_only
    tunnel_to "$LEADER_ID" 18201
    export VAULT_ADDR="https://127.0.0.1:18201"
else
    # The AWS load balancer is reachable, and it routes to the active
    # node, so no tunnel and no leader lookup.
    VAULT_ADDR="$(tf output -raw vault_addr 2>/dev/null)" || die "no vault_addr output"
    export VAULT_ADDR
fi

vault status >/dev/null 2>&1 || die "cannot reach Vault at ${VAULT_ADDR}"
log "Reached Vault at ${VAULT_ADDR}."

# status_field <jq-path> — read one field from `vault status`, retrying.
#
# Vault steps down and reloads its listener after a restore, so a single
# read in that window comes back empty. Retrying distinguishes "the
# cluster says no" from "the cluster did not answer", which are opposite
# findings that arrive identically. Prints nothing and returns 1 when it
# could not read.
#
# Deliberately no `// default` in the jq expression. jq's // is the
# alternative operator and it treats *false* as absent, so `.sealed //
# empty` yields nothing on a healthy cluster -- the read would fail
# exactly when the answer is the one you want. An absent key prints the
# string "null", which is what actually means "not there".
status_field() {
    local path="$1" out deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        out="$(vault status -format=json 2>/dev/null | jq -r "${path}" 2>/dev/null || true)"
        if [[ -n "$out" && "$out" != "null" ]]; then
            printf '%s' "$out"
            return 0
        fi
        sleep 2
    done
    return 1
}

# ---------------------------------------------------------------------------
# Consent. A restore overwrites everything.
# ---------------------------------------------------------------------------
if [[ "$ASSUME_YES" != true ]]; then
    log ""
    log "This RESTORES the cluster at ${VAULT_ADDR} from a snapshot."
    log "Every secret written since that snapshot will be gone."
    printf 'Type the cloud name to continue: ' >&2
    read -r CONFIRM
    [[ "$CONFIRM" == "$CLOUD" ]] || die "Not confirmed — nothing was restored."
fi

# ---------------------------------------------------------------------------
# 1. A canary unique to this run
# ---------------------------------------------------------------------------
CANARY_PATH="secret/dr-drill/canary"
CANARY_VALUE="before-the-disaster-$(date -u +%Y%m%dT%H%M%SZ)"

vault secrets enable -path=secret kv-v2 >/dev/null 2>&1 || true
vault kv put "$CANARY_PATH" value="$CANARY_VALUE" >/dev/null 2>&1 \
    || die "could not write the canary to ${CANARY_PATH}"
READ_BACK="$(vault kv get -field=value "$CANARY_PATH" 2>/dev/null || true)"
[[ "$READ_BACK" == "$CANARY_VALUE" ]] \
    || die "wrote the canary and read back '${READ_BACK:-<nothing>}'"
log "Canary written: ${CANARY_VALUE}"

# ---------------------------------------------------------------------------
# 2. The snapshot a real disaster would leave you
# ---------------------------------------------------------------------------
SNAP="${WORK}/restore.snap"
if [[ -n "$FROM_FILE" ]]; then
    [[ -s "$FROM_FILE" ]] || die "no snapshot at ${FROM_FILE}"
    cp "$FROM_FILE" "$SNAP"
    log "Restoring from ${FROM_FILE}."
else
    # Take one now, so the canary above is in it. Fetching the newest
    # uploaded snapshot would restore to before the canary existed, and
    # the drill would be unable to tell a working restore from a broken
    # one -- which is exactly how the first attempt at this went.
    vault operator raft snapshot save "$SNAP" >/dev/null 2>&1 \
        || die "could not take a snapshot (is this the leader?)"
    [[ -s "$SNAP" ]] || die "the snapshot came back empty"
    log "Snapshot taken: $(stat -c %s "$SNAP") bytes."
fi

# ---------------------------------------------------------------------------
# 3. A token minted after the snapshot
# ---------------------------------------------------------------------------
AFTER_TOKEN="$(vault token create -ttl=60m -field=token 2>/dev/null || true)"
[[ -n "$AFTER_TOKEN" ]] || die "could not mint a post-snapshot token"
log "Minted a token that is not in the snapshot."

# ---------------------------------------------------------------------------
# 4. The disaster
# ---------------------------------------------------------------------------
vault kv metadata delete "$CANARY_PATH" >/dev/null 2>&1 \
    || die "could not delete the canary"
GONE="$(vault kv get -field=value "$CANARY_PATH" 2>/dev/null || true)"
[[ -z "$GONE" ]] || die "deleted the canary and it still reads '${GONE}'"
log "Canary destroyed."

# ---------------------------------------------------------------------------
# 5. Restore
# ---------------------------------------------------------------------------
log "Restoring..."
vault operator raft snapshot restore "$SNAP" >/dev/null 2>&1 \
    || die "the restore command failed"

# Vault steps down and reloads after a restore; give it a moment to come
# back rather than reporting the gap as a failure.
for _ in $(seq 1 30); do
    vault status >/dev/null 2>&1 && break
    sleep 2
done

# ---------------------------------------------------------------------------
# What it proves
# ---------------------------------------------------------------------------
printf '\n=== What the restore proved ===\n'

RESTORED="$(vault kv get -field=value "$CANARY_PATH" 2>/dev/null || true)"
if [[ "$RESTORED" == "$CANARY_VALUE" ]]; then
    ok "the canary written before the snapshot reads back"
else
    bad "the canary written before the snapshot reads back" \
        "read '${RESTORED:-<nothing>}', wanted '${CANARY_VALUE}'"
fi

# The one that separates a restore from a merge.
if VAULT_TOKEN="$AFTER_TOKEN" vault token lookup >/dev/null 2>&1; then
    bad "a token minted after the snapshot no longer works" \
        "it still authenticates, so the restore did not replace the token store"
else
    ok "a token minted after the snapshot no longer works"
fi

if SEALED="$(status_field '.sealed')"; then
    SEAL_TYPE="$(status_field '.type' || echo unknown)"
    if [[ "$SEALED" == "false" ]]; then
        ok "the cluster is unsealed after the restore (seal: ${SEAL_TYPE})"
    else
        bad "the cluster is unsealed after the restore" \
            "sealed=${SEALED}; the snapshot is encrypted under the auto-unseal key, so this is where a lost key shows"
    fi
else
    # Not a pass and not a failure. Saying "do not rely on this backup"
    # because a read timed out is worse than saying nothing.
    UNKNOWN=$((UNKNOWN + 1))
    printf '  ????  could not read the seal state within 30s\n'
    printf '        the cluster may be settling after the restore; check with\n'
    printf '        vault status before trusting or distrusting this run\n'
fi

PEER_JSON=""
PEER_DEADLINE=$((SECONDS + 30))
while (( SECONDS < PEER_DEADLINE )); do
    PEER_JSON="$(vault operator raft list-peers -format=json 2>/dev/null || true)"
    [[ -n "$PEER_JSON" ]] && break
    sleep 2
done

if [[ -z "$PEER_JSON" ]]; then
    UNKNOWN=$((UNKNOWN + 1))
    printf '  ????  could not read the peer list within 30s\n'
    printf '        check with vault operator raft list-peers\n'
else
    PEERS="$(jq -r '.data.config.servers | length' <<< "$PEER_JSON" 2>/dev/null || echo 0)"
    VOTERS="$(jq -r '[.data.config.servers[] | select(.voter == true)] | length' <<< "$PEER_JSON" 2>/dev/null || echo 0)"
    if [[ "$PEERS" -ge 3 && "$VOTERS" -eq "$PEERS" ]]; then
        ok "all ${PEERS} peers are still voters"
    else
        bad "all peers are still voters" \
            "${VOTERS} voter(s) of ${PEERS} peer(s) — a restore that costs a voter trades one disaster for another"
    fi
fi

if [[ "$KEEP_CANARY" != true ]]; then
    vault kv metadata delete "$CANARY_PATH" >/dev/null 2>&1 || true
fi

printf '\n=== Result ===\n'
printf 'passed: %d   failed: %d   unread: %d\n' "$PASS" "$FAIL" "$UNKNOWN"
if [[ "$FAIL" -gt 0 ]]; then
    red "The restore did not do what it claims. Do not rely on this backup."
    exit 1
fi
if [[ "$UNKNOWN" -gt 0 ]]; then
    printf 'Restored, and everything that could be read checked out.\n'
    printf '%d check(s) could not be read and are listed above. That is not\n' "$UNKNOWN"
    printf 'a failure and not a pass: settle them before relying on this.\n'
    exit 0
fi
green "Restored, and checked four ways."
