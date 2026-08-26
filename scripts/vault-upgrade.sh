#!/usr/bin/env bash
#
# vault-upgrade.sh — Rolling upgrade of an HA Vault cluster
#
# Usage:
#   ./vault-upgrade.sh <download-url> [options]
#
# Example:
#   ./vault-upgrade.sh https://releases.hashicorp.com/vault/1.17.2/vault_1.17.2_linux_amd64.zip \
#       --nodes vault-node-1,vault-node-2,vault-node-3 \
#       --ssh-user deploy \
#       --sha256 abc123...  (recommended — see: https://releases.hashicorp.com/vault/1.17.2/vault_1.17.2_SHA256SUMS)
#
# What it does, per node, one at a time:
#   1. Downloads the release archive from the given URL
#   2. Verifies the archive is a valid zip, optionally checks its SHA256
#      checksum against --sha256, then extracts the vault binary
#   3. If the node is the current active (leader) node, steps it down first
#      so it becomes a standby before being touched
#   4. Stops the vault service, swaps the binary, restarts the service
#   5. Waits for the node to report healthy (initialized, unsealed) before
#      moving to the next node
#   6. Aborts the whole run if any node fails to come back healthy —
#      it will NOT continue upgrading remaining nodes in that case
#
# Checksum verification (--sha256) is optional but strongly recommended.
# Without it, the script has no way to detect a corrupted download or a
# tampered artifact before installing it across the cluster. HashiCorp
# publishes a SHA256SUMS file alongside every release — copy the hash for
# your platform's archive from there.
#
# Requirements on the machine running this script:
#   - bash, curl, unzip, ssh, jq, sha256sum
#   - SSH key-based access to every node in --nodes
#   - The remote user must be able to sudo systemctl for the vault service
#
# Requirements on each Vault node:
#   - Vault installed as a systemd service named "vault"
#   - Vault binary at /usr/local/bin/vault (override with --binary-path)
#   - VAULT_ADDR reachable locally on each node for health checks

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
NODES=""
# $USER is not always exported — CI runners, containers and cron often
# have no login shell to set it, and `set -u` turns that into an immediate
# crash before the script does anything. Fall back to the real uid.
SSH_USER="${USER:-$(id -un 2>/dev/null || echo root)}"
SSH_KEY=""
BINARY_PATH="/usr/local/bin/vault"
SERVICE_NAME="vault"
VAULT_ADDR="https://127.0.0.1:8200"
HEALTH_TIMEOUT=120        # seconds to wait for a node to come back healthy
HEALTH_INTERVAL=5         # seconds between health checks
SKIP_TLS_VERIFY=false
EXPECTED_SHA256=""
WORKDIR=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

cleanup() {
    # See oidc-login-test.sh: a trailing `&&` that evaluates false makes
    # this return 1, which bash applies to the script's exit status from
    # an EXIT trap. WORKDIR is empty until it is created, so any future
    # "nothing to upgrade, exit 0" path would report failure instead.
    if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

curl_opts=(-fsSL)

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
[[ $# -lt 1 ]] && usage

DOWNLOAD_URL="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)            NODES="$2"; shift 2 ;;
        --ssh-user)          SSH_USER="$2"; shift 2 ;;
        --ssh-key)           SSH_KEY="$2"; shift 2 ;;
        --binary-path)       BINARY_PATH="$2"; shift 2 ;;
        --service-name)      SERVICE_NAME="$2"; shift 2 ;;
        --vault-addr)        VAULT_ADDR="$2"; shift 2 ;;
        --health-timeout)    HEALTH_TIMEOUT="$2"; shift 2 ;;
        --skip-tls-verify)   SKIP_TLS_VERIFY=true; shift ;;
        --sha256)             EXPECTED_SHA256="$2"; shift 2 ;;
        -h|--help)           usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -z "$NODES" ]] && die "--nodes is required, e.g. --nodes host1,host2,host3"
[[ "$SKIP_TLS_VERIFY" == true ]] && curl_opts+=(-k)
if [[ -z "$EXPECTED_SHA256" ]]; then
    log "WARNING: --sha256 not provided — skipping checksum verification. This is not recommended for production upgrades."
fi

