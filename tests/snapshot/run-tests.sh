#!/usr/bin/env bash
#
# run-tests.sh — Tests for scheduled Raft snapshots
#
# Usage:
#   ./tests/snapshot/run-tests.sh
#
# Runs in about two seconds. No cluster, no cloud account, no credentials.
#
# scripts/snapshot.sh runs unattended on an hourly timer against a real
# cluster, which is the worst possible place for a quiet failure: every
# mode that matters here ends with "and nobody notices until the restore".
# The cases below are the ones that produce a green timer and no usable
# backup.
#
# Requirements: bash, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SNAPSHOT="${REPO_ROOT}/scripts/snapshot.sh"
FAKE_BIN="${SCRIPT_DIR}/fake-bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
# run_snapshot <args...>
# Runs the script with the shims ahead of the real tools on PATH, capturing
# its exit code, its output, and the log of every command the shims saw.
#
# Scenario variables (FAKE_*) must be exported by the caller: the shims are
# grandchildren of this shell, and a `VAR=x run_snapshot` prefix does not
# reach them.
RC=0
OUT=""
LOG=""

run_snapshot() {
    local logfile="${WORK}/calls.$$.log"
    : > "$logfile"

    RC=0
    OUT="$(FAKE_LOG="$logfile" PATH="${FAKE_BIN}:${PATH}" \
        "$SNAPSHOT" "$@" 2>&1)" || RC=$?
    LOG="$(cat "$logfile")"
}

# Reset scenario state between cases, so a variable set by one test cannot
# silently satisfy the next.
reset_scenario() {
    export FAKE_IS_SELF=true
    export FAKE_LEADER_IS_SELF=true
    export FAKE_LEADER_RC=0
    export FAKE_SEALED=false
    export FAKE_SNAPSHOT_RC=0
    export FAKE_SNAPSHOT_SIZE=1024
    export FAKE_INSPECT_RC=0
    export FAKE_APPROLE_RC=0
    export FAKE_APPROLE_TOKEN=s.faketoken
    export FAKE_AWS_RC=0
    export FAKE_IMDS_RC=0
    export FAKE_IMDS_TOKEN=tok
    export FAKE_BLOB_CURL_RC=0
    export FAKE_BLOB_HTTP_CODE=201
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_TOKEN=s.testtoken
    unset VAULT_ROLE_ID VAULT_SECRET_ID 2>/dev/null || true
}

assert_rc() {
    if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1" "expected exit ${2}, got ${RC}: ${OUT}"; fi
}

assert_log_has() {
    if [[ "$LOG" == *"$2"* ]]; then ok "$1"; else bad "$1" "no call matching: ${2}"; fi
}

# An exclusion assertion is only as strong as the spelling its author
# thought to forbid. Where one of these names a specific command, prefer
# the shortest prefix that covers every way of doing the same thing --
# `aws s3` rather than `aws s3 cp` -- so a rewrite that reaches for a
# different subcommand still trips it.
assert_log_lacks() {
    if [[ "$LOG" != *"$2"* ]]; then ok "$1"; else bad "$1" "unexpected call: ${2}"; fi
}

