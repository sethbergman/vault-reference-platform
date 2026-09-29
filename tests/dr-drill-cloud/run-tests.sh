#!/usr/bin/env bash
#
# run-tests.sh — Tests for the cloud disaster-recovery drill
#
# Usage:
#   ./tests/dr-drill-cloud/run-tests.sh
#
# Runs in about fifteen seconds. No cluster, no cloud account, no
# credentials. Every case passes --read-timeout 3: two of them are about a
# cluster the drill cannot read, and at the default thirty seconds those
# two alone would be most of the run.
#
# WHY THIS SUITE EXISTS
#
# scripts/dr-drill-cloud.sh is the only thing in this repository that has
# ever restored a cloud cluster, and it is run by hand, once per cluster,
# on the day somebody has a cluster to spend. There is no second chance to
# notice it is broken: a drill that reports four passes against a cluster
# it never really restored is worse than no drill, because it converts an
# unknown into a wrong answer.
#
# It shipped without a suite and the AWS half was, at the time, unrunnable:
# it pointed at the load balancer, which keeps standbys in the pool on
# purpose, and it never set VAULT_CACERT. Neither was visible from
# reading it. Both are pinned below.
#
# The shims are stateful, because the thing under test is a sequence.
# `vault` here remembers the canary, what the snapshot contained, and
# whether a restore has happened, so a restore that succeeds and changes
# nothing is a case this suite can actually express -- which is the
# failure the drill exists to catch and the one an exit code cannot see.
#
# Requirements: bash, jq, python3

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FAKE_BIN="${SCRIPT_DIR}/fake-bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Short enough that the two cases about an unreadable cluster do not
# dominate the run, long enough that a loaded machine does not turn a
# passing case into an unread one.
READ_TIMEOUT=3

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

# ---------------------------------------------------------------------------
# A repository the drill can believe in
# ---------------------------------------------------------------------------
# The script derives REPO_ROOT from its own location and reads the CA from
# ansible/files/tls/ca.crt. Running it out of a copied tree rather than the
# real one keeps every case -- including "the CA is missing" -- away from a
# directory that holds private keys on a developer's machine.
FAKE_ROOT="${WORK}/repo"
DRILL="${FAKE_ROOT}/scripts/dr-drill-cloud.sh"
mkdir -p "${FAKE_ROOT}/scripts" "${FAKE_ROOT}/ansible/files/tls" \
         "${FAKE_ROOT}/terraform/aws" "${FAKE_ROOT}/terraform/azure"
cp "${REPO_ROOT}/scripts/dr-drill-cloud.sh" "$DRILL"
chmod +x "$DRILL"
CA="${FAKE_ROOT}/ansible/files/tls/ca.crt"
printf 'not-a-real-ca\n' > "$CA"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
RC=0
OUT=""
LOG=""

# run_drill <args...> — with the shims ahead of the real tools, and a fresh
# state directory so one case's canary cannot satisfy the next.
#
# FAKE_* must be exported by the caller: the shims are grandchildren of this
# shell, so a `VAR=x run_drill` prefix does not reach them.
run_drill() {
    local logfile="${WORK}/calls.log"
    : > "$logfile"
    rm -rf "${WORK}/state"

    RC=0
    OUT="$(FAKE_LOG="$logfile" FAKE_STATE="${WORK}/state" \
        PATH="${FAKE_BIN}:${PATH}" "$DRILL" \
        --read-timeout "$READ_TIMEOUT" "$@" 2>&1)" || RC=$?
    LOG="$(cat "$logfile")"
}

# Same, with something on stdin — for the confirmation prompt.
run_drill_saying() {
    local said="$1"; shift
    local logfile="${WORK}/calls.log"
    : > "$logfile"
    rm -rf "${WORK}/state"

    RC=0
    OUT="$(printf '%s\n' "$said" | FAKE_LOG="$logfile" FAKE_STATE="${WORK}/state" \
        PATH="${FAKE_BIN}:${PATH}" "$DRILL" \
        --read-timeout "$READ_TIMEOUT" "$@" 2>&1)" || RC=$?
    LOG="$(cat "$logfile")"
}

