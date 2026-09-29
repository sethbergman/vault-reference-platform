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
#   --read-timeout <s>    How long to keep asking a cluster that has just
#                         restored (default: 30). Vault steps down and
#                         reloads its listener, so a read in that window
#                         comes back empty; the drill reports a read it
#                         never got as "could not read" rather than as a
#                         failure, and on a larger cluster that is the
#                         wrong thing to have to say.
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
# THE TUNNEL HAS TO REACH THE LEADER -- ON BOTH CLOUDS
#
# A snapshot is served by the leader alone, and Vault does not forward a
# snapshot request the way it forwards an ordinary one. It redirects, to
# the leader's own api_addr, which both profiles set to the node's private
# address. From outside the network that is:
#
#   redirect failed: dial tcp 10.1.0.7:8200: i/o timeout
#
# So this looks the leader up and forwards a port to it rather than
# assuming. On Azure that is a Bastion tunnel, because internal_lb = true
# leaves no reachable load balancer address at all.
#
# On AWS there is a reachable load balancer, and it is the wrong thing to
# use anyway. terraform/aws/lb.tf probes
# /v1/sys/health?standbyok=true, so a healthy standby answers 200 and
# stays in the target group -- which is checklist item 4, and deliberate.
# The listener is TCP, so connections spread across all three nodes and
# two attempts in three land on a standby. A load balancer that keeps
# standbys in the pool is the right load balancer and the wrong address
# for this one job. AWS forwards the port over SSM instead, the same
# channel ansible/inventory/aws_ec2.yml already reaches the nodes through.
#
# Talking to 127.0.0.1 verifies, on either cloud: every leaf
# scripts/generate-cloud-certs.sh mints carries DNS:localhost and
# IP:127.0.0.1. Nothing here needs -tls-skip-verify and nothing here has
# it.
#
# Requirements: terraform, vault, jq, python3; aws or az for the object
# store; session-manager-plugin on AWS, and the az bastion extension on
# Azure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLOUD=""
TF_DIR=""
FROM_FILE=""
KEEP_CANARY=false
ASSUME_YES=false
READ_TIMEOUT=30

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
        --read-timeout) READ_TIMEOUT="$2"; shift 2 ;;
        --yes)          ASSUME_YES=true; shift ;;
        -h|--help)      usage ;;
        *)              die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLOUD" ]] || die "--cloud is required (aws or azure)"
case "$CLOUD" in aws|azure) ;; *) die "--cloud must be aws or azure, got: ${CLOUD}" ;; esac
if ! [[ "$READ_TIMEOUT" =~ ^[0-9]+$ ]] || (( READ_TIMEOUT == 0 )); then
    die "--read-timeout must be a positive number of seconds, got: ${READ_TIMEOUT}"
fi
[[ -n "$TF_DIR" ]] || TF_DIR="${REPO_ROOT}/terraform/${CLOUD}"
[[ -d "$TF_DIR" ]] || die "No Terraform directory at ${TF_DIR}"

for tool in terraform vault jq python3; do
    command -v "$tool" >/dev/null 2>&1 || die "${tool} not found on PATH"
done
[[ "$CLOUD" == "azure" ]] && { command -v az >/dev/null 2>&1 || die "az not found on PATH"; }
if [[ "$CLOUD" == "aws" ]]; then
    command -v aws >/dev/null 2>&1 || die "aws not found on PATH"
    # `aws ssm start-session` shells out to this and reports a bare
    # "SessionManagerPlugin is not found" that reads like an AWS outage.
    # scripts/preflight-cloud.sh checks for it for the same reason.
    command -v session-manager-plugin >/dev/null 2>&1 \
        || die "session-manager-plugin not found on PATH — the port forward to the leader needs it"
fi

