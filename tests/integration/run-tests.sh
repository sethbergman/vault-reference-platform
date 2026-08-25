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
ROOT_TOKEN="$("${REPO_ROOT}/scripts/bootstrap-dev-cluster.sh" --with-database --with-monitoring --with-audit)"
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

# health_code <port> — the *role* of the node.
#
# Deliberately without standbyok: that parameter tells Vault to answer 200
# for a standby, which is exactly the distinction being drawn here. With it
# set no node ever reports 429 and the standby search finds nothing.
#
#   200 active   429 standby   472/473 DR/perf standby   503 sealed
health_code() {
    curl --cacert "$VAULT_CACERT" -sS -o /dev/null -w '%{http_code}' \
        "https://127.0.0.1:$1/v1/sys/health" 2>/dev/null || echo "000"
}

# alive_code <port> — is the node serving at all, whatever its role.
alive_code() {
    curl --cacert "$VAULT_CACERT" -sS -o /dev/null -w '%{http_code}' \
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
info "  node role at 8200: HTTP $(health_code 8200)"
if "${REPO_ROOT}/scripts/snapshot.sh" --cloud none --output-dir "$SNAP_DIR" >"${WORK}/snap.log" 2>&1; then
    # Exit 0 alone proves nothing — a standby and a sealed node also exit
    # 0, by design. The assertion has to be that it actually took one.
    if grep -q "Snapshot verified" "${WORK}/snap.log"; then
        ok "snapshot.sh took and verified a snapshot"
    else
        bad "snapshot.sh took and verified a snapshot" "exited 0 without taking one; log follows"
        sed 's/^/        /' "${WORK}/snap.log"
    fi
else
    bad "snapshot.sh failed against the active node" "log follows"
    sed 's/^/        /' "${WORK}/snap.log"
fi

# `set -o pipefail` plus `set -e` makes a failing `find` abort the whole
# suite with no diagnostic at all — which is how this first ran. Every
# data-gathering line below has to be non-fatal so a missing value is
# reported as a failed assertion rather than a silent exit.
SNAP_FILE="$(find "$SNAP_DIR" -name '*.snap' -type f 2>/dev/null | head -1 || true)"
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
    c="$(health_code "$p")"
    info "  ${n} (port ${p}): HTTP ${c}"
    if [[ "$c" == "429" && -z "$STANDBY_PORT" ]]; then
        STANDBY_PORT="$p"
    fi
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

    if [[ -z "$(find "$STANDBY_DIR" -name '*.snap' -type f 2>/dev/null | head -1 || true)" ]]; then
        ok "and it takes no snapshot"
    else
        bad "and it takes no snapshot" "a standby wrote a snapshot"
    fi

    # Specifically "standby", not just any reason. The old wording was
    # "Node is unknown, not active", which a node that could not work out
    # its own role produced just as readily as a real standby — so a
    # looser match here passed while no node anywhere took a snapshot.
    if grep -q "standby" "${WORK}/standby.log"; then
        ok "and identifies itself as a standby"
    else
        bad "and identifies itself as a standby" "$(tail -2 "${WORK}/standby.log")"
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

BEFORE_SERIAL="$(served_cert 8200 | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2 || true)"
BEFORE_ISSUER="$(served_cert 8200 | openssl x509 -noout -issuer 2>/dev/null || true)"
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
    echo "HUP \$n"
    docker compose kill -s HUP "\$n" || echo "  (kill failed for \$n)"
done
sleep 5
EOF
chmod +x "${WORK}/reload.sh"

# The hook runs as an opaque command from issue-node-cert.sh, so its
# output is captured separately. If the signal never lands, that is the
# one line worth seeing.
cat > "${WORK}/reload-wrapper.sh" <<EOF
#!/usr/bin/env bash
"${WORK}/reload.sh" > "${WORK}/reload.out" 2>&1
EOF
chmod +x "${WORK}/reload-wrapper.sh"

# issue <label> <key-mode> <logfile> — everything except the key mode is
# identical between the two runs below.
issue_cert() {
    "${REPO_ROOT}/scripts/issue-node-cert.sh" \
        --common-name vault-0.vault.internal \
        --alt-names vault-0,localhost \
        --ip-sans 127.0.0.1 \
        --tls-dir "$TLS_DIR" \
        --cert-name vault-0 \
        --key-mode "$1" \
        --force \
        --reload-cmd "${WORK}/reload-wrapper.sh" \
        --verify-addr 127.0.0.1:8200 \
        >"$2" 2>&1
}

# --- The regression case -------------------------------------------------
#
# A key at 0600 owned by the host user is unreadable by the container's
# vault uid. Vault answers the SIGHUP with:
#
#   Error(s) were encountered during reload: 1 error occurred:
#       * error encountered reloading listener: open ...vault-0.key: permission denied
#
# and carries on serving the previous certificate. The reload command
# still exits 0, because the *signal* was delivered — so before this suite
# existed, the script reported success, the timer reported success, and
# the node would have served a stale certificate until it expired.
#
# This asserts the script now notices. It is the bug this test found,
# kept as a permanent check.
if issue_cert 0600 "${WORK}/issue-bad.log"; then
    bad "an unreadable key makes the reload fail loudly"         "the script reported success while Vault kept the old certificate"
else
    if grep -q "did not take" "${WORK}/issue-bad.log"; then
        ok "an unreadable key makes the reload fail loudly"
    else
        bad "an unreadable key makes the reload fail loudly"             "it failed, but not with the reload-verification error:"
        sed 's/^/        /' "${WORK}/issue-bad.log"
    fi
fi

# --- The working case ----------------------------------------------------
#
# 0644 matches what generate-dev-certs.sh writes for this profile, and for
# the same reason: the key is mounted read-only into a container running
# as a uid that does not own it. On a real node the renewal runs as root
# and 0600 is both correct and readable by Vault.
if issue_cert 0644 "${WORK}/issue.log"; then
    ok "issue-node-cert.sh issued, installed and confirmed a certificate"
else
    bad "issue-node-cert.sh issued, installed and confirmed a certificate" "log follows"
    sed 's/^/        /' "${WORK}/issue.log"
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
# On-disk vs served. If they agree, SIGHUP worked. If the on-disk serial
# changed but the served one did not, Vault did not reload — which would
# falsify the claim the renewal design rests on, so it has to be visible
# rather than inferred from a single failing assertion.
DISK_SERIAL="$(openssl x509 -in "${TLS_DIR}/vault-0.crt" -noout -serial 2>/dev/null | cut -d= -f2 || true)"
info "  serial before:  ${BEFORE_SERIAL:-<none>}"
info "  serial on disk: ${DISK_SERIAL:-<none>}"

if [[ -n "$DISK_SERIAL" && "$DISK_SERIAL" != "$BEFORE_SERIAL" ]]; then
    ok "a new certificate was written to disk"
else
    bad "a new certificate was written to disk" "on-disk serial is still ${DISK_SERIAL:-<none>}"
fi

info "  reload hook output:"
sed 's/^/        /' "${WORK}/reload.out" 2>/dev/null || true

AFTER_SERIAL="$(served_cert 8200 | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2 || true)"
info "  serial served:  ${AFTER_SERIAL:-<none>}"
AFTER_ISSUER="$(served_cert 8200 | openssl x509 -noout -issuer 2>/dev/null || true)"
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
info "=== The full migration, across every node ==="
# ---------------------------------------------------------------------------
# The single-node swap above is the risky step. This is the whole
# rollout: trust everywhere, swap each node, then drop the bootstrap CA —
# the last of which had only ever been exercised against a shim.

cat > "${WORK}/migrate-reload.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${COMPOSE_DIR}"
docker compose kill -s HUP "\$1" >/dev/null 2>&1 || true
sleep 3
EOF
chmod +x "${WORK}/migrate-reload.sh"

BOOTSTRAP_CA_SUBJECT="$(openssl x509 -in "${TLS_DIR}/ca.crt" -noout -subject 2>/dev/null | sed 's/^subject= *//' || true)"

if "${REPO_ROOT}/scripts/migrate-to-vault-pki.sh" \
        --nodes "vault-0=127.0.0.1:8200,vault-1=127.0.0.1:8210,vault-2=127.0.0.1:8220" \
        --tls-dir "$TLS_DIR" \
        --domain vault.internal \
        --key-mode 0644 \
        --reload-cmd "${WORK}/migrate-reload.sh {node}" \
        >"${WORK}/migrate.log" 2>&1; then
    ok "the migration completed across all three nodes"
else
    bad "the migration completed across all three nodes" "log follows"
    tail -25 "${WORK}/migrate.log" | sed 's/^/        /'
fi

# Every node must now serve a certificate from the PKI mount. Checked on
# the wire rather than on disk: a certificate written and never reloaded
# is not migrated, and that distinction is the whole reason the driver
# checks the same way.
MIGRATED=0
for port in 8200 8210 8220; do
    ISSUER="$(echo | openssl s_client -connect "127.0.0.1:${port}" 2>/dev/null \
        | openssl x509 -noout -issuer 2>/dev/null || true)"
    [[ "$ISSUER" == *"vault.internal Root CA"* ]] && MIGRATED=$((MIGRATED + 1))
done
if [[ "$MIGRATED" == "3" ]]; then
    ok "all three nodes serve PKI certificates"
else
    bad "all three nodes serve PKI certificates" "only ${MIGRATED}/3 did"
fi

# And the bootstrap CA is gone from the trust bundle — the step that
# partitions a cluster if it runs too early.
if [[ -n "$BOOTSTRAP_CA_SUBJECT" ]]; then
    # Read the bundle one PEM block at a time. A bundle holds several
    # certificates and `openssl x509 -in bundle` only ever reports the
    # first, so asking it directly would say the bootstrap CA was gone
    # the moment the PKI CA was prepended — regardless of the truth.
    BUNDLE_SUBJECTS=""
    BLOCK=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        BLOCK+="${line}"$'\n'
        if [[ "$line" == *"END CERTIFICATE"* ]]; then
            BUNDLE_SUBJECTS+="$(openssl x509 -noout -subject 2>/dev/null <<< "$BLOCK" || true)"$'\n'
            BLOCK=""
        fi
    done < "${TLS_DIR}/ca.crt"
    if [[ "$BUNDLE_SUBJECTS" != *"$BOOTSTRAP_CA_SUBJECT"* ]]; then
        ok "the bootstrap CA has been pruned from the trust bundle"
    else
        bad "the bootstrap CA has been pruned from the trust bundle" \
            "still present: ${BOOTSTRAP_CA_SUBJECT}"
    fi
else
    bad "the bootstrap CA has been pruned from the trust bundle" "could not read the original subject"
fi

# The cluster has to have survived all of it.
VOTERS_MIG="$(vault operator raft list-peers -format=json 2>/dev/null \
    | jq '[.data.config.servers[]? | select(.voter == true)] | length' 2>/dev/null || echo 0)"
if [[ "$VOTERS_MIG" == "3" ]]; then
    ok "all three peers are still voters after the migration"
else
    bad "all three peers are still voters after the migration" "got ${VOTERS_MIG}"
fi

CANARY_MIG="$(vault kv get -field=value itest/canary 2>/dev/null || echo "")"
if [[ "$CANARY_MIG" == "before-cert-swap" ]]; then
    ok "and data written before it is still readable"
else
    bad "and data written before it is still readable" "got '${CANARY_MIG}'"
fi

# Re-running is a no-op: every node is already on PKI, so there is
# nothing to swap and the prune guard is satisfied.
if "${REPO_ROOT}/scripts/migrate-to-vault-pki.sh" \
        --nodes "vault-0=127.0.0.1:8200,vault-1=127.0.0.1:8210,vault-2=127.0.0.1:8220" \
        --tls-dir "$TLS_DIR" --domain vault.internal --key-mode 0644 \
        --reload-cmd "${WORK}/migrate-reload.sh {node}" \
        --phase swap >"${WORK}/migrate2.log" 2>&1 \
        && grep -q "already serving a PKI certificate" "${WORK}/migrate2.log"; then
    ok "re-running the swap phase is a no-op"
else
    bad "re-running the swap phase is a no-op" "$(tail -5 "${WORK}/migrate2.log")"
fi

# Vault is not the only thing that reads the trust bundle. Prometheus and
# the blackbox exporter both bind-mount docker/dev/tls/ca.crt to verify
# the TLS of the nodes they scrape and probe, and both read it once at
# startup. The prune above replaced it, so until they are restarted they
# are validating against a bootstrap CA that no longer signs anything:
# the blackbox probe fails, probe_ssl_earliest_cert_expiry stops being
# reported, and certificate expiry goes unmonitored without an error
# anywhere. The assertion further down caught exactly that.
#
# Restarting them here is the documented remedy, and running it before
# that assertion is what makes the assertion proof that the remedy works.
info "Restarting monitoring so it reloads the new trust bundle..."
compose restart prometheus blackbox >/dev/null 2>&1 \
    || info "  (could not restart monitoring; probe assertions may fail)"
sleep 10

# ---------------------------------------------------------------------------
info ""
info "=== The cluster survived the swap ==="
# ---------------------------------------------------------------------------
CODE="$(alive_code 8200)"
if [[ "$CODE" == "200" || "$CODE" == "429" ]]; then
    ok "vault-0 is still healthy and unsealed (${CODE})"
else
    bad "vault-0 is still healthy and unsealed" "health returned ${CODE}"
fi

SEALED="$(vault status -format=json 2>/dev/null | jq -r 'if has("sealed") then .sealed else true end' || true)"
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
info "=== Dynamic database credentials ==="
# ---------------------------------------------------------------------------
# The claim: the credential does not exist until it is asked for, works,
# is scoped, and dies. None of that can be shown with a shim — a shim can
# only confirm the right API calls were made. Here the credentials are
# used against the database they were minted for.

# psql <user> <password> <sql> — run SQL as a specific role.
psql_as() {
    # stderr is kept, because the interesting answers arrive there:
    # "permission denied" is how a readonly role proves it is readonly.
    #
    # But docker compose writes its own diagnostics to the same stream,
    # and one of them — the obsolete-`version` warning — silently
    # prefixed every result and turned a passing query into a failed
    # assertion. Filtered by `level=` rather than by that one message,
    # since any future compose warning would break this identically.
    # Over the service name, not loopback. initdb gives 127.0.0.1 a trust
    # rule, so a loopback connection accepts any password at all — which
    # would make the root-rotation assertion below meaningless.
    compose exec -T -e PGPASSWORD="$2" postgres \
        psql -h postgres -U "$1" -d appdata -tAc "$3" 2>&1 \
        | grep -v 'level=' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$' || true
}

BOOTSTRAP_PW="bootstrap-only-rotated-immediately"

# A table for the grants to mean something. Created before the engine is
# configured so both roles see it.
psql_as vaultadmin "$BOOTSTRAP_PW"     "CREATE TABLE IF NOT EXISTS widgets (id int); INSERT INTO widgets VALUES (1);" >/dev/null 2>&1 || true

if "${REPO_ROOT}/scripts/bootstrap-database-secrets.sh"         --host postgres:5432         --password "$BOOTSTRAP_PW"         --default-ttl 1h         >"${WORK}/dbsecrets.log" 2>&1; then
    ok "bootstrap-database-secrets.sh configured the engine"
else
    bad "bootstrap-database-secrets.sh configured the engine" "log follows"
    sed 's/^/        /' "${WORK}/dbsecrets.log"
fi

CREDS_A="$(vault read -format=json database/creds/appdata-readonly 2>/dev/null || true)"
USER_A="$(jq -r '.data.username // empty' <<< "${CREDS_A:-{\}}" 2>/dev/null || true)"
PASS_A="$(jq -r '.data.password // empty' <<< "${CREDS_A:-{\}}" 2>/dev/null || true)"
LEASE_A="$(jq -r '.lease_id // empty' <<< "${CREDS_A:-{\}}" 2>/dev/null || true)"

if [[ -n "$USER_A" && -n "$PASS_A" ]]; then
    ok "Vault issued a credential"
else
    bad "Vault issued a credential" "$(head -3 "${WORK}/dbsecrets.log" 2>/dev/null)"
fi

# The whole point: every consumer gets its own. If two reads returned the
# same user this would be a shared password with extra steps.
CREDS_B="$(vault read -format=json database/creds/appdata-readonly 2>/dev/null || true)"
USER_B="$(jq -r '.data.username // empty' <<< "${CREDS_B:-{\}}" 2>/dev/null || true)"
PASS_B="$(jq -r '.data.password // empty' <<< "${CREDS_B:-{\}}" 2>/dev/null || true)"
if [[ -n "$USER_B" && "$USER_B" != "$USER_A" ]]; then
    ok "a second read returns a different user"
else
    bad "a second read returns a different user" "both were '${USER_A}'"
fi

# It has to actually work, not merely be returned.
if [[ "$(psql_as "$USER_A" "$PASS_A" "SELECT 1;")" == "1" ]]; then
    ok "the issued credential can connect and query"
else
    bad "the issued credential can connect and query" "$(psql_as "$USER_A" "$PASS_A" "SELECT 1;")"
fi

# And the grants have to be real. A readonly role that can write is a
# readonly role in name only.
WRITE_OUT="$(psql_as "$USER_A" "$PASS_A" "INSERT INTO widgets VALUES (2);")"
if [[ "$WRITE_OUT" == *"permission denied"* ]]; then
    ok "the readonly credential cannot write"
else
    bad "the readonly credential cannot write" "insert returned: ${WRITE_OUT}"
fi

CREDS_RW="$(vault read -format=json database/creds/appdata-readwrite 2>/dev/null || true)"
USER_RW="$(jq -r '.data.username // empty' <<< "${CREDS_RW:-{\}}" 2>/dev/null || true)"
PASS_RW="$(jq -r '.data.password // empty' <<< "${CREDS_RW:-{\}}" 2>/dev/null || true)"
RW_OUT="$(psql_as "$USER_RW" "$PASS_RW" "INSERT INTO widgets VALUES (3); SELECT count(*) FROM widgets;")"
if [[ "$RW_OUT" != *"permission denied"* && -n "$USER_RW" ]]; then
    ok "the readwrite credential can write"
else
    bad "the readwrite credential can write" "insert returned: ${RW_OUT}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Revocation actually revokes ==="
# ---------------------------------------------------------------------------
# A lease that expires in Vault but leaves the account alive in the
# database is the worst outcome here: it looks managed and is not.
if [[ -n "$LEASE_A" ]] && vault lease revoke "$LEASE_A" >/dev/null 2>&1; then
    ok "the lease was revoked"
else
    bad "the lease was revoked" "lease id was '${LEASE_A}'"
fi

sleep 2
REVOKED_OUT="$(psql_as "$USER_A" "$PASS_A" "SELECT 1;")"
if [[ "$REVOKED_OUT" != "1" ]]; then
    ok "the revoked credential can no longer connect"
else
    bad "the revoked credential can no longer connect" "it still works"
fi

# Gone from the database, not merely unable to log in.
# Asked using a *live* Vault-issued credential, not the bootstrap
# account — by this point root rotation has run and the bootstrap
# password is correctly dead. pg_roles is a public catalog view, so an
# ordinary credential can answer this, and using one keeps the check
# working regardless of what happened to the admin password.
ROLE_LEFT="$(psql_as "$USER_B" "$PASS_B"     "SELECT count(*) FROM pg_roles WHERE rolname = '${USER_A}';")"
if [[ "$ROLE_LEFT" == "0" ]]; then
    ok "and the role is dropped from Postgres entirely"
else
    bad "and the role is dropped from Postgres entirely" "pg_roles still has it (count=${ROLE_LEFT})"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Root rotation ==="
# ---------------------------------------------------------------------------
# After bootstrap, nobody knows the password to the account Vault connects
# with — not the operator who ran the script, not this test. That is the
# end state dynamic secrets are for, and it is only demonstrable against a
# real database.
# Control first. Under a trust rule Postgres accepts *any* password, so
# the assertion after this one would pass or fail for reasons having
# nothing to do with rotation. Proving a bogus password is rejected is
# what makes the next line evidence rather than decoration.
WRONG_OUT="$(psql_as vaultadmin "definitely-not-the-password" "SELECT 1;")"
if [[ "$WRONG_OUT" != "1" ]]; then
    ok "a wrong password is rejected, so the next check means something"
else
    bad "a wrong password is rejected, so the next check means something" \
        "Postgres accepted a bogus password — auth is not enforced on this path"
fi

ROOT_OUT="$(psql_as vaultadmin "$BOOTSTRAP_PW" "SELECT 1;")"
if [[ "$ROOT_OUT" != "1" ]]; then
    ok "the bootstrap password no longer works"
else
    bad "the bootstrap password no longer works" \
        "the password in docker-compose.yml still authenticates — rotate-root did not run"
fi

# And Vault can still issue, which is what makes the rotation safe rather
# than merely destructive.
if vault read -format=json database/creds/appdata-readonly >/dev/null 2>&1; then
    ok "but Vault can still issue credentials"
else
    bad "but Vault can still issue credentials" "rotation broke the connection"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Audit devices ==="
# ---------------------------------------------------------------------------
# The question an audit log exists to answer is "who read that secret".
# Checking the file exists does not answer it; reading the entry back out
# and finding the request in it does.

# file primary + socket secondary: the pairing HashiCorp recommend, and
# the only arrangement where killing one device demonstrates anything.
# Two files on one filesystem fail together.
if "${REPO_ROOT}/scripts/bootstrap-audit.sh" \
        --second-type socket \
        --second-address audit-collector:9090 \
        >"${WORK}/audit.log" 2>&1; then
    ok "bootstrap-audit.sh enabled the audit devices"
else
    bad "bootstrap-audit.sh enabled the audit devices" "log follows"
    sed 's/^/        /' "${WORK}/audit.log"
fi

AUDIT_N="$(vault audit list -format=json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
if [[ "${AUDIT_N:-0}" -ge 2 ]]; then
    ok "two devices are enabled (one failing must not stop Vault)"
else
    bad "two devices are enabled" "found ${AUDIT_N:-0}; Vault refuses requests when it cannot write to any device"
fi

# audit_cat <file> — read an audit log out of the vault-0 container.
audit_cat() {
    compose exec -T vault-0 cat "$1" 2>/dev/null | grep -v 'level=' || true
}

# A request with a recognisable path, so it can be found again.
vault kv put itest/audit-canary value=look-for-me >/dev/null 2>&1 || true
sleep 1

PRIMARY=/vault/audit/vault-audit.log
AUDIT_TEXT="$(audit_cat "$PRIMARY")"

if [[ -n "$AUDIT_TEXT" ]]; then
    ok "the primary device is writing entries"
else
    bad "the primary device is writing entries" "${PRIMARY} is empty or unreadable"
fi

if [[ "$AUDIT_TEXT" == *"itest/audit-canary"* ]]; then
    ok "and the request path appears in the log"
else
    bad "and the request path appears in the log" "no entry for itest/audit-canary"
fi

# Both devices receive every entry. If the secondary is empty, the
# redundancy the two-device design depends on is not actually there.
SECOND_TEXT="$(compose exec -T audit-collector cat /tmp/audit-socket.log 2>/dev/null | grep -v 'level=' || true)"
if [[ "$SECOND_TEXT" == *"itest/audit-canary"* ]]; then
    ok "and the socket device delivered the same entry to the collector"
else
    # Enabling a socket device only proves the TCP listener accepted a
    # connection. Whether the collector then managed to write is a
    # separate question, and its own logs are the only place it is
    # answered — so print them rather than guessing.
    bad "and the socket device delivered the same entry to the collector" \
        "enabled but nothing arrived; collector logs follow"
    compose logs --tail=15 audit-collector 2>&1 | sed 's/^/        /' || true
fi

# ---------------------------------------------------------------------------
info ""
info "=== Losing one device does not stop Vault ==="
# ---------------------------------------------------------------------------
# The reason for two devices, demonstrated rather than asserted. Vault
# refuses to serve when it cannot write to ANY enabled device; with the
# collector dead the file device still satisfies that, so requests keep
# working. Two files on one filesystem could not show this — they fail
# together, which is why the secondary here is a socket.
info "  stopping the audit collector..."
compose stop audit-collector >/dev/null 2>&1 || true
sleep 3

# A TCP socket device drops a single entry on connection loss and the
# request still succeeds, so write twice before drawing a conclusion.
vault kv put itest/after-collector-loss value=one >/dev/null 2>&1 || true
sleep 2
WROTE_AFTER=0
vault kv put itest/after-collector-loss value=two >/dev/null 2>&1 && WROTE_AFTER=1

if [[ "$WROTE_AFTER" == "1" ]]; then
    ok "Vault still accepts writes with one audit device dead"
else
    bad "Vault still accepts writes with one audit device dead" \
        "the surviving file device should have satisfied the at-least-one guarantee"
fi

CODE="$(alive_code 8200)"
if [[ "$CODE" == "200" || "$CODE" == "429" ]]; then
    ok "and it is still healthy (${CODE})"
else
    bad "and it is still healthy" "health returned ${CODE}"
fi

# And the surviving device kept recording. Serving requests that no audit
# device captured would be worse than refusing them.
SURVIVOR="$(audit_cat "$PRIMARY")"
if [[ "$SURVIVOR" == *"itest/after-collector-loss"* ]]; then
    ok "and the surviving device still recorded the request"
else
    bad "and the surviving device still recorded the request" \
        "Vault served a request that no audit device captured"
fi

info "  restarting the audit collector..."
compose start audit-collector >/dev/null 2>&1 || true
sleep 3

# ---------------------------------------------------------------------------
info ""
info "=== The log is safe to ship ==="
# ---------------------------------------------------------------------------
# Audit entries HMAC sensitive values rather than recording them. If that
# were not true, shipping these logs to a central collector would be
# copying every secret in Vault to a second, less protected place.
if [[ "$AUDIT_TEXT" == *"look-for-me"* ]]; then
    bad "the secret value is NOT in the audit log"         "found the plaintext value — log_raw is on, or hashing is not working"
else
    ok "the secret value is not in the audit log"
fi

if [[ "$AUDIT_TEXT" == *"hmac-sha256:"* ]]; then
    ok "values are recorded as hmac-sha256 digests"
else
    bad "values are recorded as hmac-sha256 digests" "no hmac prefix found in the log"
fi

# The root token is in the request headers of every call made above. It
# must be hashed too — an audit log containing a usable root token is a
# credential store with extra steps.
if [[ "$AUDIT_TEXT" == *"$ROOT_TOKEN"* ]]; then
    bad "the root token is NOT in the audit log" "found the token in clear text"
else
    ok "the root token is not in the audit log"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Rotation ==="
# ---------------------------------------------------------------------------
# Vault holds the file open, so rotating means moving it and signalling.
# Without the signal Vault keeps writing to the moved inode and the new
# file stays empty — the log looks rotated and nothing lands in it.
compose exec -T vault-0 sh -c "mv ${PRIMARY} ${PRIMARY}.rotated" >/dev/null 2>&1 || true
compose kill -s HUP vault-0 >/dev/null 2>&1 || true
sleep 3

vault kv put itest/audit-after-rotate value=post >/dev/null 2>&1 || true
sleep 2

ROTATED_NEW="$(audit_cat "$PRIMARY")"
if [[ "$ROTATED_NEW" == *"itest/audit-after-rotate"* ]]; then
    ok "SIGHUP reopens the log and writes continue to the new file"
else
    bad "SIGHUP reopens the log and writes continue to the new file"         "nothing landed in the reopened path — rotation would silently lose entries"
fi

# And Vault stayed up through it. A rotation that costs availability is
# not a rotation anyone will run on a schedule.
CODE="$(alive_code 8200)"
if [[ "$CODE" == "200" || "$CODE" == "429" ]]; then
    ok "and Vault kept serving throughout (${CODE})"
else
    bad "and Vault kept serving throughout" "health returned ${CODE}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A bad device fails at enable time, not at request time ==="
# ---------------------------------------------------------------------------
# Vault writes a test entry when a device is enabled, so an unwritable
# path is rejected immediately. That matters: the alternative is a device
# that enables cleanly and then blocks every request afterwards.
if vault audit enable -path=badpath file file_path=/nonexistent/dir/audit.log >/dev/null 2>&1; then
    bad "an unwritable audit path is rejected" "Vault accepted a device it cannot write to"
    vault audit disable badpath >/dev/null 2>&1 || true
else
    ok "an unwritable audit path is rejected at enable time"
fi

# And the rejection did not take Vault with it.
CODE="$(alive_code 8200)"
if [[ "$CODE" == "200" || "$CODE" == "429" ]]; then
    ok "and the rejected device left Vault serving (${CODE})"
else
    bad "and the rejected device left Vault serving" "health returned ${CODE}"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Alerting on absence ==="
# ---------------------------------------------------------------------------
# The rule unit tests prove the expressions behave correctly against
# synthetic series. What they cannot show is whether the metrics those
# rules name actually exist — and an alert on a metric nobody reports is
# permanently silent, which is the failure mode this whole rule file was
# written for.

prom() {
    curl -sS --max-time 10 "http://127.0.0.1:9090/api/v1/$1" 2>/dev/null || echo '{}'
}

# Wait for Prometheus to have scraped at least once.
for _ in $(seq 1 30); do
    [[ "$(prom 'query?query=up' | jq -r '.status // empty' 2>/dev/null)" == "success" ]] && break
    sleep 2
done

RULE_COUNT="$(prom 'rules' | jq '[.data.groups[]?.rules[]? | select(.type=="alerting")] | length' 2>/dev/null || echo 0)"
if [[ "${RULE_COUNT:-0}" -ge 8 ]]; then
    ok "Prometheus loaded ${RULE_COUNT} alerting rules"
else
    bad "Prometheus loaded the alerting rules" "found ${RULE_COUNT:-0} — is rule_files pointing at the right path?"
fi

# Every metric the rules name must actually be reported by something. A
# typo or a metric renamed between Vault versions produces a rule that
# parses, loads, and can never fire.
for metric in vault_core_unsealed vault_core_active; do
    N="$(prom "query?query=${metric}" | jq '.data.result | length' 2>/dev/null || echo 0)"
    if [[ "${N:-0}" -gt 0 ]]; then
        ok "${metric} is being reported (${N} series)"
    else
        bad "${metric} is being reported"             "no series — every rule naming this metric is permanently silent"
    fi
done

# The TLS probe: certificate expiry measured from what is served.
PROBE_N="$(prom 'query?query=probe_ssl_earliest_cert_expiry' | jq '.data.result | length' 2>/dev/null || echo 0)"
if [[ "${PROBE_N:-0}" -gt 0 ]]; then
    ok "probe_ssl_earliest_cert_expiry is being reported (${PROBE_N} series)"
else
    bad "probe_ssl_earliest_cert_expiry is being reported"         "the blackbox probe is not working, so certificate expiry is unmonitored"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A missing backup actually pages someone ==="
# ---------------------------------------------------------------------------
# Nothing has pushed a snapshot metric, so the series does not exist.
# VaultSnapshotStale cannot fire — it has nothing to evaluate — and
# VaultSnapshotMetricMissing is what must speak instead. This is the
# whole design, observed end to end rather than in a unit test.
info "  waiting for VaultSnapshotMetricMissing to fire (for: 2m)..."
FIRING=""
for _ in $(seq 1 75); do
    FIRING="$(prom 'alerts' | jq -r '[.data.alerts[]? | select(.labels.alertname=="VaultSnapshotMetricMissing" and .state=="firing")] | length' 2>/dev/null || echo 0)"
    [[ "${FIRING:-0}" -gt 0 ]] && break
    sleep 2
done

if [[ "${FIRING:-0}" -gt 0 ]]; then
    ok "VaultSnapshotMetricMissing fires when nothing reports a snapshot"
else
    bad "VaultSnapshotMetricMissing fires when nothing reports a snapshot"         "state: $(prom 'alerts' | jq -c '[.data.alerts[]? | {alertname: .labels.alertname, state}]' 2>/dev/null)"
fi

# And it must reach Alertmanager. A rule that fires and reaches nobody is
# the same class of problem as a backup nobody takes.
DELIVERED=""
for _ in $(seq 1 30); do
    DELIVERED="$(curl -sS --max-time 10 'http://127.0.0.1:9093/api/v2/alerts' 2>/dev/null         | jq -r '[.[]? | select(.labels.alertname=="VaultSnapshotMetricMissing")] | length' 2>/dev/null || echo 0)"
    [[ "${DELIVERED:-0}" -gt 0 ]] && break
    sleep 2
done

if [[ "${DELIVERED:-0}" -gt 0 ]]; then
    ok "and it reaches Alertmanager"
else
    bad "and it reaches Alertmanager" "Prometheus fired it but Alertmanager never received it"
fi

# Now record a snapshot and watch the alert clear. An alert that fires and
# never resolves is one people learn to ignore.
if "${REPO_ROOT}/scripts/snapshot.sh" --cloud none --output-dir "${WORK}/alerting-snap"         --metrics-push http://127.0.0.1:9091 >"${WORK}/push.log" 2>&1; then
    ok "snapshot.sh recorded a success to the pushgateway"
else
    bad "snapshot.sh recorded a success to the pushgateway" "$(tail -3 "${WORK}/push.log")"
fi

PUSHED=""
for _ in $(seq 1 30); do
    PUSHED="$(prom 'query?query=vault_snapshot_last_success_timestamp_seconds' | jq '.data.result | length' 2>/dev/null || echo 0)"
    [[ "${PUSHED:-0}" -gt 0 ]] && break
    sleep 2
done

if [[ "${PUSHED:-0}" -gt 0 ]]; then
    ok "and Prometheus can now see the snapshot metric"
else
    bad "and Prometheus can now see the snapshot metric"         "the push did not land, so the absence alert would never clear"
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
