#!/usr/bin/env bash
#
# run-tests.sh — Tests for the Vault Agent bootstrap
#
# Usage:
#   ./tests/agent/run-tests.sh
#
# Runs in about a second. No Vault, no agent, no cluster.
#
# Covers how the credentials are placed: that role_id and secret_id are
# not treated as the same kind of thing, that the secret_id is never
# written world-readable, and that --wrap-ttl actually changes what lands
# on disk rather than only what is logged.
#
# It also checks the agent config, because two of its settings correct
# Vault Agent defaults that are wrong for a file holding a live password.
#
# Whether Agent authenticates, renders, and keeps working when Vault goes
# away is tests/integration.
#
# Requirements: bash, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REAL_BOOTSTRAP="${REPO_ROOT}/scripts/bootstrap-agent.sh"
AGENT_CONFIG="${REPO_ROOT}/docker/vault-agent/agent.hcl"
AGENT_POLICY="${REPO_ROOT}/examples/policies/vault-agent.hcl"
FAKE_BIN="${SCRIPT_DIR}/fake-bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
SKIP=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()   { PASS=$((PASS + 1)); green "  PASS  $1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }
bad()  { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

RC=0
OUT=""
LOG=""
CREDS=""

# The script resolves bootstrap-approle.sh and rotate-secret-id.sh as its
# own siblings, so a copy of it is placed next to the stubs. Overriding
# that with flags would mean adding options to production code that exist
# only for tests.
BIN="${WORK}/bin"
mkdir -p "$BIN"
cp "$REAL_BOOTSTRAP" "${BIN}/bootstrap-agent.sh"
cp "${FAKE_BIN}/bootstrap-approle.sh" "${FAKE_BIN}/rotate-secret-id.sh" "$BIN/"
chmod +x "${BIN}"/*.sh
BOOTSTRAP="${BIN}/bootstrap-agent.sh"

reset_scenario() {
    export FAKE_APPROLE_RC=0
    export FAKE_ROTATE_RC=0
    export FAKE_ROTATE_NOISY=false
    export FAKE_ROLE_ID_RC=0
    export FAKE_GENERIC_RC=0
    export FAKE_ROLE_ID="11111111-2222-3333-4444-555555555555"
    export FAKE_SECRET_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    export FAKE_WRAP_TOKEN="hvs.WRAPPEDTOKEN"
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_TOKEN=s.testtoken
    CREDS="${WORK}/creds.$RANDOM"
}

run_bootstrap() {
    local logfile="${WORK}/calls.log"
    : > "$logfile"
    RC=0
    OUT="$(FAKE_LOG="$logfile" PATH="${FAKE_BIN}:${PATH}" \
        "$BOOTSTRAP" --creds-dir "$CREDS" --policy-file "$AGENT_POLICY" "$@" 2>&1)" || RC=$?
    LOG="$(cat "$logfile")"
}

assert_rc()      { if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1" "expected ${2}, got ${RC}: ${OUT}"; fi; }
assert_says()    { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1" "output lacked: ${2}"; fi; }
assert_log_has() { if [[ "$LOG" == *"$2"* ]]; then ok "$1"; else bad "$1" "no call matching: ${2}"; fi; }
cfg_has()        { if [[ "$CONFIG_TEXT" == *"$2"* ]]; then ok "$1"; else bad "$1" "config lacked: ${2}"; fi; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || { red "ERROR: jq not found on PATH"; exit 1; }
[[ -x "$BOOTSTRAP" ]]   || { red "ERROR: ${BOOTSTRAP} is not executable"; exit 1; }
[[ -f "$AGENT_CONFIG" ]] || { red "ERROR: no agent config at ${AGENT_CONFIG}"; exit 1; }

PERMS_SUPPORTED=false
probe="${WORK}/probe"; : > "$probe"; chmod 600 "$probe" 2>/dev/null || true
[[ "$(stat -c '%a' "$probe" 2>/dev/null)" == "600" ]] && PERMS_SUPPORTED=true
rm -f "$probe"

if PATH="${FAKE_BIN}:${PATH}" command -v vault | grep -q "fake-bin"; then
    ok "the vault shim shadows any real vault on PATH"
else
    red "ERROR: fake-bin is not being resolved first"; exit 1
fi

# ---------------------------------------------------------------------------
printf '\n=== Argument handling ===\n'
# ---------------------------------------------------------------------------
reset_scenario
run_bootstrap --wat
assert_says "rejects unknown arguments" "Unknown argument"

reset_scenario
RC=0; OUT="$(PATH="${FAKE_BIN}:${PATH}" VAULT_ADDR='' VAULT_TOKEN=t \
    "$BOOTSTRAP" --creds-dir "$CREDS" --policy-file "$AGENT_POLICY" 2>&1)" || RC=$?
if [[ $RC -ne 0 && "$OUT" == *"VAULT_ADDR"* ]]; then
    ok "requires VAULT_ADDR"
else
    bad "requires VAULT_ADDR" "got ${RC}: ${OUT}"
fi

reset_scenario
RC=0; OUT="$(PATH="${FAKE_BIN}:${PATH}" \
    "$BOOTSTRAP" --creds-dir "$CREDS" --policy-file /nonexistent.hcl 2>&1)" || RC=$?
if [[ $RC -ne 0 && "$OUT" == *"No policy file"* ]]; then
    ok "requires the policy file to exist"
else
    bad "requires the policy file to exist" "got ${RC}: ${OUT}"
fi

# ---------------------------------------------------------------------------
printf '\n=== It composes the existing AppRole scripts ===\n'
# ---------------------------------------------------------------------------
# A third copy of role creation or secret_id issuance would be a third
# thing to keep correct.
reset_scenario
run_bootstrap
assert_rc      "provisions the role"          0
assert_log_has "delegates role creation"      "approle --role vault-agent"
assert_log_has "and passes the policy"        "--policy-file"
assert_log_has "delegates secret_id issuance" "rotate --role vault-agent"

# ---------------------------------------------------------------------------
printf '\n=== role_id and secret_id are not the same kind of thing ===\n'
# ---------------------------------------------------------------------------
reset_scenario
run_bootstrap

if [[ -s "${CREDS}/role_id" ]]; then
    ok "role_id is written"
else
    bad "role_id is written"
fi

if [[ -s "${CREDS}/secret_id" ]]; then
    ok "secret_id is written"
else
    bad "secret_id is written"
fi

if [[ "$(cat "${CREDS}/secret_id" 2>/dev/null)" == "$FAKE_SECRET_ID" ]]; then
    ok "and it is the value the rotation script produced"
else
    bad "and it is the value the rotation script produced"
fi

# The secret_id is a credential; the role_id is an identifier that is
# useless without one. Writing both 0600 would suggest the role_id needs
# protecting; writing both 0644 would leak the credential.
if [[ "$PERMS_SUPPORTED" == true ]]; then
    SID_MODE="$(stat -c '%a' "${CREDS}/secret_id" 2>/dev/null || echo unknown)"
    RID_MODE="$(stat -c '%a' "${CREDS}/role_id" 2>/dev/null || echo unknown)"
    if [[ "$SID_MODE" == "600" ]]; then
        ok "the secret_id is mode 0600"
    else
        bad "the secret_id is mode 0600" "got ${SID_MODE}"
    fi
    if [[ "$RID_MODE" == "644" ]]; then
        ok "the role_id is mode 0644, since it is not a secret"
    else
        bad "the role_id is mode 0644, since it is not a secret" "got ${RID_MODE}"
    fi
else
    skip "credential file modes" "this filesystem ignores chmod; runs in CI"
fi

# ---------------------------------------------------------------------------
printf '\n=== --wrap-ttl changes what lands on disk ===\n'
# ---------------------------------------------------------------------------
# The honest answer to secret zero. It has to change the file, not just
# the log line — a flag that only alters wording would be worse than not
# having it, because it would read as protection that is not there.
reset_scenario
run_bootstrap --wrap-ttl 5m
assert_rc      "runs with --wrap-ttl"        0
assert_log_has "and asks for a wrapped one"  "--wrap-ttl 5m"

WRAPPED="$(cat "${CREDS}/secret_id" 2>/dev/null || true)"
if [[ "$WRAPPED" == "$FAKE_WRAP_TOKEN" ]]; then
    ok "the file holds the wrapping token"
else
    bad "the file holds the wrapping token" "got '${WRAPPED}'"
fi
if [[ "$WRAPPED" != "$FAKE_SECRET_ID" ]]; then
    ok "and not the raw secret_id"
else
    bad "and not the raw secret_id" "the wrap flag changed nothing on disk"
fi

# Without it, the script should say what you are getting rather than
# leaving the weaker default silent.
reset_scenario
run_bootstrap
assert_says "the unwrapped default says so" "in the clear"

# ---------------------------------------------------------------------------
printf '\n=== Failures are not silent ===\n'
# ---------------------------------------------------------------------------
reset_scenario
export FAKE_APPROLE_RC=2
run_bootstrap
assert_rc   "a failed role creation aborts" 1
if [[ ! -f "${CREDS}/role_id" ]]; then
    ok "and no credentials are written"
else
    bad "and no credentials are written" "role_id was written anyway"
fi

reset_scenario
export FAKE_ROTATE_RC=2
run_bootstrap
assert_rc "a failed secret_id issuance aborts" 1

# The case that separates the exit-code guard from the empty-value guard:
# a rotation that prints something usable-looking and still fails. Without
# this, removing the exit-code check changes no result and the check is
# untested.
reset_scenario
export FAKE_ROTATE_RC=2 FAKE_ROTATE_NOISY=true
run_bootstrap
assert_rc "a rotation that fails after printing still aborts" 1
if [[ ! -f "${CREDS}/secret_id" ]]; then
    ok "and nothing is written from a failed rotation"
else
    bad "and nothing is written from a failed rotation" "a partial value was written"
fi

reset_scenario
export FAKE_ROLE_ID_RC=2
run_bootstrap
assert_rc "an unreadable role_id aborts" 1

# ---------------------------------------------------------------------------
printf '\n=== The agent config corrects two bad defaults ===\n'
# ---------------------------------------------------------------------------
CONFIG_TEXT="$(cat "$AGENT_CONFIG")"

# Comments stripped before checking for settings that must be ABSENT.
# The config explains in prose why tls_skip_verify is not used, so a bare
# substring search finds the explanation and reports the setting present
# — which is how this assertion first failed against a correct config.
CONFIG_CODE="$(sed 's/#.*//' "$AGENT_CONFIG")"

# Agent renders templates 0644 by default. For a file holding a live
# database password that means every account on the host can read it.
cfg_has "the rendered secret is 0600" 'perms = "0600"'

# Left false, a template referencing a field that does not exist renders
# an empty string — the application starts with a blank password and
# fails somewhere far from the cause.
cfg_has "missing template keys are an error" "error_on_missing_key = true"

# Verifying the CA is the point. tls_skip_verify would make the
# connection work and check nothing.
cfg_has "the agent verifies Vault's TLS" "ca_cert"
if [[ "$CONFIG_CODE" != *"tls_skip_verify"* ]]; then
    ok "and does not skip verification"
else
    bad "and does not skip verification"
fi

# The token sink is a credential too.
if [[ "$CONFIG_TEXT" == *"mode = 0640"* || "$CONFIG_TEXT" == *"mode = 0600"* ]]; then
    ok "the token sink is not world-readable"
else
    bad "the token sink is not world-readable"
fi

# ---------------------------------------------------------------------------
printf '\n=== The agent policy is narrow ===\n'
# ---------------------------------------------------------------------------
POLICY_TEXT="$(cat "$AGENT_POLICY")"
# Same reasoning: the policy's comments name the paths it deliberately
# does not grant.
POLICY_CODE="$(sed 's/#.*//' "$AGENT_POLICY")"

if [[ "$POLICY_TEXT" == *'path "database/creds/appdata-readonly"'* ]]; then
    ok "it can read the one credential path it renders"
else
    bad "it can read the one credential path it renders"
fi

# Agent's value is that the application holds no token. That is undone if
# the token Agent holds can read everything.
for forbidden in 'database/config' 'secret/' 'sys/policies'; do
    if [[ "$POLICY_CODE" != *"path \"${forbidden}"* ]]; then
        ok "and no access to ${forbidden}"
    else
        bad "and no access to ${forbidden}"
    fi
done

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\nskipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if [[ $FAIL -gt 0 ]]; then
    red "FAILED"
    exit 1
fi
green "All ${PASS} assertions passed."