reset_scenario() {
    export VAULT_TOKEN=hvs.roottoken
    unset VAULT_ADDR VAULT_CACERT 2>/dev/null || true

    # Terraform outputs, per profile.
    export FAKE_TF_AUTOSCALING_GROUP_NAME=vault-ref-asg
    export FAKE_TF_AWS_REGION=us-west-2
    export FAKE_TF_VAULT_ADDR=https://vault-ref-nlb-1234.elb.us-west-2.amazonaws.com:8200
    export FAKE_TF_RESOURCE_GROUP_NAME=vault-ref-rg
    export FAKE_TF_VAULT_SCALE_SET_NAME=vault-ref-vmss
    export FAKE_TF_BASTION_NAME=vault-ref-bastion

    # Who the leader is, and how each cloud names it.
    export FAKE_LEADER_IP=10.0.1.7
    export FAKE_ASG_FIRST_INSTANCE=i-0aaaaaaaaaaaaaaa1
    export FAKE_LEADER_INSTANCE=i-0bbbbbbbbbbbbbbb2
    # Not 0, 1, 2: scale set instance ids never reuse a number downwards,
    # so anything that has ever replaced an instance looks like this.
    export FAKE_VMSS_INSTANCES="4 5 6"
    export FAKE_NIC_FINDS_NOTHING=false

    export FAKE_ASG_RC=0
    export FAKE_DESCRIBE_RC=0
    export FAKE_DESCRIBE_FINDS_NOTHING=false
    export FAKE_SSM_RC=0
    export FAKE_BASTION_RC=0

    export FAKE_STATUS_RC=0
    export FAKE_STATUS_JSON_RC=0
    export FAKE_STATUS_JSON_RC_AFTER_RESTORE=0
    export FAKE_SEALED=false
    export FAKE_SEAL_TYPE=awskms
    export FAKE_SNAPSHOT_RC=0
    export FAKE_SNAPSHOT_BYTES=24576
    export FAKE_RESTORE_RC=0
    export FAKE_RESTORE_IS_NOOP=false
    export FAKE_TOKEN_CREATE_RC=0
    export FAKE_TOKEN_SURVIVES=false
    export FAKE_KV_PUT_RC=0
    export FAKE_DELETE_RC=0
    export FAKE_PEERS=3
    export FAKE_VOTERS=3
    export FAKE_PEERS_RC=0
}

assert_rc() {
    if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1" "expected exit ${2}, got ${RC}: ${OUT}"; fi
}
assert_says() {
    if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1" "output did not contain: ${2}"; fi
}
assert_silent_about() {
    if [[ "$OUT" != *"$2"* ]]; then ok "$1"; else bad "$1" "output contained: ${2}"; fi
}
assert_log_has() {
    if [[ "$LOG" == *"$2"* ]]; then ok "$1"; else bad "$1" "no call matching: ${2}"; fi
}
assert_log_lacks() {
    if [[ "$LOG" != *"$2"* ]]; then ok "$1"; else bad "$1" "a call matched: ${2}"; fi
}
# assert_before <name> <first> <second> — order within the call log.
assert_before() {
    local a b
    a="$(grep -n -- "$2" <<< "$LOG" | head -1 | cut -d: -f1)"
    b="$(grep -n -- "$3" <<< "$LOG" | head -1 | cut -d: -f1)"
    if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then
        ok "$1"
    else
        bad "$1" "'${2}' at line ${a:-none}, '${3}' at line ${b:-none}"
    fi
}

# ===========================================================================
printf '\n=== Arguments, and the things it refuses to start without ===\n'
# ===========================================================================
reset_scenario
run_drill --yes
assert_rc   "no --cloud is refused" 1
assert_says "and it says which values are allowed" "aws or azure"

reset_scenario
run_drill --cloud gcp --yes
assert_rc   "an unsupported cloud is refused" 1
assert_says "and it echoes back what it was given" "got: gcp"

reset_scenario
unset VAULT_TOKEN
run_drill --cloud aws --yes
assert_rc   "no VAULT_TOKEN is refused" 1
assert_says "and it says what the token has to be able to do" "snapshot and restore"

reset_scenario
run_drill --cloud aws --yes --read-timeout 0
assert_rc   "a zero read budget is refused" 1
assert_says "and it says what the value has to be" "positive number of seconds"

