#!/usr/bin/env bash
#
# run-tests.sh — Tests for the Vault PKI migration driver
#
# Usage:
#   ./tests/pki-migration/run-tests.sh
#
# Runs in a couple of seconds. No cluster.
#
# scripts/migrate-to-vault-pki.sh sequences a certificate rollout across a
# live cluster. Almost every way it can go wrong ends with nodes refusing
# each other, which presents as a network fault and gets diagnosed as one.
#
# So the cases here are mostly about ordering and refusal:
#
#   - the trust phase must complete before anything swaps
#   - the swap must stop at the first node that does not come back
#   - the prune must refuse while any node still serves a bootstrap
#     certificate, because that is the step that partitions the cluster
#
# Whether the rollout actually works against real Vault is tests/integration.
#
# Requirements: bash, jq, python3, openssl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MIGRATE="${REPO_ROOT}/scripts/migrate-to-vault-pki.sh"
FAKE_BIN="${SCRIPT_DIR}/fake-bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export FIXTURES="${WORK}/fixtures"

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

NODES="vault-0=127.0.0.1:8200,vault-1=127.0.0.1:8210,vault-2=127.0.0.1:8220"

RC=0
OUT=""
LOG=""

reset_scenario() {
    export FAKE_VOTERS=3
    export FAKE_PKI_READY=true
    export FAKE_DEFAULT_ISSUER=bootstrap
    export FAKE_NODE_ISSUERS=""
    export FAKE_NODE_HEALTH=""
    # What each node currently serves, and what the role will not sign.
    # Both default to the permissive case so a test that does not care
    # about SANs is not quietly testing them.
    export FAKE_NODE_SANS=""
    export FAKE_DEFAULT_SANS="DNS:localhost|IP:127.0.0.1"
    export FAKE_ROLE_REFUSES=""
    # The serial real Vault returns from an issue, and whether revoking it
    # works. An empty serial is a response the driver cannot undo.
    export FAKE_ISSUE_SERIAL="3f:9c:12:aa:7b:04:e1:55"
    export FAKE_REVOKE_RC=0
    export FAKE_ACTIVE_ADDR="127.0.0.1:8200"
    export FAKE_DEFAULT_HEALTH=429
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_TOKEN=s.testtoken
    # The stub issue-node-cert.sh records what it was asked to do.
    : > "${WORK}/issue-calls.log"
    export FAKE_ISSUE_RC=0
    unset FAKE_VOTERS_DROP_AFTER FAKE_ISSUE_FAIL_ON 2>/dev/null || true
}

run_migrate() {
    local logfile="${WORK}/calls.log"
    : > "$logfile"
    # The voter-drop counter lives beside the call log. Leaving it in
    # place made every later run start mid-drop, which is how the first
    # version of this suite reported a two-voter cluster throughout.
    rm -f "${logfile}.votercalls"
    RC=0
    OUT="$(FAKE_LOG="$logfile" ISSUE_LOG="${WORK}/issue-calls.log" \
        PATH="${FAKE_BIN}:${WORK}/bin:${PATH}" \
        "$MIGRATE" --nodes "$NODES" --tls-dir "${WORK}/tls"         --issue-script "$ISSUE_STUB" --health-retries 2 "$@" 2>&1)" || RC=$?
    LOG="$(cat "$logfile")"
    ISSUE_LOG="$(cat "${WORK}/issue-calls.log" 2>/dev/null || true)"
}

