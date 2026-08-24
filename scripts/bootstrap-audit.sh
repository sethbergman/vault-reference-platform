#!/usr/bin/env bash
#
# bootstrap-audit.sh — Enable Vault audit devices
#
# Usage:
#   ./bootstrap-audit.sh [options]
#
# Options:
#   --path <name>        Primary device mount name (default: file)
#   --file-path <path>   Where it writes (default: /vault/audit/vault-audit.log)
#   --second-path <name> Secondary device mount name (default: file-secondary)
#   --second-type <t>    file or socket (default: file)
#   --second-file <path> Where a file secondary writes
#                        (default: /vault/audit/vault-audit-secondary.log)
#   --second-address <a> Where a socket secondary sends (host:port)
#   --no-second          Enable only one device. Read the warning below.
#   --mode <octal>       File mode for the logs (default: 0600)
#   --list               Show enabled devices and exit
#   --force              Re-enable a device that already exists
#
# WHY TWO DEVICES
#
# Vault sends every request and response to all enabled audit devices and
# guarantees the entry reaches at least one of them. If it cannot write to
# **any** enabled device, it refuses to service the request.
#
# That is correct behaviour — a Vault that cannot be audited should not be
# answering questions about secrets — and it means a single audit device
# turns a full disk into a total outage. Two devices on independent
# failure domains is what stops routine disk pressure becoming downtime.
#
# The secondary defaults to a second file, which works anywhere and needs
# nothing else running — but two files on one filesystem are one failure
# domain wearing two hats. `--second-type socket` points it at a
# collector instead, which is the shape HashiCorp recommend and what the
# local profile and integration tests actually use.
#
# A socket device alone is a bad idea: when its endpoint goes away Vault
# can block. Paired with a file device it cannot, because the file device
# keeps satisfying the at-least-one guarantee. That pairing is the whole
# reason both exist. See docs/audit.md.
#
# WHAT IS NOT LOGGED
#
# Audit entries hash sensitive values with a per-cluster HMAC key rather
# than recording them. You can tell whether a given secret matches a known
# value, but you cannot read it out of the log. That is what makes these
# logs safe to ship somewhere central.
#
# `log_raw = true` turns that off and writes secrets in clear text. This
# script will not set it, and there is deliberately no flag for it.
#
# ROTATION
#
# Vault holds the log file open. Rotating it means moving the file and
# then sending SIGHUP, which makes Vault close and reopen the path.
#
# Note that the same signal also reloads TLS certificates — see
# scripts/issue-node-cert.sh. That is harmless, but it means a logrotate
# postrotate hook and a certificate renewal are doing the same thing to
# the same process, and a certificate that cannot be read will surface as
# a failed reload during log rotation.
#
# Requirements: vault, jq, and a VAULT_TOKEN with sudo on sys/audit

set -euo pipefail

DEVICE_PATH="file"
FILE_PATH="/vault/audit/vault-audit.log"
SECOND_PATH="file-secondary"
SECOND_FILE="/vault/audit/vault-audit-secondary.log"
SECOND_TYPE="file"
SECOND_ADDRESS=""
ENABLE_SECOND=true
MODE="0600"
LIST_ONLY=false
FORCE=false

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)        DEVICE_PATH="$2"; shift 2 ;;
        --file-path)   FILE_PATH="$2"; shift 2 ;;
        --second-path) SECOND_PATH="$2"; shift 2 ;;
        --second-file) SECOND_FILE="$2"; shift 2 ;;
        --second-type) SECOND_TYPE="$2"; shift 2 ;;
        --second-address) SECOND_ADDRESS="$2"; shift 2 ;;
        --no-second)   ENABLE_SECOND=false; shift ;;
        --mode)        MODE="$2"; shift 2 ;;
        --list)        LIST_ONLY=true; shift ;;
        --force)       FORCE=true; shift ;;
        -h|--help)     usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