reset_scenario
run_drill --cloud aws --yes --read-timeout soon
assert_rc   "a read budget that is not a number is refused" 1
assert_says "and it echoes back what it was given" "got: soon"

reset_scenario
rm -f "$CA"
run_drill --cloud aws --yes
assert_rc        "a missing CA is refused" 1
assert_says      "and it names the script that mints one" "generate-cloud-certs.sh"
assert_log_lacks "and nothing reaches the cloud first" "aws "
printf 'not-a-real-ca\n' > "$CA"

# ===========================================================================
printf '\n=== AWS reaches the leader, not the load balancer ===\n'
# ===========================================================================
# terraform/aws/lb.tf probes /v1/sys/health?standbyok=true so that standbys
# stay in the target group -- checklist item 4, and deliberate. The listener
# is TCP, so the load balancer spreads connections across all three nodes,
# and Vault redirects a snapshot request to the leader's private api_addr.
# Using it here would fail two times in three.
reset_scenario
run_drill --cloud aws --yes
assert_rc        "the happy path passes" 0
assert_log_has   "it asks the autoscaling group for a node to start from" \
                 "ssm start-session --target i-0aaaaaaaaaaaaaaa1"
assert_log_has   "and forwards that first port to 18200" \
                 "localPortNumber=18200"
assert_log_has   "it then re-targets the port forward at the leader" \
                 "ssm start-session --target i-0bbbbbbbbbbbbbbb2"
assert_log_has   "on a second local port" \
                 "localPortNumber=18201"
assert_says      "and says which instance is the leader" "Leader is 10.0.1.7"

# The positive form of "it does not use the load balancer": every single
# call the drill makes to Vault is pinned to the forwarded port. Asserting
# the absence of the load balancer's name would pass a drill that used its
# IP address, or a second load balancer, or no address at all.
reset_scenario
run_drill --cloud aws --yes
OFF_PORT="$(grep '^vault ' <<< "$LOG" | grep -cv 'VAULT_ADDR=https://127\.0\.0\.1:1820[01]')"
if [[ "$OFF_PORT" == 0 ]]; then
    ok "every Vault call goes through the forwarded port"
else
    bad "every Vault call goes through the forwarded port" \
        "${OFF_PORT} call(s) went somewhere else"
fi

# And the other half of reaching a node: verifying it. TLS terminates at
# Vault under a private CA, so without this every call fails verification
# and the only way past it is the flag this repository forbids.
NO_CA="$(grep '^vault ' <<< "$LOG" | grep -cv "VAULT_CACERT=${CA}")"
if [[ "$NO_CA" == 0 ]]; then
    ok "every Vault call carries the CA"
else
    bad "every Vault call carries the CA" "${NO_CA} call(s) did not"
fi

# The region comes from the profile that was applied, not from whichever
# one happens to be configured on the operator's machine.
reset_scenario
export FAKE_TF_AWS_REGION=eu-central-1
export AWS_REGION=us-east-1
run_drill --cloud aws --yes
assert_log_has "the region comes from the terraform output" "AWS_REGION=eu-central-1"
unset AWS_REGION

reset_scenario
unset FAKE_TF_AUTOSCALING_GROUP_NAME
run_drill --cloud aws --yes
assert_rc   "a profile with no autoscaling group output is refused" 1
assert_says "and it names the output" "autoscaling_group_name"

reset_scenario
export FAKE_ASG_FIRST_INSTANCE=None
run_drill --cloud aws --yes
assert_rc   "an autoscaling group with nothing InService is refused" 1
assert_says "and it suggests the obvious cause" "is the cluster up?"

reset_scenario
export FAKE_LEADER_IP=10.0.9.99
export FAKE_DESCRIBE_FINDS_NOTHING=true
run_drill --cloud aws --yes
assert_rc   "a leader that maps to no instance is refused" 1
assert_says "and it says which address it could not place" "10.0.9.99"

# ===========================================================================
printf '\n=== Azure reaches the leader through the Bastion ===\n'
# ===========================================================================
reset_scenario
export FAKE_LEADER_IP=10.1.0.7
export FAKE_LEADER_INSTANCE=5
export FAKE_SEAL_TYPE=azurekeyvault
run_drill --cloud azure --yes
assert_rc      "the happy path passes on Azure too" 0
assert_log_has "it tunnels through the Bastion" "network bastion tunnel"
assert_log_has "and resolves the leader to a scale set instance" \
               "virtualMachines/5"
