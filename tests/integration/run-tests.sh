#!/usr/bin/env bash
#
# run-tests.sh — Run the operational scripts against a real Vault cluster
#
# Usage:
#   ./tests/integration/run-tests.sh [--keep-running]
#
# Every other suite in this repository replaces Vault with a shim. Shims
# prove a script issues the right commands; they cannot prove Vault
# accepts them, and they cannot prove anything about what happens to a
# running cluster afterwards.
#
# This one stands up the real 3-node Raft cluster from
# scripts/bootstrap-dev-cluster.sh — real Vault 1.17.2, real Raft, real
# Transit auto-unseal, real TLS — and runs the scripts against it.
#
# The claims it exists to check, none of which a shim can reach:
#
#   1. A Raft snapshot taken by scripts/snapshot.sh is one Vault will
#      actually accept back. `snapshot inspect` against real snapshot
#      data, not against a file the shim wrote.
#
#   2. Standby detection works against a real HA cluster, rather than
#      against whatever ha_mode the shim was told to report.
#
#   3. Vault reloads certificates on SIGHUP without restarting. This is
#      the load-bearing claim behind the whole PKI renewal design, and
#      until now it rested on documentation alone. Here the process start
#      time is compared before and after: if Vault restarted, the test
#      fails.
#
#   4. A node keeps its place in the cluster across a certificate swap —
#      still unsealed, still a voter, data still readable.
#
# Requirements: docker compose, the vault CLI, jq, openssl, curl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}/docker/dev"
TLS_DIR="${COMPOSE_DIR}/tls"

KEEP_RUNNING=false
[[ "${1:-}" == "--keep-running" ]] && KEEP_RUNNING=true

WORK="$(mktemp -d)"

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

compose() {
    docker compose --project-directory "$COMPOSE_DIR" \
        -f "${COMPOSE_DIR}/docker-compose.yml" "$@"
}

cleanup() {
    local rc=$?
    if [[ "$KEEP_RUNNING" == true ]]; then
        info "Leaving the cluster up (--keep-running). Tear down with:"
        info "  cd docker/dev && docker compose down -v"
    else
        info "Tearing down the cluster..."
        compose down -v >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for dep in docker vault jq openssl curl; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done

# ---------------------------------------------------------------------------
info ""
info "=== Bringing up the cluster ==="
# ---------------------------------------------------------------------------
ROOT_TOKEN="$("${REPO_ROOT}/scripts/bootstrap-dev-cluster.sh")"
[[ -n "$ROOT_TOKEN" ]] || { red "ERROR: no root token from bootstrap-dev-cluster.sh"; exit 1; }

export VAULT_TOKEN="$ROOT_TOKEN"
export VAULT_CACERT="${TLS_DIR}/ca.crt"
export VAULT_ADDR="https://127.0.0.1:8200"

# node_port <name> — the host port each node publishes
node_port() {
    case "$1" in
        vault-0) echo 8200 ;;
        vault-1) echo 8210 ;;
        vault-2) echo 8220 ;;
    esac
}

# health_code <port>
health_code() {
    curl --cacert "$VAULT_CACERT" -fsS -o /dev/null -w '%{http_code}' \
        "https://127.0.0.1:$1/v1/sys/health?standbyok=true" 2>/dev/null || echo "000"
}

# ---------------------------------------------------------------------------
info ""
info "=== The cluster is real ==="
# ---------------------------------------------------------------------------
PEERS_JSON="$(vault operator raft list-peers -format=json 2>/dev/null || echo '{}')"
PEER_COUNT="$(jq -r '.data.config.servers | length // 0' <<< "$PEERS_JSON" 2>/dev/null || echo 0)"
VOTERS="$(jq -r '[.data.config.servers[]? | select(.voter == true)] | length' <<< "$PEERS_JSON" 2>/dev/null || echo 0)"

if [[ "$PEER_COUNT" == "3" ]]; then ok "three Raft peers"; else bad "three Raft peers" "got ${PEER_COUNT}"; fi
if [[ "$VOTERS" == "3" ]]; then ok "all three are voters"; else bad "all three are voters" "got ${VOTERS}"; fi

# A canary, so a later assertion can show the node still holds its data
# after the certificate swap rather than having quietly reinitialised.
vault secrets enable -path=itest -version=2 kv >/dev/null 2>&1 || true
if vault kv put itest/canary value=before-cert-swap >/dev/null 2>&1; then
    ok "wrote a canary secret"
else
    bad "wrote a canary secret"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Snapshots against real Raft data ==="
# ---------------------------------------------------------------------------
SNAP_DIR="${WORK}/snapshots"
if "${REPO_ROOT}/scripts/snapshot.sh" --cloud none --output-dir "$SNAP_DIR" >"${WORK}/snap.log" 2>&1; then
    ok "snapshot.sh succeeded against the active node"
else
    bad "snapshot.sh succeeded against the active node" "$(tail -3 "${WORK}/snap.log")"
fi

SNAP_FILE="$(find "$SNAP_DIR" -name '*.snap' -type f 2>/dev/null | head -1)"
if [[ -s "${SNAP_FILE:-/nonexistent}" ]]; then
    ok "a non-empty snapshot file was produced"