assert_says() {
    if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1" "output did not mention: ${2}"; fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || { red "ERROR: jq not found on PATH"; exit 1; }
[[ -x "$SNAPSHOT" ]] || { red "ERROR: ${SNAPSHOT} is not executable"; exit 1; }

# The shims are the whole test. If PATH resolution failed and the real
# tools were used instead, every assertion below would be meaningless.
if PATH="${FAKE_BIN}:${PATH}" command -v vault | grep -q "fake-bin"; then
    ok "the vault shim shadows any real vault on PATH"
else
    red "ERROR: the fake-bin shims are not being resolved first"
    exit 1
fi

# ---------------------------------------------------------------------------
printf '\n=== Argument handling ===\n'
# ---------------------------------------------------------------------------
reset_scenario

run_snapshot;                                  assert_rc "rejects a missing --cloud" 1
run_snapshot --cloud gcp;                      assert_says "rejects an unknown cloud" "must be aws, azure, or none"
run_snapshot --cloud aws;                      assert_says "aws requires --bucket" "--bucket is required"
run_snapshot --cloud azure --account a;        assert_says "azure requires --container" "--container is required"
run_snapshot --cloud none;                     assert_says "none requires --output-dir" "--output-dir is required"
run_snapshot --cloud aws --bucket b --wat;     assert_says "rejects unknown arguments" "Unknown argument"

# ---------------------------------------------------------------------------
printf '\n=== Only the active node snapshots ===\n'
# ---------------------------------------------------------------------------
# Three nodes on an hourly timer means three uploads of the same Raft
# state per hour if this check is wrong — triple the storage bill for no
# additional recovery capability.
reset_scenario
export FAKE_IS_SELF=false
run_snapshot --cloud aws --bucket vault-snaps
assert_rc        "a standby exits 0, not an error" 0
assert_log_lacks "a standby takes no snapshot"     "snapshot save"
assert_log_lacks "a standby uploads nothing"       "aws s3"
assert_says      "a standby says why"              "standby"

# Exiting non-zero here would mean systemd reporting a failed unit on two
# nodes out of three every hour, which trains everyone to ignore it.
reset_scenario
export FAKE_SEALED=true
run_snapshot --cloud aws --bucket vault-snaps
assert_rc        "a sealed node exits 0"        0
assert_log_lacks "a sealed node takes nothing"  "snapshot save"

reset_scenario
run_snapshot --cloud aws --bucket vault-snaps
assert_rc      "the active node proceeds" 0
assert_log_has "the active node snapshots" "snapshot save"

# ---------------------------------------------------------------------------
printf '\n=== Leadership comes from is_self, not ha_mode ===\n'
# ---------------------------------------------------------------------------
# `vault status -format=json` has no ha_mode field — the CLI renders that
# only in its text output. Reading it from the JSON made every node
# conclude it was not the leader, so no snapshot was ever taken anywhere:
# three green timers and zero backups.
#
# The shim used to emit ha_mode too, so the shim agreed with the bug and
# the suite stayed green. It took a real cluster to find, which is a fair
# argument for having one.
reset_scenario
export FAKE_IS_SELF=absent
export FAKE_LEADER_IS_SELF=true
run_snapshot --cloud aws --bucket vault-snaps
assert_log_has "falls back to sys/leader when status omits is_self" "sys/leader"
assert_log_has "and still takes the snapshot"                       "snapshot save"

reset_scenario
export FAKE_IS_SELF=absent
export FAKE_LEADER_IS_SELF=false
run_snapshot --cloud aws --bucket vault-snaps
assert_log_lacks "a standby identified via sys/leader takes nothing" "snapshot save"

# If leadership cannot be determined at all, take one anyway. A redundant
# snapshot costs storage; a skipped one costs the backup. This check
# exists to avoid waste, not to gate correctness, so it fails towards
# taking one.
reset_scenario
export FAKE_IS_SELF=absent
export FAKE_LEADER_RC=2
run_snapshot --cloud aws --bucket vault-snaps
assert_rc      "indeterminate leadership still snapshots" 0
assert_log_has "it takes one rather than skipping"        "snapshot save"
assert_says    "and warns that it could not tell"         "could not determine leadership"

# ---------------------------------------------------------------------------
printf '\n=== A bad snapshot is never uploaded ===\n'
# ---------------------------------------------------------------------------
# This is the failure that matters most. An empty or corrupt snapshot that
# uploads cleanly looks exactly like a backup until the day it is needed.
reset_scenario
export FAKE_SNAPSHOT_SIZE=0
run_snapshot --cloud aws --bucket vault-snaps
assert_rc        "a zero-byte snapshot aborts"      1
assert_log_lacks "a zero-byte snapshot is not sent" "aws s3"
assert_says      "and says so"                      "zero bytes"

reset_scenario
export FAKE_SNAPSHOT_SIZE=none
run_snapshot --cloud aws --bucket vault-snaps
assert_rc        "a missing snapshot file aborts"      1
assert_log_lacks "a missing snapshot is not sent"      "aws s3"

reset_scenario
export FAKE_INSPECT_RC=1
run_snapshot --cloud aws --bucket vault-snaps
assert_rc        "a snapshot failing inspect aborts"   1
assert_log_lacks "an unverified snapshot is not sent"  "aws s3"
assert_says      "and says it failed verification"     "verification"

reset_scenario
export FAKE_SNAPSHOT_RC=1
run_snapshot --cloud aws --bucket vault-snaps
assert_rc        "a failed snapshot command aborts" 1
assert_log_lacks "nothing is uploaded"              "aws s3"

# Verification must actually run, or the assertions above pass for the
# wrong reason.
reset_scenario
run_snapshot --cloud aws --bucket vault-snaps
assert_log_has "every snapshot is inspected before upload" "snapshot inspect"

# ---------------------------------------------------------------------------
printf '\n=== It never deletes ===\n'
# ---------------------------------------------------------------------------
# Retention is a server-side lifecycle rule, and the AWS instance role has
# no s3:DeleteObject on purpose: a node that can prune backups is a node
# that can destroy them. If this script ever grows a delete, that design
# is silently undone.
reset_scenario
run_snapshot --cloud aws --bucket vault-snaps
assert_log_lacks "no s3 rm"     "s3 rm"
assert_log_lacks "no s3api delete" "delete-object"

reset_scenario
run_snapshot --cloud azure --account acct --container snaps
assert_log_lacks "no blob DELETE" "DELETE"

# ---------------------------------------------------------------------------
printf '\n=== The local copy is always cleaned up ===\n'
# ---------------------------------------------------------------------------
# The previous version left every snapshot in /tmp. On an hourly timer
# that fills the disk and takes the node down — a backup job that causes
# the outage it exists to protect against.
reset_scenario
before="$(find /tmp -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l)"
run_snapshot --cloud aws --bucket vault-snaps
after="$(find /tmp -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l)"
if [[ "$after" -le "$before" ]]; then
    ok "no working directory is left behind on success"
else
    bad "no working directory is left behind on success" "temp dirs grew from ${before} to ${after}"
fi

# The same has to hold when the upload fails, which is the case that
# actually recurs in production.
reset_scenario
export FAKE_AWS_RC=1
before="$(find /tmp -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l)"
run_snapshot --cloud aws --bucket vault-snaps
after="$(find /tmp -maxdepth 1 -name 'tmp.*' 2>/dev/null | wc -l)"
assert_rc "a failed upload is an error" 1
if [[ "$after" -le "$before" ]]; then
    ok "no working directory is left behind on failure"
else
    bad "no working directory is left behind on failure" "temp dirs grew from ${before} to ${after}"
fi

# --keep-local is the deliberate exception, and it must actually differ.
reset_scenario
run_snapshot --cloud none --output-dir "${WORK}/local" --keep-local
assert_says "--keep-local says it kept the directory" "Leaving"

# ---------------------------------------------------------------------------
printf '\n=== Authentication ===\n'
# ---------------------------------------------------------------------------
reset_scenario
unset VAULT_TOKEN
run_snapshot --cloud aws --bucket vault-snaps
assert_rc   "no credentials is an error"  1
assert_says "and names what is missing"   "VAULT_ROLE_ID"

reset_scenario
unset VAULT_TOKEN
export VAULT_ROLE_ID=role VAULT_SECRET_ID=secret
run_snapshot --cloud aws --bucket vault-snaps
assert_rc      "AppRole login is used when no token is set" 0
assert_log_has "it logs in via approle"  "auth/approle/login"
# A token minted every hour and never revoked is a slowly growing pile of
# live credentials on a host that already holds the cluster's data.
assert_log_has "the minted token is revoked afterwards" "revoke"

reset_scenario
unset VAULT_TOKEN
export VAULT_ROLE_ID=role VAULT_SECRET_ID=secret FAKE_APPROLE_RC=2
run_snapshot --cloud aws --bucket vault-snaps
assert_rc        "a failed AppRole login aborts" 1
assert_log_lacks "and takes no snapshot"         "snapshot save"

# A supplied token must not be revoked — it belongs to whoever set it, and
# revoking it would break the next run and anything else using it.
reset_scenario
run_snapshot --cloud aws --bucket vault-snaps
assert_log_lacks "a supplied VAULT_TOKEN is left alone" "revoke"

# ---------------------------------------------------------------------------
printf '\n=== AWS upload ===\n'
# ---------------------------------------------------------------------------
reset_scenario
run_snapshot --cloud aws --bucket vault-snaps --prefix nightly
assert_rc      "uploads to S3"                0
assert_log_has "uses the configured bucket"   "s3://vault-snaps/nightly/"
assert_log_has "the object name is a snapshot" ".snap"

reset_scenario
export FAKE_AWS_RC=1
run_snapshot --cloud aws --bucket vault-snaps
assert_rc   "a failed S3 upload is an error" 1
assert_says "and says where it failed"       "Upload to s3://vault-snaps"

# ---------------------------------------------------------------------------
printf '\n=== Azure upload ===\n'
# ---------------------------------------------------------------------------
reset_scenario
run_snapshot --cloud azure --account acct --container snaps
assert_rc      "uploads to blob storage"     0
assert_log_has "requests a managed identity token" "169.254.169.254"
assert_log_has "PUTs to the right blob URL"  "https://acct.blob.core.windows.net/snaps/"
assert_log_has "declares the blob type"      "x-ms-blob-type: BlockBlob"

# curl exits 0 on a 403 as happily as on a 201. Without the status-code
# check the script would report a successful backup that never landed —
# the single most dangerous outcome in this file.
reset_scenario
export FAKE_BLOB_HTTP_CODE=403
run_snapshot --cloud azure --account acct --container snaps
assert_rc   "a 403 from blob storage is an error" 1
assert_says "and reports the status code"         "HTTP 403"

reset_scenario
export FAKE_BLOB_HTTP_CODE=404
run_snapshot --cloud azure --account acct --container snaps
assert_rc "a 404 from blob storage is an error" 1

reset_scenario
export FAKE_IMDS_TOKEN=none
run_snapshot --cloud azure --account acct --container snaps
assert_rc        "no access token is an error" 1
assert_log_lacks "and nothing is PUT"          "blob.core.windows.net/snaps/"

reset_scenario
export FAKE_IMDS_RC=7
run_snapshot --cloud azure --account acct --container snaps
assert_rc   "an unreachable IMDS is an error" 1
assert_says "and says so"                     "metadata service"

# ---------------------------------------------------------------------------
printf '\n=== Local backend ===\n'
# ---------------------------------------------------------------------------
reset_scenario
rm -rf "${WORK}/local"
run_snapshot --cloud none --output-dir "${WORK}/local"
assert_rc "writes to a local directory" 0
if compgen -G "${WORK}/local/*.snap" >/dev/null; then
    ok "a .snap file lands in the output directory"
else
    bad "a .snap file lands in the output directory" "nothing matched ${WORK}/local/*.snap"
fi
assert_says "warns that local has no retention policy" "prune it yourself"

# ---------------------------------------------------------------------------
printf '\n=== The systemd units say what the docs say ===\n'
# ---------------------------------------------------------------------------
# docs/disaster-recovery.md claimed hourly snapshots for a long time
# before anything scheduled them. This keeps the claim and the timer
# tied together.
TIMER="${REPO_ROOT}/ansible/roles/vault_snapshots/templates/vault-snapshot.timer.j2"
SERVICE="${REPO_ROOT}/ansible/roles/vault_snapshots/templates/vault-snapshot.service.j2"
DEFAULTS="${REPO_ROOT}/ansible/roles/vault_snapshots/defaults/main.yml"

for f in "$TIMER" "$SERVICE" "$DEFAULTS"; do
    [[ -f "$f" ]] || { bad "$(basename "$f") exists"; continue; }
    ok "$(basename "$f") exists"
done

TIMER_TEXT="$(cat "$TIMER")"
if [[ "$TIMER_TEXT" == *"OnCalendar="* ]]; then ok "the timer sets OnCalendar"; else bad "the timer sets OnCalendar"; fi
if [[ "$TIMER_TEXT" == *"Persistent=true"* ]]; then
    ok "a missed window is caught up on boot"
else
    bad "a missed window is caught up on boot"
fi

SCHEDULE="$(grep -E '^vault_snapshots_schedule:' "$DEFAULTS" | awk '{print $2}')"
if [[ "$SCHEDULE" == "hourly" ]]; then
    ok "the default schedule is hourly, as disaster-recovery.md states"
else
    bad "the default schedule is hourly, as disaster-recovery.md states" \
        "defaults say '${SCHEDULE}' — update docs/disaster-recovery.md to match, or change it back"
fi

SERVICE_TEXT="$(cat "$SERVICE")"
# Credentials on an ExecStart line are readable by every user on the box
# through /proc/<pid>/cmdline.
if [[ "$SERVICE_TEXT" == *"EnvironmentFile="* ]]; then
    ok "credentials come from an EnvironmentFile, not the command line"
else
    bad "credentials come from an EnvironmentFile, not the command line"
fi
if [[ "$SERVICE_TEXT" != *"SECRET_ID="* && "$SERVICE_TEXT" != *"VAULT_TOKEN="* ]]; then
    ok "no credential is baked into the unit file"
else
    bad "no credential is baked into the unit file"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    red "FAILED"
    exit 1
fi
green "All ${PASS} assertions passed."