assert_says    "and reports the seal it found" "seal: azurekeyvault"

# The scale set here has instances 4, 5 and 6, because a real one that has
# replaced anything does. Asking instance 0 who the leader is would fail
# with "no instance 0 in vault-ref-vmss" -- which is what the drill did
# until 2026-09-29, and which worked exactly once, against a cluster built
# from scratch the day before.
assert_log_has "it asks the scale set which instances exist" \
               "[0].instanceId"
assert_log_has "and starts from one of them" "virtualMachines/4"

reset_scenario
export FAKE_VMSS_INSTANCES=""
run_drill --cloud azure --yes
assert_rc   "an empty scale set is refused" 1
assert_says "and it says so about the scale set" "no instances in vault-ref-vmss"

reset_scenario
export FAKE_LEADER_IP=10.1.0.7
export FAKE_LEADER_INSTANCE=9        # answers nic list, not in the scale set
run_drill --cloud azure --yes
assert_rc   "a leader the scale set does not list is refused" 1
assert_says "and it names the instance and the scale set" \
            "no instance 9 in vault-ref-vmss"

reset_scenario
unset FAKE_TF_BASTION_NAME
run_drill --cloud azure --yes
assert_rc   "a profile applied without a Bastion is refused" 1
assert_says "and it says which setting explains that" "bastion_enabled"

# ===========================================================================
printf '\n=== The sequence, which is the whole point ===\n'
# ===========================================================================
# Every one of these is only meaningful in order. A token minted before the
# snapshot proves nothing; a canary deleted before the snapshot is taken is
# not in it.
reset_scenario
run_drill --cloud aws --yes
assert_before "the canary is written before the snapshot is taken" \
              "kv put" "snapshot save"
assert_before "the token is minted after the snapshot is taken" \
              "snapshot save" "token create"
assert_before "the canary is destroyed after the token is minted" \
              "token create" "kv metadata delete"
assert_before "and the restore comes last" \
              "kv metadata delete" "snapshot restore"

reset_scenario
run_drill --cloud aws --yes
assert_says "it reports four passes" "passed: 4   failed: 0   unread: 0"
assert_says "the canary check passes" "PASS  the canary written before the snapshot reads back"
assert_says "the token check passes" "PASS  a token minted after the snapshot no longer works"
assert_says "the seal check passes, naming the seal" \
            "PASS  the cluster is unsealed after the restore (seal: awskms)"
assert_says "the voter check passes, naming the count" "PASS  all 3 peers are still voters"
assert_says "and it says so once at the end" "Restored, and checked four ways."

# ===========================================================================
printf '\n=== What each check catches ===\n'
# ===========================================================================
# A restore that succeeds and changes nothing. The exit code is 0 and the
# cluster is healthy and unsealed, so nothing but the canary can see it.
reset_scenario
export FAKE_RESTORE_IS_NOOP=true
run_drill --cloud aws --yes
assert_rc   "a restore that silently did nothing fails the drill" 1
assert_says "the canary check is what catches it" \
            "FAIL  the canary written before the snapshot reads back"
assert_says "and it says not to trust the backup" \
            "Do not rely on this backup."

# A merge rather than a replacement: the canary is back and the cluster is
# fine, and the token store was never replaced.
reset_scenario
export FAKE_TOKEN_SURVIVES=true
run_drill --cloud aws --yes
assert_rc   "a restore that merged rather than replaced fails the drill" 1
assert_says "the post-snapshot token is what catches it" \
            "FAIL  a token minted after the snapshot no longer works"
assert_says "and it says what that means" "did not replace the token store"
assert_says "while the canary check still passes" \
            "PASS  the canary written before the snapshot reads back"

# jq's // is the alternative operator and it treats false as absent, so
# `.sealed // empty` reads as nothing on a healthy cluster: the check could
# only ever fail when everything was fine. Both values are pinned here, so
# a `//` creeping back in fails the false case.
reset_scenario
export FAKE_SEALED=false
run_drill --cloud aws --yes
assert_says "sealed=false is read, not mistaken for absent" \
            "PASS  the cluster is unsealed after the restore"

