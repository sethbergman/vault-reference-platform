#!/usr/bin/env bash
#
# migrate-to-vault-pki.sh — Move a running cluster onto Vault-issued certificates
#
# Usage:
#   ./migrate-to-vault-pki.sh --nodes <name>=<host:port>,... [options]
#
# Example (local Docker profile):
#   ./migrate-to-vault-pki.sh \
#       --nodes vault-0=127.0.0.1:8200,vault-1=127.0.0.1:8210,vault-2=127.0.0.1:8220 \
#       --tls-dir docker/dev/tls \
#       --domain vault.internal \
#       --reload-cmd 'docker compose -f docker/dev/docker-compose.yml kill -s HUP {node}'
#
# WHY THIS EXISTS
#
# scripts/issue-node-cert.sh swaps one node's certificate. Doing that to a
# whole cluster is not a loop around it: get the ordering wrong and the
# nodes stop trusting each other, which presents as a network fault and
# is diagnosed as one.
#
# Nodes verify their peers with tls_client_ca_file. A node whose trust
# bundle does not contain the CA that signed its peer's certificate will
# refuse that peer. So there is exactly one safe order:
#
#   1. TRUST  every node's bundle gains the PKI CA, keeping the bootstrap
#             CA. Nothing swaps yet. After this, every node trusts both.
#   2. SWAP   one node at a time moves onto a PKI certificate. Its peers
#             already trust the new CA (step 1), and it still trusts them
#             because it kept the old one.
#   3. PRUNE  once every node is on PKI, the bootstrap CA comes out.
#
# Running step 3 while any node still presents a bootstrap certificate
# partitions the cluster. This script refuses to, and checks rather than
# assumes — see the guard in phase_prune.
#
# ORDERING WITHIN THE SWAP
#
# Standbys first, the active node last. A certificate swap does not cost
# leadership (Vault reloads on SIGHUP without restarting), so this is not
# about avoiding an election. It is about what is still true if the run
# fails halfway: the leader is the node you least want in an unknown
# state, so it is the one touched last, when the procedure has already
# worked twice.
#
# Options:
#   --nodes <list>       Required. name=host:port pairs, comma separated.
#   --tls-dir <dir>      Where certificates live (default: /etc/vault.d/tls)
#   --domain <domain>    Domain for issued common names (default: vault.internal)
#   --mount <path>       PKI mount (default: pki)
#   --role <name>        PKI role (default: vault-node)
#   --reload-cmd <cmd>   How to reload a node. {node} is substituted.
#                        Default: systemctl reload vault
#   --key-mode <mode>    Mode for installed keys (default: 0600)
#   --phase <p>          trust, swap, prune, or all (default: all)
#   --issue-script <p>   Path to issue-node-cert.sh (default: alongside
#                        this script)
#   --health-retries <n> How many 2s attempts a node gets to come back
#                        healthy after each change (default: 30)
#   --dry-run            Print the plan and exit
#
# Requirements: vault, jq, openssl, and a VAULT_TOKEN that can issue from
# the PKI role. Run scripts/bootstrap-pki.sh first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE="${SCRIPT_DIR}/issue-node-cert.sh"

NODES=""
TLS_DIR="/etc/vault.d/tls"
DOMAIN="vault.internal"
MOUNT="pki"
ROLE="vault-node"
RELOAD_CMD="systemctl reload vault"
KEY_MODE="0600"
PHASE="all"
HEALTH_RETRIES=30
DRY_RUN=false

log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
step() { printf '\n[%s] === %s ===\n' "$(date -u '+%H:%M:%S')" "$*" >&2; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)      NODES="$2"; shift 2 ;;
        --tls-dir)    TLS_DIR="$2"; shift 2 ;;
        --domain)     DOMAIN="$2"; shift 2 ;;
        --mount)      MOUNT="$2"; shift 2 ;;
        --role)       ROLE="$2"; shift 2 ;;
        --reload-cmd) RELOAD_CMD="$2"; shift 2 ;;
        --key-mode)   KEY_MODE="$2"; shift 2 ;;
        --phase)      PHASE="$2"; shift 2 ;;
        --issue-script) ISSUE="$2"; shift 2 ;;
        --health-retries) HEALTH_RETRIES="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$NODES" ]] || die "--nodes is required, e.g. --nodes vault-0=127.0.0.1:8200,..."
case "$PHASE" in
    trust|swap|prune|all) ;;
    *) die "--phase must be trust, swap, prune, or all, got: ${PHASE}" ;;
esac

command -v vault   >/dev/null 2>&1 || die "vault not found on PATH"
command -v jq      >/dev/null 2>&1 || die "jq not found on PATH"
command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH"
[[ -x "$ISSUE" ]] || die "${ISSUE} is missing or not executable"
[[ -n "${VAULT_ADDR:-}" ]] || die "VAULT_ADDR is not set"

# ---------------------------------------------------------------------------
# Parse the node list
# ---------------------------------------------------------------------------
declare -a NODE_NAMES=()
declare -A NODE_ADDR=()