else
    bad "a non-empty snapshot file was produced"
fi

# The point of the whole exercise: Vault itself accepts this file. The
# shim suite could only check that some bytes were written.
if [[ -n "$SNAP_FILE" ]] && vault operator raft snapshot inspect "$SNAP_FILE" >"${WORK}/inspect.log" 2>&1; then
    ok "Vault accepts the snapshot (operator raft snapshot inspect)"
else
    bad "Vault accepts the snapshot (operator raft snapshot inspect)" "$(tail -3 "${WORK}/inspect.log" 2>/dev/null)"
fi

# A real snapshot of a real cluster is not tiny. A few hundred bytes would
# mean something wrote a header and stopped.
SNAP_SIZE="$(wc -c < "${SNAP_FILE:-/dev/null}" 2>/dev/null | tr -d '[:space:]' || echo 0)"
if [[ "${SNAP_SIZE:-0}" -gt 1000 ]]; then
    ok "the snapshot is a plausible size (${SNAP_SIZE} bytes)"
else
    bad "the snapshot is a plausible size" "got ${SNAP_SIZE} bytes"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Standby detection against a real HA cluster ==="
# ---------------------------------------------------------------------------
STANDBY_PORT=""
for n in vault-0 vault-1 vault-2; do
    p="$(node_port "$n")"
    [[ "$(health_code "$p")" == "429" ]] && { STANDBY_PORT="$p"; break; }
done

if [[ -n "$STANDBY_PORT" ]]; then
    ok "found a real standby node (port ${STANDBY_PORT})"

    STANDBY_DIR="${WORK}/standby-snapshots"
    if VAULT_ADDR="https://127.0.0.1:${STANDBY_PORT}" \
        "${REPO_ROOT}/scripts/snapshot.sh" --cloud none --output-dir "$STANDBY_DIR" \
        >"${WORK}/standby.log" 2>&1; then
        ok "a standby exits 0 rather than failing the timer"
    else
        bad "a standby exits 0 rather than failing the timer" "$(tail -3 "${WORK}/standby.log")"
    fi

    if [[ -z "$(find "$STANDBY_DIR" -name '*.snap' -type f 2>/dev/null | head -1)" ]]; then
        ok "and it takes no snapshot"
    else
        bad "and it takes no snapshot" "a standby wrote a snapshot"
    fi

    if grep -q "not active" "${WORK}/standby.log"; then
        ok "and says why"
    else
        bad "and says why" "$(tail -2 "${WORK}/standby.log")"
    fi
else
    bad "found a real standby node" "no node reported 429; is this actually an HA cluster?"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Vault PKI issues a usable node certificate ==="
# ---------------------------------------------------------------------------
if "${REPO_ROOT}/scripts/bootstrap-pki.sh" \
        --domain vault.internal \
        --extra-domains vault-0,vault-1,vault-2 \
        >"${WORK}/pki.log" 2>&1; then
    ok "bootstrap-pki.sh configured the engine"
else
    bad "bootstrap-pki.sh configured the engine" "$(tail -5 "${WORK}/pki.log")"
fi

if vault read -field=certificate pki/cert/ca >"${WORK}/pki-ca.crt" 2>/dev/null \
    && [[ -s "${WORK}/pki-ca.crt" ]]; then
    ok "the PKI mount has a root CA"
else
    bad "the PKI mount has a root CA"
fi

# served_cert <port> — what the node actually presents on the wire. Not
# what is on disk: the whole question is whether Vault picked it up.
served_cert() {
    echo | openssl s_client -connect "127.0.0.1:$1" -servername localhost 2>/dev/null \
        | openssl x509 2>/dev/null
}

BEFORE_SERIAL="$(served_cert 8200 | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2)"
BEFORE_ISSUER="$(served_cert 8200 | openssl x509 -noout -issuer 2>/dev/null)"
BEFORE_STARTED="$(docker inspect -f '{{.State.StartedAt}}' "$(compose ps -q vault-0)" 2>/dev/null || echo unknown)"
BEFORE_BUNDLE_N="$(grep -c 'BEGIN CERTIFICATE' "${TLS_DIR}/ca.crt" 2>/dev/null || echo 0)"

if [[ -n "$BEFORE_SERIAL" ]]; then
    ok "vault-0 is serving a certificate we can read"
else
    bad "vault-0 is serving a certificate we can read"
fi

# All three containers mount the same host directory, so appending the
# PKI CA to the bundle updates it for every node at once. They still need
# a SIGHUP to pick it up, which is why the reload hook signals all three
# — that ordering (trust first, swap second) is what keeps the cluster
# together during a migration.
cat > "${WORK}/reload.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${COMPOSE_DIR}"
for n in vault-0 vault-1 vault-2; do
    docker compose kill -s HUP "\$n" >/dev/null 2>&1 || true
done
sleep 3
EOF
chmod +x "${WORK}/reload.sh"