reset_scenario
export FAKE_SEALED=true
run_drill --cloud aws --yes
assert_rc   "a cluster still sealed after the restore fails the drill" 1
assert_says "and it points at the seal key" \
            "the snapshot is encrypted under the auto-unseal key"

# Not a pass and not a failure. Saying "do not rely on this backup" because
# a read timed out is worse than saying nothing.
reset_scenario
export FAKE_STATUS_JSON_RC_AFTER_RESTORE=1
run_drill --cloud aws --yes
assert_rc            "a seal state that cannot be read is not a failure" 0
assert_says          "it is reported as unread" "could not read the seal state"
assert_says          "and counted separately" "unread: 1"
assert_silent_about  "and it does not condemn the backup over it" \
                     "Do not rely on this backup."

reset_scenario
export FAKE_STATUS_JSON_RC=1
run_drill --cloud aws --yes
assert_rc        "a cluster it cannot read at all is refused up front" 1
assert_says      "and it says what it could not read" "leader_address"
assert_log_lacks "rather than restoring into the dark" "snapshot restore"

reset_scenario
export FAKE_VOTERS=2
run_drill --cloud aws --yes
assert_rc   "a restore that cost a voter fails the drill" 1
assert_says "and it says what was lost" "2 voter(s) of 3 peer(s)"

reset_scenario
export FAKE_PEERS_RC=1
run_drill --cloud aws --yes
assert_rc   "a peer list that cannot be read is not a failure" 0
assert_says "it is reported as unread" "could not read the peer list"

# ===========================================================================
printf '\n=== Consent, and the things it will not do without it ===\n'
# ===========================================================================
reset_scenario
run_drill_saying "yes" --cloud aws
assert_rc        "anything but the cloud name aborts" 1
assert_says      "and it says nothing was restored" "nothing was restored"
assert_log_lacks "and nothing was" "snapshot restore"

reset_scenario
run_drill_saying "aws" --cloud aws
assert_rc      "typing the cloud name proceeds" 0
assert_log_has "and it restores" "snapshot restore"

# ===========================================================================
printf '\n=== --from-file, for when the cluster cannot take one ===\n'
# ===========================================================================
reset_scenario
printf 'pretend-snapshot' > "${WORK}/given.snap"
run_drill --cloud aws --yes --from-file "${WORK}/given.snap"
assert_log_lacks "a supplied snapshot is not replaced by a fresh one" \
                 "snapshot save"
assert_log_has   "and it is what gets restored" "snapshot restore"
assert_says      "and it says which file" "given.snap"

reset_scenario
run_drill --cloud aws --yes --from-file "${WORK}/nothing-here.snap"
assert_rc   "a snapshot file that is not there is refused" 1
assert_says "and it names the path" "nothing-here.snap"

# ===========================================================================
printf '\n=== Failures on the way in ===\n'
# ===========================================================================
reset_scenario
export FAKE_SNAPSHOT_RC=2
run_drill --cloud aws --yes
assert_rc   "a snapshot that will not save stops the drill" 1
assert_says "and it names the likeliest cause" "is this the leader?"

# An empty file is the shape a truncated or refused snapshot arrives in,
# and restoring one is how a drill reports success over nothing at all.
reset_scenario
export FAKE_SNAPSHOT_BYTES=0
run_drill --cloud aws --yes
assert_rc        "a snapshot that comes back empty stops the drill" 1
assert_says      "and it says so plainly" "came back empty"
assert_log_lacks "before anything is restored" "snapshot restore"

reset_scenario
export FAKE_TOKEN_CREATE_RC=2
run_drill --cloud aws --yes
assert_rc        "a token it cannot mint stops the drill" 1
assert_log_lacks "rather than restoring without that check" "snapshot restore"

reset_scenario
export FAKE_DELETE_RC=2
run_drill --cloud aws --yes
assert_rc        "a canary it cannot destroy stops the drill" 1
assert_log_lacks "rather than restoring over an intact canary" "snapshot restore"

# ===========================================================================
printf '\n=== Results ===\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    red "${FAIL} assertion(s) failed."
    exit 1
fi
green "All ${PASS} assertions passed."