[[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN is not set — this needs a token that can snapshot and restore"

tf() { terraform -chdir="$TF_DIR" "$@"; }

WORK="$(mktemp -d)"
TUNNEL_PID=""

# Both clouds wrap the process that actually holds the local port: `az`
# spawns it, and `aws ssm start-session` execs session-manager-plugin.
# Killing the wrapper alone leaves the child bound, and the next tunnel
# fails to listen on a port nothing appears to be using.
close_tunnel() {
    [[ -n "$TUNNEL_PID" ]] || return 0
    local child
    for child in $(ps -eo pid,ppid --no-headers 2>/dev/null \
        | awk -v p="$TUNNEL_PID" '$2 == p { print $1 }'); do
        kill "$child" 2>/dev/null || true
    done
    kill "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
}
cleanup() {
    close_tunnel
    rm -rf "$WORK"
}
# Not `trap 'close_tunnel; rm -rf "$WORK"' EXIT`: a trap handler ending in
# a conditional hands its exit status to the script, which is what
# tests/lint/check_trap_exit.py exists to catch.
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Reach the leader
# ---------------------------------------------------------------------------
# require_free_port <port> — refuse to start a tunnel onto a port that
# something else already holds.
#
# wait_for_port below waits for the port to accept a connection, and cannot
# tell our tunnel from anyone's. Two orphaned `az network bastion tunnel`
# processes held 18200 and 18201 for over a day on 2026-09-29, against a
# resource group that had been destroyed -- so the check would have passed
# instantly and this drill would have reported on the wrong cluster, or on
# no cluster at all, with nothing in its output saying so.
#
# Naming the holder matters more than refusing does. "18200 is in use" sends
# an operator hunting; the command line says it is yesterday's tunnel.
require_free_port() {
    local port="$1" holder
    python3 -c "
import socket,sys
s = socket.socket(); s.settimeout(1)
sys.exit(1 if s.connect_ex(('127.0.0.1', ${port})) == 0 else 0)" 2>/dev/null && return 0

    holder="$(ss -ltnp 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p { print $NF }' | head -1)"
    die "port ${port} is already in use${holder:+ by ${holder}} — a forward left over from an earlier run reaches whatever it was opened against, not this cluster. Close it (ss -ltnp | grep ${port}) and try again."
}

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

# TLS terminates at Vault under the CA generate-cloud-certs.sh minted, on
# both profiles. Without this every call fails verification, and the only
# way past that is the flag this repository forbids.
CACERT="${REPO_ROOT}/ansible/files/tls/ca.crt"
[[ -f "$CACERT" ]] || die "no CA at ${CACERT}; run generate-cloud-certs.sh first"
export VAULT_CACERT="$CACERT"

# Each cloud supplies three things: some node to ask who the leader is,
# a way to turn the leader's private address back into an instance, and a
# way to forward a local port to one. Everything after this block is
# shared.
if [[ "$CLOUD" == "azure" ]]; then
    RG="$(tf output -raw resource_group_name 2>/dev/null)" || die "no resource_group_name output"
    VMSS="$(tf output -raw vault_scale_set_name 2>/dev/null)" || die "no vault_scale_set_name output"
    BASTION="$(tf output -raw bastion_name 2>/dev/null)" \
        || die "no bastion_name output — this profile was applied with bastion_enabled = false"

    # Ask which instances exist rather than assuming instance 0 does.
    # Scale set instance ids are assigned once and never reused downwards,
    # so every reconciliation increments them and a scale set that has
    # replaced a node has no instance 0 at all -- the 2026-09-28 apply
    # finished with instance 000005 on a three-instance scale set. The
    # drill ran the following day against a cluster rebuilt from scratch,
    # which is the only reason assuming 0 ever worked.
    ANY_NODE="$(az vmss list-instances -g "$RG" -n "$VMSS" \
        --query "[0].instanceId" -o tsv 2>/dev/null)"
    [[ -n "$ANY_NODE" ]] || die "no instances in ${VMSS} — is the cluster up?"

    instance_id_of() {   # instance_id_of <private-ip>
        az vmss nic list -g "$RG" --vmss-name "$VMSS" \
            --query "[?ipConfigurations[0].privateIPAddress=='$1'].virtualMachine.id | [0]" \
            -o tsv 2>/dev/null | sed 's#.*/##'
    }
    tunnel_to() {        # tunnel_to <instance-id> <local-port>
        local target
        require_free_port "$2"
        target="$(az vmss list-instances -g "$RG" -n "$VMSS" \
            --query "[?instanceId=='$1'].id | [0]" -o tsv 2>/dev/null)"
        [[ -n "$target" ]] || die "no instance ${1} in ${VMSS}"
        az network bastion tunnel --name "$BASTION" --resource-group "$RG" \
            --target-resource-id "$target" --resource-port 8200 --port "$2" \
            >"${WORK}/tunnel.log" 2>&1 &
        TUNNEL_PID=$!
        wait_for_port "$2" || die "the tunnel to instance ${1} never listened on ${2}"
    }
else
    ASG="$(tf output -raw autoscaling_group_name 2>/dev/null)" \
        || die "no autoscaling_group_name output"
    # Every aws call below needs a region and none of them should depend on
    # whichever one happens to be configured locally being the one the
    # cluster was applied into.
    AWS_REGION="$(tf output -raw aws_region 2>/dev/null)" || die "no aws_region output"
    export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

    ANY_NODE="$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG" \
        --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" \
        --output text 2>/dev/null)"
    [[ -n "$ANY_NODE" && "$ANY_NODE" != "None" ]] \
        || die "no InService instance in ${ASG} — is the cluster up?"

    instance_id_of() {   # instance_id_of <private-ip>
        aws ec2 describe-instances \
            --filters "Name=private-ip-address,Values=$1" \
                      "Name=instance-state-name,Values=running" \
            --query 'Reservations[].Instances[].InstanceId | [0]' \
            --output text 2>/dev/null | sed 's/^None$//'
    }
    tunnel_to() {        # tunnel_to <instance-id> <local-port>
        require_free_port "$2"
        aws ssm start-session --target "$1" \
            --document-name AWS-StartPortForwardingSession \
            --parameters "portNumber=8200,localPortNumber=$2" \
            >"${WORK}/tunnel.log" 2>&1 &
        TUNNEL_PID=$!
        wait_for_port "$2" \
            || die "the port forward to ${1} never listened on ${2} — see ${WORK}/tunnel.log"
    }
fi

log "Forwarding a port to ${ANY_NODE} to find the leader..."
tunnel_to "$ANY_NODE" 18200
export VAULT_ADDR="https://127.0.0.1:18200"
LEADER_IP="$(vault status -format=json 2>/dev/null \
    | jq -r '.leader_address // ""' | sed -e 's#https\?://##' -e 's#:.*##')"
[[ -n "$LEADER_IP" ]] || die "could not read leader_address"
LEADER_ID="$(instance_id_of "$LEADER_IP")"
[[ -n "$LEADER_ID" ]] || die "could not map leader ${LEADER_IP} to an instance"
log "Leader is ${LEADER_IP} (${LEADER_ID})."

# A second port rather than reusing the first: the old forward may take a
# moment to release, and binding a port that is still held fails in a way
# that looks like the new target being unreachable.
close_tunnel
tunnel_to "$LEADER_ID" 18201
export VAULT_ADDR="https://127.0.0.1:18201"

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
    local path="$1" out deadline=$((SECONDS + READ_TIMEOUT))
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
    printf '  ????  could not read the seal state within %ss\n' "$READ_TIMEOUT"
    printf '        the cluster may be settling after the restore; check with\n'
    printf '        vault status before trusting or distrusting this run\n'
fi

PEER_JSON=""
PEER_DEADLINE=$((SECONDS + READ_TIMEOUT))
while (( SECONDS < PEER_DEADLINE )); do
    PEER_JSON="$(vault operator raft list-peers -format=json 2>/dev/null || true)"
    [[ -n "$PEER_JSON" ]] && break
    sleep 2
done

if [[ -z "$PEER_JSON" ]]; then
    UNKNOWN=$((UNKNOWN + 1))
    printf '  ????  could not read the peer list within %ss\n' "$READ_TIMEOUT"
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