IFS=',' read -r -a NODE_LIST <<< "$NODES"
[[ ${#NODE_LIST[@]} -lt 1 ]] && die "No nodes parsed from --nodes"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

remote() {
    local host="$1"; shift
    # Callers pass an already-composed command string with local variables
    # (e.g. $VAULT_ADDR) that are meant to expand here, before it reaches ssh.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

# ---------------------------------------------------------------------------
# Step 1: Download and stage the new binary locally, then verify it
# ---------------------------------------------------------------------------
WORKDIR="$(mktemp -d)"
ARCHIVE_PATH="${WORKDIR}/vault_upgrade.zip"

log "Downloading Vault release from: ${DOWNLOAD_URL}"
curl "${curl_opts[@]}" -o "$ARCHIVE_PATH" "$DOWNLOAD_URL" \
    || die "Failed to download archive from ${DOWNLOAD_URL}"

file "$ARCHIVE_PATH" | grep -qi 'zip archive' \
    || die "Downloaded file does not look like a valid zip archive — refusing to proceed"

if [[ -n "$EXPECTED_SHA256" ]]; then
    log "Verifying SHA256 checksum"
    ACTUAL_SHA256="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
    # Normalize case for comparison since some SHA256SUMS files use uppercase
    if [[ "${ACTUAL_SHA256,,}" != "${EXPECTED_SHA256,,}" ]]; then
        die "Checksum mismatch — refusing to install. Expected ${EXPECTED_SHA256}, got ${ACTUAL_SHA256}. The download may be corrupted or tampered with."
    fi
    log "Checksum verified OK (${ACTUAL_SHA256})"
fi

log "Extracting archive"
unzip -o -q "$ARCHIVE_PATH" -d "$WORKDIR" \
    || die "Failed to extract archive"

[[ -f "${WORKDIR}/vault" ]] || die "No 'vault' binary found inside the downloaded archive"
chmod +x "${WORKDIR}/vault"

NEW_VERSION="$("${WORKDIR}/vault" version 2>/dev/null | head -n1 || true)"
log "Staged binary reports version: ${NEW_VERSION:-unknown}"

# ---------------------------------------------------------------------------
# Health check helper — polls a node until it reports initialized+unsealed
# ---------------------------------------------------------------------------
wait_for_healthy() {
    local host="$1"
    local waited=0
    log "  Waiting for ${host} to report healthy (timeout ${HEALTH_TIMEOUT}s)..."
    while (( waited < HEALTH_TIMEOUT )); do
        if remote "$host" "curl -fsSk -o /dev/null -w '%{http_code}' ${VAULT_ADDR}/v1/sys/health" 2>/dev/null \
            | grep -qE '^(200|429|472|473)$'; then
            log "  ${host} is healthy."
            return 0
        fi
        sleep "$HEALTH_INTERVAL"
        waited=$(( waited + HEALTH_INTERVAL ))
    done
    return 1
}

is_leader() {
    local host="$1"
    remote "$host" "curl -fsSk ${VAULT_ADDR}/v1/sys/leader" 2>/dev/null \
        | jq -e '.is_self == true' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Step 2: Rolling upgrade, one node at a time
# ---------------------------------------------------------------------------
log "Beginning rolling upgrade across ${#NODE_LIST[@]} node(s): ${NODES}"

for host in "${NODE_LIST[@]}"; do
    log "=== Upgrading node: ${host} ==="

    if is_leader "$host"; then
        log "  ${host} is the current active node — stepping down first"
        remote "$host" "curl -fsSk -X PUT ${VAULT_ADDR}/v1/sys/step-down" \
            || log "  WARNING: step-down request failed or was already a standby; continuing"
        sleep 5
    fi

    log "  Copying new binary to ${host}:${BINARY_PATH}.new"
    scp "${SSH_OPTS[@]}" "${WORKDIR}/vault" "${SSH_USER}@${host}:${BINARY_PATH}.new" \
        || die "Failed to copy binary to ${host}"

    log "  Stopping vault service on ${host}"
    remote "$host" "sudo systemctl stop ${SERVICE_NAME}" \
        || die "Failed to stop vault on ${host}"

    log "  Swapping binary on ${host}"
    remote "$host" "sudo mv ${BINARY_PATH}.new ${BINARY_PATH} && sudo chmod +x ${BINARY_PATH}" \
        || die "Failed to install new binary on ${host}"

    log "  Starting vault service on ${host}"
    remote "$host" "sudo systemctl start ${SERVICE_NAME}" \
        || die "Failed to start vault on ${host}"

    if ! wait_for_healthy "$host"; then
        die "${host} did not report healthy within ${HEALTH_TIMEOUT}s after upgrade — aborting remaining rollout. Manual intervention needed on this node."
    fi

    INSTALLED_VERSION="$(remote "$host" "${BINARY_PATH} version" 2>/dev/null | head -n1 || echo unknown)"
    log "  ${host} now running: ${INSTALLED_VERSION}"
done

log "Rolling upgrade complete across all ${#NODE_LIST[@]} node(s)."