assert_rc()   { if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1" "expected ${2}, got ${RC}: ${OUT}"; fi; }
assert_says() { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1" "output lacked: ${2}"; fi; }
assert_lacks() { if [[ "$OUT" != *"$2"* ]]; then ok "$1"; else bad "$1" "output contained: ${2}"; fi; }
issue_has()   { if [[ "$ISSUE_LOG" == *"$2"* ]]; then ok "$1"; else bad "$1" "no issue call matching: ${2}"; fi; }
issue_lacks() { if [[ "$ISSUE_LOG" != *"$2"* ]]; then ok "$1"; else bad "$1" "unexpected issue call: ${2}"; fi; }
log_has()     { if [[ "$LOG" == *"$2"* ]]; then ok "$1"; else bad "$1" "no vault call matching: ${2}"; fi; }
# Pinned by count, not by presence: "a revoke happened" passes against a
# driver that revokes one of three test certificates and leaks the rest.
log_count()   {
    local n
    n="$(grep -cF -- "$3" <<< "$LOG" || true)"
    if [[ "$n" == "$2" ]]; then ok "$1"; else bad "$1" "expected ${2} vault calls matching '${3}', got ${n}"; fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for dep in jq python3 openssl; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done
[[ -x "$MIGRATE" ]] || { red "ERROR: ${MIGRATE} is not executable"; exit 1; }

FAKE_REAL_OPENSSL="$(command -v openssl)"
export FAKE_REAL_OPENSSL

# A real CA certificate, so the driver's subject lookup is genuine.
mkdir -p "$FIXTURES" "${WORK}/tls" "${WORK}/bin"
( cd "$FIXTURES"
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 30 \
      -keyout pkica.key -out pkica.crt -subj "/CN=vault pki CA" 2>/dev/null )

# Read the fixture's subject with the same binary the driver will use, and
# hand it to the openssl shim. The shim used to hardcode "CN=vault pki CA",
# which matched the author's openssl and not CI's: OpenSSL 3.0 renders the
# same DN as "CN = vault pki CA". Every node then read as un-migrated and
# the prune cases failed for a reason with nothing to do with the driver.
FAKE_PKI_ISSUER="$("$FAKE_REAL_OPENSSL" x509 -in "${FIXTURES}/pkica.crt" \
    -noout -subject 2>/dev/null | sed 's/^subject= *//')"
export FAKE_PKI_ISSUER

if [[ -n "$FAKE_PKI_ISSUER" ]]; then
    ok "the fixture subject was read with the driver's own openssl"
else
    red "ERROR: could not read the fixture CA subject"; exit 1
fi

# A stand-in for issue-node-cert.sh. The driver's job is orchestration —
# what it calls, in what order, and when it stops — so the thing being
# orchestrated is replaced with something that records and obeys.
cat > "${WORK}/bin/issue-node-cert.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf 'issue %s\n' "$*" >> "${ISSUE_LOG}"
# FAKE_ISSUE_FAIL_ON names a --cert-name whose swap should fail.
if [[ -n "${FAKE_ISSUE_FAIL_ON:-}" && "$*" == *"--cert-name ${FAKE_ISSUE_FAIL_ON}"* && "$*" != *"--ca-only"* ]]; then
    echo "issue-node-cert: simulated failure" >&2
    exit 1
fi
exit "${FAKE_ISSUE_RC:-0}"
STUB
chmod +x "${WORK}/bin/issue-node-cert.sh"

# The driver resolves the issuer script next to itself, so it is pointed
# at the stub with --issue-script rather than relying on PATH order.
ISSUE_STUB="${WORK}/bin/issue-node-cert.sh"

# A stand-in for --node-exec. It records the node and the entire argv it
# was handed, one line per call, so the per-node invocation can be pinned
# exactly. "Does not contain --reload-cmd" would pass against a driver
# that passed nothing at all, or the wrong path, or no node.
cat > "${WORK}/bin/node-exec" <<'EXEC'
#!/usr/bin/env bash
set -uo pipefail
node="$1"; shift
printf 'exec %s :: %s
' "$node" "$*" >> "${ISSUE_LOG}"
exit "${FAKE_EXEC_RC:-0}"
EXEC
chmod +x "${WORK}/bin/node-exec"
NODE_EXEC_STUB="${WORK}/bin/node-exec {node}"

if PATH="${FAKE_BIN}:${PATH}" command -v vault | grep -q "fake-bin"; then
    ok "the vault shim shadows any real vault on PATH"
else
    red "ERROR: fake-bin is not being resolved first"; exit 1
fi

# ---------------------------------------------------------------------------
printf '\n=== Argument handling ===\n'
# ---------------------------------------------------------------------------
reset_scenario
RC=0; OUT="$(PATH="${FAKE_BIN}:${PATH}" "$MIGRATE" 2>&1)" || RC=$?
if [[ $RC -ne 0 && "$OUT" == *"--nodes is required"* ]]; then
    ok "rejects a missing --nodes"
else
    bad "rejects a missing --nodes" "got ${RC}: ${OUT}"
fi

reset_scenario
run_migrate --phase nonsense
assert_rc   "rejects an unknown phase" 1
assert_says "and lists the valid ones" "must be trust, swap, prune, or all"

reset_scenario
RC=0; OUT="$(PATH="${FAKE_BIN}:${PATH}" "$MIGRATE" --nodes "vault-0" 2>&1)" || RC=$?
if [[ $RC -ne 0 && "$OUT" == *"Malformed node spec"* ]]; then
    ok "rejects a node spec with no address"
else
    bad "rejects a node spec with no address" "got ${RC}: ${OUT}"
fi

reset_scenario
export FAKE_PKI_READY=false
run_migrate --dry-run
assert_rc   "refuses when the PKI mount has no CA" 1
assert_says "and says to bootstrap it first"       "bootstrap-pki.sh"

# ---------------------------------------------------------------------------
printf '\n=== The plan is shown before anything changes ===\n'
# ---------------------------------------------------------------------------
reset_scenario
run_migrate --dry-run
assert_rc     "a dry run succeeds"      0
assert_says   "and says it changed nothing" "nothing was changed"
issue_lacks   "and calls nothing"       "issue"

# The active node is touched last, so a run that fails partway leaves the
# leader on the configuration it started with.
assert_says "the plan puts the active node last" "vault-1 vault-2 vault-0"

# ---------------------------------------------------------------------------
printf '\n=== Trust comes before any swap ===\n'
# ---------------------------------------------------------------------------
# The ordering the whole script exists for. A node that presents a PKI
# certificate before its peers trust that CA is a node its peers refuse.
reset_scenario
run_migrate --phase trust
assert_rc "the trust phase succeeds" 0
issue_has "it updates every node's bundle" "--ca-only"

for n in vault-0 vault-1 vault-2; do
    if [[ "$ISSUE_LOG" == *"--cert-name ${n}"* ]]; then
        ok "${n}'s bundle is updated"
    else
        bad "${n}'s bundle is updated"
    fi
done

# --ca-only issues nothing. If the trust phase ever swapped a
# certificate, it would be doing the dangerous half of the migration
# before the safe half.
issue_lacks "the trust phase issues no certificate" "--common-name"
issue_lacks "and replaces no trust bundle"          "--replace-ca"

# ---------------------------------------------------------------------------
printf '\n=== The swap stops at the first node that fails ===\n'
# ---------------------------------------------------------------------------
# Continuing past a node that did not come back is how one bad
# certificate becomes an outage.
reset_scenario
export FAKE_ISSUE_FAIL_ON=vault-1
run_migrate --phase swap
assert_rc   "a failed swap aborts the run" 1
assert_says "and says the rest are untouched" "untouched"
issue_lacks "and never reaches the active node" "--cert-name vault-0 "

# A node that is unhealthy afterwards stops the run just as firmly, even
# though the swap command itself succeeded.
# Driven through the trust phase for the same reason as the voter case:
# the swap path checks the served certificate before it reaches the gate,
# so an unhealthy node would abort on that check instead and this
# assertion would pass without the health gate existing at all. It did,
# until a mutation that deleted the health check changed nothing.
reset_scenario
export FAKE_NODE_HEALTH="127.0.0.1:8210=503"
run_migrate --phase trust
assert_rc   "a node that does not come back healthy aborts" 1
assert_says "and names the node"                            "vault-1"
assert_says "and says the rest are untouched"               "untouched"

# Losing a voter is the other way a swap goes wrong: the node answers
# health checks but has dropped out of the cluster.
# Losing a voter is the other way a swap goes wrong: the node answers
# health checks but has dropped out of the cluster, so the next swap
# would be taking a second node out of a cluster already down to two.
# Driven through the trust phase rather than the swap: the swap checks
# that a node is serving a PKI certificate before it reaches the gate, so
# it would abort on that instead and this assertion would pass for the
# wrong reason.
reset_scenario
export FAKE_VOTERS_DROP_AFTER=2
run_migrate --phase trust
assert_rc   "a voter dropping mid-run aborts" 1
assert_says "and reports the drop"            "Voter count dropped"

# ---------------------------------------------------------------------------
printf '\n=== The prune refuses while any node is still on bootstrap ===\n'
# ---------------------------------------------------------------------------
# This is the step that partitions a cluster. Dropping the bootstrap CA
# while any node still presents a certificate signed by it makes every
# other node refuse that peer.
reset_scenario
export FAKE_DEFAULT_ISSUER=pki
export FAKE_NODE_ISSUERS="127.0.0.1:8220=bootstrap"
run_migrate --phase prune
assert_rc   "prune refuses with a laggard"      1
assert_says "and names the node holding it up"  "vault-2"
assert_says "and explains the consequence"      "reject"
issue_lacks "and changes nothing"               "--replace-ca"

# Checked against what each node *serves*, not what is on its disk: a
# certificate written and never reloaded is not migrated.
reset_scenario
export FAKE_DEFAULT_ISSUER=none
run_migrate --phase prune
assert_rc   "prune refuses when a node serves nothing readable" 1
issue_lacks "and changes nothing"                                "--replace-ca"

reset_scenario
export FAKE_DEFAULT_ISSUER=pki
run_migrate --phase prune
assert_rc "prune proceeds once every node is on PKI" 0
issue_has "and replaces the bundle"                  "--replace-ca"
issue_has "on every node"                            "--cert-name vault-2"

# ---------------------------------------------------------------------------
printf '\n=== A full run does the phases in order ===\n'
# ---------------------------------------------------------------------------
reset_scenario
export FAKE_DEFAULT_ISSUER=pki
run_migrate
assert_rc "a full run succeeds when every node is already on PKI" 0

# Order matters more than presence: the first --replace-ca must come
# after the last --ca-only trust update.
FIRST_REPLACE="$(grep -n -m1 -- '--replace-ca' <<< "$ISSUE_LOG" | cut -d: -f1 || echo 0)"
FIRST_ANY="$(grep -n -m1 -- '--ca-only' <<< "$ISSUE_LOG" | cut -d: -f1 || echo 0)"
if [[ "${FIRST_REPLACE:-0}" -gt "${FIRST_ANY:-0}" && "${FIRST_ANY:-0}" -gt 0 ]]; then
    ok "trust updates happen before the bundle is replaced"
else
    bad "trust updates happen before the bundle is replaced" \
        "first --ca-only at line ${FIRST_ANY}, first --replace-ca at ${FIRST_REPLACE}"
fi


# ---------------------------------------------------------------------------
printf '\n=== Per-node mode: the work runs on the node ===\n'
# ---------------------------------------------------------------------------
# Until --node-exec existed this driver could not migrate a cloud cluster
# at all: it would have issued three certificates into the operator's own
# /etc/vault.d/tls, reloaded nothing, and reported success three times.
reset_scenario
export FAKE_DEFAULT_ISSUER=pki
run_migrate --node-exec "$NODE_EXEC_STUB" --phase trust
assert_rc   "a trust phase runs per node" 0
assert_says "and the plan says which mode it is in" "Mode:    per node"

# Pinned, not grepped. This is the whole argv for one node, so a flag
# appearing that should not -- or the remote path being wrong, or {node}
# not being substituted -- fails here.
issue_has "vault-0's work runs on vault-0, with the node's own defaults" \
          "exec vault-0 :: /usr/local/bin/vault-issue-node-cert.sh --ca-only --mount pki"
issue_has "and so does vault-2's" \
          "exec vault-2 :: /usr/local/bin/vault-issue-node-cert.sh --ca-only --mount pki"

# The operator's flags are the wrong flags on a node, and each of these
# would be wrong in its own way: --tls-dir is this machine's, the file on
# a node is vault.crt and not <node>.crt, the reload is a local systemctl,
# and VAULT_ADDR comes from /etc/vault.d/pki.env. Paired with the pinned
# assertions above, which is what makes an absence assertion mean
# something.
issue_lacks "the operator's --reload-cmd is not sent to the node" "--reload-cmd"
issue_lacks "nor the operator's --cert-name"                      "--cert-name"
issue_lacks "nor the operator's --verify-addr"                    "--verify-addr"

reset_scenario
export FAKE_DEFAULT_ISSUER=pki
run_migrate --node-exec "$NODE_EXEC_STUB" \
            --remote-issue /opt/vault/issue.sh --phase trust
issue_has "--remote-issue changes the path used on the node" \
          ":: /opt/vault/issue.sh --ca-only"

# vault-0 is the active node here, so the first node swapped is vault-1 --
# which is the swap order's whole guarantee, and the stub does not change
# what a node serves, so the driver correctly stops after it.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
run_migrate --node-exec "$NODE_EXEC_STUB" --phase swap
issue_has "a swap sends the identity and the node's own SANs" \
          "exec vault-1 :: /usr/local/bin/vault-issue-node-cert.sh --common-name vault-1.vault.internal --alt-names localhost --ip-sans 127.0.0.1 --mount pki --role vault-node --force"
issue_lacks "and the active node is not the one it starts with" "exec vault-0"

reset_scenario
export FAKE_DEFAULT_ISSUER=pki
run_migrate --node-exec "$NODE_EXEC_STUB" --phase prune
issue_has "a prune replaces the bundle on the node" \
          ":: /usr/local/bin/vault-issue-node-cert.sh --ca-only --replace-ca --mount pki"

# Still the active node last. Asserted from the plan rather than from the
# calls: the stub never changes what a node serves, so a real swap run
# stops after the first node by design and never reaches the last one.
# The order is a decision, and the decision is what this pins.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_ACTIVE_ADDR="127.0.0.1:8210"
run_migrate --node-exec "$NODE_EXEC_STUB" --dry-run
assert_says "the active node is still swapped last in per-node mode" \
            "2. swap   vault-0 vault-2 vault-1  (active node last)"
assert_says "and the plan names the active node it found" "Active:  vault-1"

reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
run_migrate --node-exec "$NODE_EXEC_STUB" --phase prune
assert_rc   "and the prune still refuses while a node serves bootstrap" 1
assert_says "naming every laggard" "Refusing to prune"

reset_scenario
export FAKE_DEFAULT_ISSUER=pki
run_migrate --node-exec "   " --phase trust
assert_rc   "a --node-exec that expands to nothing is refused" 1
assert_says "rather than running the command locally by accident" "expanded to nothing"

# In per-node mode the local copy is neither used nor needed, so requiring
# it would refuse a correct invocation from a machine that has only the
# driver checked out.
reset_scenario
export FAKE_DEFAULT_ISSUER=pki
RC=0
OUT="$(FAKE_LOG="${WORK}/calls.log" ISSUE_LOG="${WORK}/issue-calls.log" \
    PATH="${FAKE_BIN}:${WORK}/bin:${PATH}" \
    "$MIGRATE" --nodes "$NODES" --health-retries 2 \
    --issue-script /nonexistent/issue-node-cert.sh \
    --node-exec "$NODE_EXEC_STUB" --phase trust 2>&1)" || RC=$?
assert_rc "a missing local issue script does not block per-node mode" 0

# ---------------------------------------------------------------------------
printf '\n=== Two things it used to get wrong by being quiet ===\n'
# ---------------------------------------------------------------------------
# Every gate runs from where this script runs. A node it cannot reach
# reads as "not active" and "not on PKI" -- the two answers that make a
# run unsafe rather than failed.
reset_scenario
export FAKE_DEFAULT_ISSUER=pki
export FAKE_NODE_HEALTH="127.0.0.1:8210=000"
run_migrate --node-exec "$NODE_EXEC_STUB" --phase trust
assert_rc        "a node this machine cannot reach stops the run" 1
assert_says      "naming it and its address" "vault-1 (127.0.0.1:8210)"
assert_says      "and saying why that matters here" "forwarded port per node"
issue_lacks      "before anything is changed anywhere" "exec vault-0"

# `[[ -n "$ACTIVE_NODE" ]] && SWAP_ORDER+=(...)` was the whole command of
# its statement, so under set -e a cluster with no leader exited 1 there
# with no output at all.
reset_scenario
export FAKE_DEFAULT_ISSUER=pki
export FAKE_ACTIVE_ADDR="127.0.0.1:9999"      # no node is active
run_migrate --node-exec "$NODE_EXEC_STUB" --phase swap
assert_rc   "a cluster with no active node stops the run" 1
assert_says "and says so, rather than exiting silently" "No node reports active"

# ---------------------------------------------------------------------------
printf '\n=== The wrapper the docs tell you to pass ===\n'
# ---------------------------------------------------------------------------
NODE_EXEC_SCRIPT="${REPO_ROOT}/scripts/pki-node-exec.sh"

INV="${WORK}/inv.ini"
printf '[vault_nodes]\nvault-0\nvault-1\n' > "$INV"

# The shims stand in for ansible: this suite's requirements are bash, jq,
# python3 and openssl, and CI's runner for it has no ansible at all. What
# is under test is the wrapper's own logic -- which nodes it accepts, and
# how it quotes -- not ansible.
export FAKE_INVENTORY_HOSTS="vault-0 vault-1"

wrapper() {
    RC=0
    OUT="$(PATH="${FAKE_BIN}:${WORK}/bin:${PATH}"         "$NODE_EXEC_SCRIPT" --inventory "$INV" "$@" 2>&1)" || RC=$?
}

wrapper --node vault-0 --dry-run -- /usr/local/bin/vault-issue-node-cert.sh --ca-only
assert_rc   "a known node is accepted" 0
assert_says "and the remote script sources the env file first" \
            "set -a; . /etc/vault.d/pki.env; set +a; exec"
assert_says "before running the command"  "vault-issue-node-cert.sh --ca-only"

wrapper --node vault-9 --dry-run -- /bin/true
assert_rc   "a node the inventory does not know is refused" 1
assert_says "and it names the cause that has actually caused it" \
            "empty inventory and exits 0"

wrapper --node vault-0 --dry-run -- /bin/echo "two words"
assert_says "an argument containing a space stays one argument" \
            "/bin/echo two\\ words"

wrapper --node vault-0 --dry-run
assert_rc   "no command is refused" 1
assert_says "and it says where the command goes" "everything after --"

wrapper --dry-run -- /bin/true
assert_rc   "no --node is refused" 1

wrapper --node vault-0 --env-file /etc/vault.d/other.env --dry-run -- /bin/true
assert_says "--env-file changes what is sourced" ". /etc/vault.d/other.env"


# ---------------------------------------------------------------------------
printf '\n=== The SANs come from the node ===\n'
# ---------------------------------------------------------------------------
# The driver used to ask for `<node>,localhost` and `127.0.0.1`. Both
# halves were wrong: the bare node name is refused by the role
# bootstrap-pki.sh creates, and the invented list leaves out whatever else
# the cluster runs on. The fourth AWS apply found both by probing the role
# before driving it.
#
# The two profiles disagree about which names matter, which is why
# inventing cannot work. Modelled here as the two shapes.

# Cloud-shaped: leader_tls_servername is <cluster>.vault.internal, so that
# name is load-bearing and the instance id is not.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_ACTIVE_ADDR="127.0.0.1:8220"
export FAKE_NODE_SANS="127.0.0.1:8200=DNS:i-0abc|DNS:vault-reference.vault.internal|DNS:localhost|IP:10.0.1.7|IP:127.0.0.1"
run_migrate --node-exec "$NODE_EXEC_STUB" --phase swap
issue_has "every served DNS SAN is carried onto the new certificate" \
          "--alt-names i-0abc,vault-reference.vault.internal,localhost"
issue_has "and every served IP SAN, including the node's own address" \
          "--ip-sans 10.0.1.7,127.0.0.1"

# Local-shaped: no leader_tls_servername at all, peers join by
# `leader_api_addr = https://vault-0:8200`, so DNS:vault-0 is the name
# they verify. A rule that dropped bare names would break this profile
# while fixing the other one.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_ACTIVE_ADDR="127.0.0.1:8220"
export FAKE_NODE_SANS="127.0.0.1:8200=DNS:vault-0|DNS:localhost|IP:127.0.0.1"
run_migrate --node-exec "$NODE_EXEC_STUB" --phase swap
issue_has "the container name a local peer verifies is carried too" \
          "--alt-names vault-0,localhost"

# Narrowing is a decision somebody makes, not something that happens.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_ACTIVE_ADDR="127.0.0.1:8220"
export FAKE_NODE_SANS="127.0.0.1:8200=DNS:i-0abc|DNS:vault-reference.vault.internal|DNS:localhost|IP:127.0.0.1"
run_migrate --node-exec "$NODE_EXEC_STUB" --phase swap --drop-san i-0abc
issue_has "--drop-san removes the name it names" \
          "--alt-names vault-reference.vault.internal,localhost"

reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_ACTIVE_ADDR="127.0.0.1:8220"
export FAKE_NODE_SANS="127.0.0.1:8200=DNS:i-0abc|DNS:i-0abcdef|DNS:localhost|IP:127.0.0.1"
run_migrate --node-exec "$NODE_EXEC_STUB" --phase swap --drop-san i-0abc
issue_has "and only that name — not one it is a prefix of" \
          "--alt-names i-0abcdef,localhost"

# ---------------------------------------------------------------------------
printf '\n=== It asks the role before it installs anything ===\n'
# ---------------------------------------------------------------------------
# A name the role will not sign is a thing to learn with the cluster
# untouched, rather than at the first swap with it half migrated.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_NODE_SANS="127.0.0.1:8200=DNS:i-0abc|DNS:localhost|IP:127.0.0.1"
export FAKE_ROLE_REFUSES="i-0abc"
run_migrate --node-exec "$NODE_EXEC_STUB" --phase swap
assert_rc        "a SAN the role will not sign stops the run" 1
assert_says      "and the refusal names the SAN" "i-0abc"
assert_says      "and says which node it belongs to" "REFUSED  vault-0"
assert_says      "offering the two ways out" "--extra-domains"
assert_says      "including the one that narrows the certificate" "--drop-san"
assert_says      "and saying nothing was touched" "Nothing has been changed."
issue_lacks      "with nothing installed anywhere" "exec vault-"

# The check is the role's answer, not a guess about it: a name that looks
# unusual but is allowed does not stop anything.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_NODE_SANS="127.0.0.1:8200=DNS:i-0abc|DNS:localhost|IP:127.0.0.1"
run_migrate --node-exec "$NODE_EXEC_STUB" --dry-run
assert_rc   "a role that signs them all lets the run proceed" 0
assert_says "saying so once" "the role will issue all of them"

# --dry-run reaches it too: the plan is the place an operator finds out.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_NODE_SANS="127.0.0.1:8210=DNS:nope|DNS:localhost|IP:127.0.0.1"
export FAKE_ROLE_REFUSES="nope"
run_migrate --node-exec "$NODE_EXEC_STUB" --dry-run
assert_rc   "a dry run refuses on the same grounds" 1
assert_says "naming the node whose SAN it is" "REFUSED  vault-1"


# ---------------------------------------------------------------------------
printf '\n=== The trust bundle the driver builds ===\n'
# ---------------------------------------------------------------------------
# It health-checks every node after every change, and during phase 2 half
# of them are on each CA -- so it needs both, for the same reason phase 1
# gives them to the nodes.
#
# The join is the part that broke. `vault read -field=certificate` emits no
# trailing newline, and neither does the bundle --replace-ca installs from
# it, so a plain append glues two PEM blocks into one unparseable line.
# curl then rejects the whole file and every node reads as unreachable at
# once -- which is what the integration suite re-run case caught, on the
# only input that has been through --replace-ca.
reset_scenario
export FAKE_DEFAULT_ISSUER=pki
NO_NL_CA="${WORK}/no-trailing-newline.crt"
printf '%s' "$(cat "${FIXTURES}/pkica.crt")" > "$NO_NL_CA"
if [[ "$(tail -c1 "$NO_NL_CA" | wc -l)" -eq 0 ]]; then
    ok "the fixture CA really has no trailing newline"
else
    bad "the fixture CA really has no trailing newline" "it ends with one"
fi

VAULT_CACERT="$NO_NL_CA" run_migrate --dry-run
assert_rc   "a CA file with no trailing newline still builds a bundle" 0
assert_says "and the bundle parses, with both certificates in it" "2 certificate(s)"

# And with a bundle that cannot parse at all, it says so rather than
# reporting every node unreachable.
reset_scenario
export FAKE_DEFAULT_ISSUER=pki
BAD_CA="${WORK}/not-a-certificate.crt"
printf 'this is not a certificate\n' > "$BAD_CA"
VAULT_CACERT="$BAD_CA" run_migrate --dry-run
assert_rc   "a trust bundle that does not parse stops the run" 1
assert_says "naming the file rather than blaming the cluster" "does not parse as PEM"

# ---------------------------------------------------------------------------
printf '\n=== The test issue does not leave certificates behind ===\n'
# ---------------------------------------------------------------------------
# Vault has no dry-run issue, so asking the role whether it will sign what
# a node serves mints a real certificate. The role bootstrap-pki.sh creates
# sets no no_store, so one that is not revoked stays in storage for its
# whole TTL -- three per run of a check that wanted nothing but the answer,
# accumulating over every retry of a migration that did not work first time.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
run_migrate --node-exec "$NODE_EXEC_STUB" --dry-run
assert_rc  "the pre-flight test-issue runs on a dry run" 0
log_count  "one test certificate is issued per node" 3 "pki/issue/vault-node"
log_count  "and each one is revoked again" 3 "write pki/revoke serial_number="
log_has    "by the serial the issue response carried" \
           "write pki/revoke serial_number=3f:9c:12:aa:7b:04:e1:55"

# A node whose SANs the role refuses was never issued anything, so there is
# no serial to revoke. Revoking one anyway would fail, and the failure
# would read as the cleanup being broken rather than as nothing to clean.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_NODE_SANS="127.0.0.1:8200=DNS:i-0abc|DNS:localhost|IP:127.0.0.1"
export FAKE_ROLE_REFUSES="i-0abc"
run_migrate --node-exec "$NODE_EXEC_STUB" --dry-run
assert_rc    "a refused SAN still stops the run" 1
log_count    "and only the certificates that were issued are revoked" 2 \
             "write pki/revoke serial_number="
# A refusal means nothing was issued, so nothing is in storage. Reporting
# otherwise sends the operator looking for a certificate that is not there.
assert_lacks "and it is not reported as leaving a certificate behind" \
             "carried no serial"

# Cleanup that fails is a warning, not an abort: the check it belongs to
# has already answered, and the answer is the thing the operator came for.
# Silence would be the wrong half to pick -- a certificate is in storage.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_REVOKE_RC=2
run_migrate --node-exec "$NODE_EXEC_STUB" --dry-run
assert_rc   "a revoke that fails does not stop the run" 0
assert_says "but it says which certificate was left behind" \
            "could not revoke test certificate 3f:9c:12:aa:7b:04:e1:55"

# And a response with no serial in it at all, which is the case where the
# driver cannot clean up even in principle. It has to say so: this is the
# only way the operator learns there is something in storage to find.
reset_scenario
export FAKE_DEFAULT_ISSUER=bootstrap
export FAKE_ISSUE_SERIAL=""
run_migrate --node-exec "$NODE_EXEC_STUB" --dry-run
assert_rc   "an issue response with no serial does not stop the run" 0
assert_says "but it says the certificate could not be revoked" \
            "carried no serial"
log_count   "and nothing is revoked by an empty serial" 0 \
            "write pki/revoke serial_number="

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    red "FAILED"
    exit 1
fi
green "All ${PASS} assertions passed."