command -v vault >/dev/null 2>&1 || die "vault not found on PATH"
command -v jq    >/dev/null 2>&1 || die "jq not found on PATH"
[[ -n "${VAULT_ADDR:-}" ]]  || die "VAULT_ADDR is not set"
[[ -n "${VAULT_TOKEN:-}" ]] || die "VAULT_TOKEN is not set"

case "$SECOND_TYPE" in
    file) ;;
    socket)
        [[ -n "$SECOND_ADDRESS" ]]             || die "--second-type socket needs --second-address host:port"
        ;;
    *) die "--second-type must be file or socket, got: ${SECOND_TYPE}" ;;
esac

# device_enabled <name>
device_enabled() {
    vault audit list -format=json 2>/dev/null \
        | jq -e --arg p "${1}/" 'has($p)' >/dev/null 2>&1
}

device_count() {
    vault audit list -format=json 2>/dev/null | jq 'length' 2>/dev/null || echo 0
}

if [[ "$LIST_ONLY" == true ]]; then
    log "Enabled audit devices:"
    vault audit list -detailed 2>/dev/null || die "Could not list audit devices"
    exit 0
fi

# ---------------------------------------------------------------------------
# Enable
# ---------------------------------------------------------------------------
# enable_device <mount-name> <destination> <label> [file|socket]
enable_device() {
    local name="$1" path="$2" label="$3" kind="${4:-file}"

    if device_enabled "$name" && [[ "$FORCE" == false ]]; then
        log "${label} device '${name}/' is already enabled; leaving it alone."
        return 0
    fi

    if device_enabled "$name" && [[ "$FORCE" == true ]]; then
        # Disabling before re-enabling is a real window: if this is the
        # only device and something writes to Vault in between, that
        # request goes unaudited. Refuse rather than narrate it.
        if [[ "$(device_count)" -le 1 ]]; then
            die "Refusing to re-enable '${name}/' with --force while it is the only device: disabling it first would leave Vault unaudited"
        fi
        log "Disabling '${name}/' to re-enable it (--force)..."
        vault audit disable "$name" >/dev/null || die "Could not disable ${name}"
    fi

    log "Enabling the ${label} audit device at '${name}/' -> ${path}..."

    # Vault writes a test entry when a device is enabled, so a
    # destination it cannot reach fails here rather than at the first
    # real request. That is the difference between a failed command and
    # an outage.
    if [[ "$kind" == "socket" ]]; then
        vault audit enable -path="$name" socket \
            address="$path" \
            socket_type=tcp >/dev/null \
            || die "Could not enable ${name} to ${path} — is the collector listening?"
    else
        vault audit enable -path="$name" file \
            file_path="$path" \
            mode="$MODE" >/dev/null \
            || die "Could not enable ${name} at ${path} — is the directory writable by the vault user?"
    fi

    log "  enabled."
}

enable_device "$DEVICE_PATH" "$FILE_PATH" "primary" file

if [[ "$ENABLE_SECOND" == true ]]; then
    if [[ "$SECOND_TYPE" == "socket" ]]; then
        enable_device "$SECOND_PATH" "$SECOND_ADDRESS" "secondary" socket
    else
        enable_device "$SECOND_PATH" "$SECOND_FILE" "secondary" file
        log ""
        log "Note: both devices are files. If they share a filesystem they"
        log "share a failure domain — see --second-type socket."
    fi
else
    log ""
    log "WARNING: only one audit device is enabled (--no-second)."
    log "Vault refuses to service requests when it cannot write to any"
    log "enabled device, so this configuration turns a full disk into a"
    log "total outage. See docs/audit.md."
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
COUNT="$(device_count)"
[[ "$COUNT" -ge 1 ]] || die "No audit devices are enabled after running — refusing to report success"

log ""
log "Audit devices enabled: ${COUNT}"
vault audit list -detailed 2>/dev/null >&2 || true

log ""
log "Entries are HMAC'd, not plaintext — the log is safe to ship centrally."
log "Rotate by moving the file and sending SIGHUP; see docs/audit.md."

if [[ "$COUNT" -lt 2 ]]; then
    log ""
    log "Note: with fewer than two devices, losing the one takes Vault down."
fi