if "${REPO_ROOT}/scripts/issue-node-cert.sh" \
        --common-name vault-0.vault.internal \
        --alt-names vault-0,localhost \
        --ip-sans 127.0.0.1 \
        --tls-dir "$TLS_DIR" \
        --cert-name vault-0 \
        --force \
        --reload-cmd "${WORK}/reload.sh" \
        >"${WORK}/issue.log" 2>&1; then
    ok "issue-node-cert.sh issued and installed a certificate"
else
    bad "issue-node-cert.sh issued and installed a certificate" "$(tail -5 "${WORK}/issue.log")"
fi

AFTER_BUNDLE_N="$(grep -c 'BEGIN CERTIFICATE' "${TLS_DIR}/ca.crt" 2>/dev/null || echo 0)"
if [[ "$AFTER_BUNDLE_N" -gt "$BEFORE_BUNDLE_N" ]]; then
    ok "the PKI CA was added to the trust bundle, not swapped in"
else
    bad "the PKI CA was added to the trust bundle, not swapped in" \
        "bundle went from ${BEFORE_BUNDLE_N} to ${AFTER_BUNDLE_N} certificates"
fi

# ---------------------------------------------------------------------------
info ""
info "=== SIGHUP reloads the certificate without restarting Vault ==="
# ---------------------------------------------------------------------------
# The claim the whole renewal design rests on. Until now it rested on
# HashiCorp's listener documentation and nothing else.
AFTER_SERIAL="$(served_cert 8200 | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2)"
AFTER_ISSUER="$(served_cert 8200 | openssl x509 -noout -issuer 2>/dev/null)"
AFTER_STARTED="$(docker inspect -f '{{.State.StartedAt}}' "$(compose ps -q vault-0)" 2>/dev/null || echo unknown)"

if [[ -n "$AFTER_SERIAL" && "$AFTER_SERIAL" != "$BEFORE_SERIAL" ]]; then
    ok "the node is serving a different certificate than before"
else
    bad "the node is serving a different certificate than before" \
        "serial was ${BEFORE_SERIAL}, now ${AFTER_SERIAL} — SIGHUP did not take effect"
fi

if [[ "$AFTER_ISSUER" == *"vault.internal Root CA"* ]]; then
    ok "and it was issued by the Vault PKI root"
else
    bad "and it was issued by the Vault PKI root" \
        "issuer is ${AFTER_ISSUER}, was ${BEFORE_ISSUER}"
fi

# The distinction between "reloaded" and "restarted". A restart would
# also swap the certificate, and would also drop leadership and — without
# auto-unseal — require a manual unseal.
if [[ "$AFTER_STARTED" == "$BEFORE_STARTED" && "$AFTER_STARTED" != "unknown" ]]; then
    ok "the Vault process never restarted (start time unchanged)"
else
    bad "the Vault process never restarted" \
        "started at ${BEFORE_STARTED}, now ${AFTER_STARTED}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== The cluster survived the swap ==="
# ---------------------------------------------------------------------------
CODE="$(health_code 8200)"
if [[ "$CODE" == "200" || "$CODE" == "429" ]]; then
    ok "vault-0 is still healthy and unsealed (${CODE})"
else
    bad "vault-0 is still healthy and unsealed" "health returned ${CODE}"
fi

SEALED="$(vault status -format=json 2>/dev/null | jq -r 'if has("sealed") then .sealed else true end')"
if [[ "$SEALED" == "false" ]]; then
    ok "and it did not reseal"
else
    bad "and it did not reseal" "sealed=${SEALED}"
fi

PEERS_AFTER="$(vault operator raft list-peers -format=json 2>/dev/null || echo '{}')"
VOTERS_AFTER="$(jq -r '[.data.config.servers[]? | select(.voter == true)] | length' <<< "$PEERS_AFTER" 2>/dev/null || echo 0)"
if [[ "$VOTERS_AFTER" == "3" ]]; then
    ok "all three peers are still voters"
else
    bad "all three peers are still voters" "got ${VOTERS_AFTER}"
fi

CANARY="$(vault kv get -field=value itest/canary 2>/dev/null || echo "")"
if [[ "$CANARY" == "before-cert-swap" ]]; then
    ok "data written before the swap is still readable"
else
    bad "data written before the swap is still readable" "got '${CANARY}'"
fi

# A renewal run immediately afterwards must decide there is nothing to do
# — against a real certificate with a real expiry, not a fixture.
if "${REPO_ROOT}/scripts/issue-node-cert.sh" \
        --common-name vault-0.vault.internal \
        --tls-dir "$TLS_DIR" \
        --cert-name vault-0 \
        --renew-within 1 \
        --no-reload \
        >"${WORK}/noop.log" 2>&1 && grep -q "nothing to do" "${WORK}/noop.log"; then
    ok "a second run correctly does nothing"
else
    bad "a second run correctly does nothing" "$(tail -3 "${WORK}/noop.log")"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Results ==="
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    red "FAILED"
    info ""
    info "Node logs (last 30 lines):"
    compose logs --tail=30 vault-0 2>&1 | sed 's/^/    /' || true
    exit 1
fi
green "All ${PASS} assertions passed against a real cluster."