IFS=',' read -r -a NODE_SPECS <<< "$NODES"
for spec in "${NODE_SPECS[@]}"; do
    [[ "$spec" == *=* ]] || die "Malformed node spec '${spec}' — expected name=host:port"
    name="${spec%%=*}"
    addr="${spec#*=}"
    [[ -n "$name" && -n "$addr" ]] || die "Malformed node spec: ${spec}"
    NODE_NAMES+=("$name")
    NODE_ADDR["$name"]="$addr"
done

[[ ${#NODE_NAMES[@]} -ge 1 ]] || die "No nodes parsed from --nodes"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# reload_for <node> — the reload command with {node} substituted.
reload_for() { printf '%s' "${RELOAD_CMD//\{node\}/$1}"; }

# served_issuer <host:port> — issuer DN of the certificate a node presents.
served_issuer() {
    echo | openssl s_client -connect "$1" 2>/dev/null \
        | openssl x509 -noout -issuer 2>/dev/null || true
}

# node_healthy <host:port> — 200 active, 429 standby; anything else is not.
# http_code_of <url>
#
# Not `curl ... || echo 000`. On a connection failure curl still prints
# its %{http_code} -- "000" -- so the fallback appends a second one and
# the caller sees "000000", which matches nothing and turns a clear
# failure into an unreadable one. Fall back only when curl printed
# nothing at all.
http_code_of() {
    local code
    code="$(curl --cacert "${VAULT_CACERT:-/dev/null}" -sS -o /dev/null \
        -w '%{http_code}' "$1" 2>/dev/null)" || true
    [[ -n "$code" ]] || code="000"
    printf '%s' "$code"
}

node_healthy() {
    local code; code="$(http_code_of "https://$1/v1/sys/health?standbyok=true")"
    [[ "$code" == "200" || "$code" == "429" ]]
}

# is_active <host:port>
is_active() {
    local code; code="$(http_code_of "https://$1/v1/sys/health")"
    [[ "$code" == "200" ]]
}

voter_count() {
    vault operator raft list-peers -format=json 2>/dev/null \
        | jq '[.data.config.servers[]? | select(.voter == true)] | length' 2>/dev/null || echo 0
}

# The subject of the PKI CA, so a node's certificate can be recognised as
# having come from it. Compared against the issuer the node actually
# serves, not against what is on its disk — a certificate that was
# installed but never reloaded is not migrated.
pki_ca_subject() {
    vault read -field=certificate "${MOUNT}/cert/ca" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject= *//' || true
}

# on_pki <node> — is this node serving a certificate from the PKI mount?
on_pki() {
    local issuer
    issuer="$(served_issuer "${NODE_ADDR[$1]}")"
    [[ -n "$PKI_SUBJECT" && "$issuer" == *"$PKI_SUBJECT"* ]]
}

EXPECTED_VOTERS="$(voter_count)"
PKI_SUBJECT="$(pki_ca_subject)"
[[ -n "$PKI_SUBJECT" ]] \
    || die "Could not read the CA from ${MOUNT} — has scripts/bootstrap-pki.sh been run?"

# ---------------------------------------------------------------------------
# Order: standbys first, the active node last
# ---------------------------------------------------------------------------
declare -a SWAP_ORDER=()
ACTIVE_NODE=""
for n in "${NODE_NAMES[@]}"; do
    if is_active "${NODE_ADDR[$n]}"; then
        ACTIVE_NODE="$n"
    else
        SWAP_ORDER+=("$n")
    fi
done
[[ -n "$ACTIVE_NODE" ]] && SWAP_ORDER+=("$ACTIVE_NODE")

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------
log "Cluster: ${#NODE_NAMES[@]} node(s), ${EXPECTED_VOTERS} voter(s)"
log "PKI CA:  ${PKI_SUBJECT}"
log "Active:  ${ACTIVE_NODE:-<none found>}"
log ""
log "Plan:"
log "  1. trust  add the PKI CA to every node's bundle, keeping the old one"
log "  2. swap   ${SWAP_ORDER[*]}  (active node last)"
log "  3. prune  drop the bootstrap CA, once every node is on PKI"

for n in "${NODE_NAMES[@]}"; do
    if on_pki "$n"; then
        log "  ${n} (${NODE_ADDR[$n]}) is already serving a PKI certificate"
    fi
done

if [[ "$DRY_RUN" == true ]]; then
    log ""
    log "Dry run — nothing was changed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
# gate <node> <what> — a node must be healthy and the cluster must still
# have every voter before the run moves on. Continuing past a node that
# did not come back is how one bad certificate becomes an outage.
gate() {
    local node="$1" what="$2" addr="${NODE_ADDR[$1]}"
    for _ in $(seq 1 "$HEALTH_RETRIES"); do
        if node_healthy "$addr"; then break; fi
        sleep 2
    done
    node_healthy "$addr" \
        || die "${node} is not healthy after ${what} — stopping. Remaining nodes are untouched."

    local voters
    voters="$(voter_count)"
    [[ "$voters" == "$EXPECTED_VOTERS" ]] \
        || die "Voter count dropped from ${EXPECTED_VOTERS} to ${voters} after ${what} on ${node} — stopping."
    log "  ${node}: healthy, ${voters}/${EXPECTED_VOTERS} voters"
}

phase_trust() {
    step "Phase 1/3 — trust the PKI CA everywhere"
    log "Nothing swaps in this phase. Every node ends up trusting both the"
    log "bootstrap CA and the PKI CA, which is what makes phase 2 safe."

    for n in "${NODE_NAMES[@]}"; do
        log "${n}: adding the PKI CA to its trust bundle..."
        "$ISSUE" \
            --ca-only \
            --mount "$MOUNT" \
            --tls-dir "$TLS_DIR" \
            --cert-name "$n" \
            --reload-cmd "$(reload_for "$n")" \
            --verify-addr "${NODE_ADDR[$n]}" \
            >&2 || die "Could not update the trust bundle on ${n}"
        gate "$n" "the trust update"
    done
}

phase_swap() {
    step "Phase 2/3 — swap certificates, one node at a time"

    for n in "${SWAP_ORDER[@]}"; do
        if on_pki "$n"; then
            log "${n}: already serving a PKI certificate; skipping."
            continue
        fi

        log "${n}: issuing and installing a PKI certificate..."
        "$ISSUE" \
            --common-name "${n}.${DOMAIN}" \
            --alt-names "${n},localhost" \
            --ip-sans "127.0.0.1" \
            --mount "$MOUNT" \
            --role "$ROLE" \
            --tls-dir "$TLS_DIR" \
            --cert-name "$n" \
            --key-mode "$KEY_MODE" \
            --force \
            --reload-cmd "$(reload_for "$n")" \
            --verify-addr "${NODE_ADDR[$n]}" \
            >&2 || die "Certificate swap failed on ${n} — stopping. Remaining nodes are untouched."

        # issue-node-cert.sh already confirms the node serves the new
        # certificate. This confirms it came from the PKI mount, which is
        # the thing phase 3 depends on.
        on_pki "$n" || die "${n} reloaded but is not serving a PKI certificate — stopping."

        gate "$n" "the certificate swap"
    done
}

phase_prune() {
    step "Phase 3/3 — drop the bootstrap CA"

    # The guard. Removing the bootstrap CA while any node still presents a
    # certificate signed by it makes every other node refuse that peer.
    # Checked against what each node actually serves, because a
    # certificate written to disk and never reloaded does not count.
    local laggards=()
    for n in "${NODE_NAMES[@]}"; do
        on_pki "$n" || laggards+=("$n")
    done

    if [[ ${#laggards[@]} -gt 0 ]]; then
        die "Refusing to prune: ${laggards[*]} still serve a non-PKI certificate. Dropping the bootstrap CA now would make their peers reject them."
    fi

    log "All ${#NODE_NAMES[@]} node(s) are serving PKI certificates."

    for n in "${NODE_NAMES[@]}"; do
        log "${n}: replacing the trust bundle with the PKI chain only..."
        "$ISSUE" \
            --ca-only \
            --replace-ca \
            --mount "$MOUNT" \
            --tls-dir "$TLS_DIR" \
            --cert-name "$n" \
            --reload-cmd "$(reload_for "$n")" \
            --verify-addr "${NODE_ADDR[$n]}" \
            >&2 || die "Could not prune the trust bundle on ${n}"
        gate "$n" "the trust bundle prune"
    done

    # The bundle on disk has changed, and Vault is not the only thing that
    # reads it. Anything holding a copy loaded it once at startup and is
    # now verifying against a CA that signs nothing.
    #
    # This is stated rather than done, because the set of consumers is
    # site-specific and this script cannot know it. It is not hypothetical:
    # in the local profile Prometheus and the blackbox exporter both mount
    # this bundle to verify Vault's TLS, and until they are restarted the
    # probe stops reporting -- certificate expiry silently unmonitored,
    # which is precisely the shape the absent() alerts exist to catch.
    #
    # The remedy is a recreate, not a restart. The bundle is replaced
    # rather than edited, so a single-file bind mount of it can still be
    # pointing at the file that went away -- on Docker Desktop the
    # container then refuses to start at all. docs/security.md has the
    # error and the reasoning.
    log ""
    log "NOTE: the bootstrap CA is gone from the trust bundle. Anything else"
    log "      that reads it -- monitoring, probes, application clients --"
    log "      loaded it at startup and must be restarted to pick up the"
    log "      new contents. Recreate rather than restart anything that"
    log "      bind-mounts the bundle as a single file -- the path is"
    log "      unchanged and the inode is not, and a restart can reuse a"
    log "      reference to the file that was replaced. See"
    log "      docs/security.md."
}

case "$PHASE" in
    trust) phase_trust ;;
    swap)  phase_swap ;;
    prune) phase_prune ;;
    all)   phase_trust; phase_swap; phase_prune ;;
esac

step "Migration complete"
log "Every node is serving a certificate from ${MOUNT} and trusts only that CA."
log "Renewal from here is scripts/issue-node-cert.sh on its timer; see docs/security.md."
