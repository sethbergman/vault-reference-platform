#!/usr/bin/env bash
#
# run-tests.sh — Tests for the database secrets engine bootstrap
#
# Usage:
#   ./tests/database/run-tests.sh
#
# Runs in about a second. No Vault, no Postgres, no credentials.
#
# What this covers is the *configuration*: that the connection is scoped,
# that the roles grant what they claim, that the policies do not hand a
# consumer more than it needs, and that root rotation happens last.
#
# What it deliberately does not cover is whether the credentials work.
# That needs a real database and lives in tests/integration, which issues
# a credential, connects to Postgres with it, checks a readonly role
# genuinely cannot write, and confirms revocation drops the role.
#
# Requirements: bash, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP="${REPO_ROOT}/scripts/bootstrap-database-secrets.sh"
FAKE_BIN="${SCRIPT_DIR}/fake-bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

RC=0
OUT=""
LOG=""

reset_scenario() {
    export FAKE_MOUNT_EXISTS=false
    export FAKE_CONFIG_EXISTS=false
    export FAKE_ENABLE_RC=0
    export FAKE_CONFIG_RC=0
    export FAKE_ROLE_RC=0
    export FAKE_ROTATE_RC=0
    export FAKE_POLICY_RC=0
    export FAKE_POLICY_DIR="$WORK"
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_TOKEN=s.testtoken
    rm -f "${WORK}"/policy-*.hcl
}

run_bootstrap() {
    local logfile="${WORK}/calls.log"
    : > "$logfile"
    RC=0
    OUT="$(FAKE_LOG="$logfile" PATH="${FAKE_BIN}:${PATH}" \
        "$BOOTSTRAP" --password test-bootstrap-pw "$@" 2>&1)" || RC=$?
    LOG="$(cat "$logfile")"
}

assert_rc()        { if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1" "expected ${2}, got ${RC}: ${OUT}"; fi; }
assert_says()      { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1" "output lacked: ${2}"; fi; }
assert_log_has()   { if [[ "$LOG" == *"$2"* ]]; then ok "$1"; else bad "$1" "no call matching: ${2}"; fi; }
assert_log_lacks() { if [[ "$LOG" != *"$2"* ]]; then ok "$1"; else bad "$1" "unexpected call: ${2}"; fi; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || { red "ERROR: jq not found on PATH"; exit 1; }
[[ -x "$BOOTSTRAP" ]] || { red "ERROR: ${BOOTSTRAP} is not executable"; exit 1; }

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
    "$BOOTSTRAP" --password p 2>&1)" || RC=$?
if [[ $RC -ne 0 && "$OUT" == *"VAULT_ADDR"* ]]; then
    ok "requires VAULT_ADDR"
else
    bad "requires VAULT_ADDR" "got ${RC}: ${OUT}"
fi

reset_scenario
RC=0; OUT="$(PATH="${FAKE_BIN}:${PATH}" POSTGRES_PASSWORD='' \
    "$BOOTSTRAP" 2>&1)" || RC=$?
if [[ $RC -ne 0 && "$OUT" == *"bootstrap password"* ]]; then
    ok "requires a bootstrap password"
else
    bad "requires a bootstrap password" "got ${RC}: ${OUT}"
fi

# ---------------------------------------------------------------------------
printf '\n=== The connection is scoped ===\n'
# ---------------------------------------------------------------------------
reset_scenario
run_bootstrap
assert_rc      "configures a fresh mount" 0
assert_log_has "enables the database engine" "secrets enable"
assert_log_has "configures the connection"   "database/config/appdata"

# allowed_roles is deny-by-default. Omitted, no role can use the
# connection; set to "*", every role added later can — including ones
# added by someone who never looked at this connection.
assert_log_has   "names the roles allowed to use it" "allowed_roles=appdata-readonly,appdata-readwrite"
assert_log_lacks "does not allow every role"         "allowed_roles=*"

assert_log_has "creates a readonly role"  "database/roles/appdata-readonly"
assert_log_has "creates a readwrite role" "database/roles/appdata-readwrite"

# ---------------------------------------------------------------------------
printf '\n=== Credentials expire without Vault'"'"'s help ===\n'
# ---------------------------------------------------------------------------
# VALID UNTIL makes the database enforce the expiry itself. Without it a
# credential outlives its lease whenever Vault is unreachable at the
# moment revocation was due — which is exactly when it matters.
reset_scenario
run_bootstrap

# Asserted per role, not against the whole log. Checking the log as a
# whole passes when *either* role carries the setting, so dropping it
# from one of the two goes unnoticed — which is exactly what happened
# when this was first written and mutation-tested.
RO_STMT="$(grep 'database/roles/appdata-readonly' <<< "$LOG" | head -1)"
RW_STMT="$(grep 'database/roles/appdata-readwrite' <<< "$LOG" | head -1)"

for pair in "readonly:$RO_STMT" "readwrite:$RW_STMT"; do
    role="${pair%%:*}"
    stmt="${pair#*:}"

    if [[ "$stmt" == *"VALID UNTIL '{{expiration}}'"* ]]; then
        ok "${role}: the creation statement sets VALID UNTIL"
    else
        bad "${role}: the creation statement sets VALID UNTIL" "${stmt:0:120}"
    fi

    if [[ "$stmt" == *"default_ttl=1h"* && "$stmt" == *"max_ttl=24h"* ]]; then
        ok "${role}: TTL and max TTL are set"
    else
        bad "${role}: TTL and max TTL are set" "${stmt:0:120}"
    fi

    # Dropping a role that owns objects fails, leaving it alive in the
    # database with its lease gone from Vault — managed-looking and not
    # managed. REASSIGN/DROP OWNED first is what makes revocation work.
    if [[ "$stmt" == *"REASSIGN OWNED BY"* && "$stmt" == *"DROP ROLE IF EXISTS"* ]]; then
        ok "${role}: revocation reassigns owned objects, then drops the role"
    else
        bad "${role}: revocation reassigns owned objects, then drops the role" "${stmt:0:120}"
    fi
done

# ---------------------------------------------------------------------------
printf '\n=== The grants differ ===\n'
# ---------------------------------------------------------------------------
# Two roles that both grant everything are one role with two names.
if [[ "$RO_STMT" == *"GRANT SELECT ON ALL TABLES"* && "$RO_STMT" != *"INSERT"* ]]; then
    ok "readonly grants SELECT and not INSERT"
else
    bad "readonly grants SELECT and not INSERT" "${RO_STMT:0:120}"
fi

if [[ "$RW_STMT" == *"INSERT"* && "$RW_STMT" == *"DELETE"* ]]; then
    ok "readwrite grants INSERT and DELETE"
else
    bad "readwrite grants INSERT and DELETE" "${RW_STMT:0:120}"
fi

# ---------------------------------------------------------------------------
printf '\n=== Consumer policies are narrow ===\n'
# ---------------------------------------------------------------------------
reset_scenario
run_bootstrap

RO_POLICY="$(cat "${WORK}/policy-appdata-readonly.hcl" 2>/dev/null || echo "")"
if [[ -n "$RO_POLICY" ]]; then
    ok "a policy is written for the readonly role"
else
    bad "a policy is written for the readonly role"
fi

if [[ "$RO_POLICY" == *'path "database/creds/appdata-readonly"'* ]]; then
    ok "it grants read on its own creds path"
else
    bad "it grants read on its own creds path"
fi

# The connection config holds the credential Vault itself connects with. A
# consumer that can read it does not need dynamic credentials, because it
# already has the keys to the database.
# Matched on a path stanza, not a bare substring: the policy's own
# comment explains why database/config is absent, and a substring check
# would fail on the explanation for the very rule it is checking.
if [[ "$RO_POLICY" != *'path "database/config'* ]]; then
    ok "and no access to the connection config"
else
    bad "and no access to the connection config" "the policy grants a path under database/config"
fi

if [[ "$RO_POLICY" != *'path "database/creds/appdata-readwrite"'* ]]; then
    ok "and no access to the other role's credentials"
else
    bad "and no access to the other role's credentials"
fi

# ---------------------------------------------------------------------------
printf '\n=== Root rotation ===\n'
# ---------------------------------------------------------------------------
reset_scenario
run_bootstrap
assert_log_has "rotates the bootstrap password by default" "rotate-root/appdata"

# Ordering matters: everything before it needs the connection working, and
# once it runs the password the script was given is dead.
ROTATE_POS="$(grep -n 'rotate-root' <<< "$LOG" | head -1 | cut -d: -f1)"
ROLES_POS="$(grep -n 'database/roles/' <<< "$LOG" | tail -1 | cut -d: -f1)"
if [[ -n "$ROTATE_POS" && -n "$ROLES_POS" && "$ROTATE_POS" -gt "$ROLES_POS" ]]; then
    ok "rotation happens after the roles are created"
else
    bad "rotation happens after the roles are created" \
        "rotate at line ${ROTATE_POS:-?}, last role at ${ROLES_POS:-?}"
fi

reset_scenario
run_bootstrap --no-rotate-root
assert_log_lacks "--no-rotate-root skips it" "rotate-root"
# Skipping leaves a shared database password in place, which is the thing
# this engine exists to remove. Saying so is the least it can do.
assert_says "and warns that a shared credential remains" "shared database credential"

# ---------------------------------------------------------------------------
printf '\n=== Refusing to clobber a rotated connection ===\n'
# ---------------------------------------------------------------------------
# Once the root password has been rotated, the value passed on the command
# line is stale. Rewriting the connection with it replaces a working
# credential with one the database rejects, and every later issuance
# fails — with an error pointing at the database, not at this script.
reset_scenario
export FAKE_MOUNT_EXISTS=true FAKE_CONFIG_EXISTS=true
run_bootstrap
assert_rc        "an existing connection is left alone" 0
assert_log_lacks "and not rewritten"                    "write database/config/appdata"
assert_says      "and it explains why"                  "no longer valid"

reset_scenario
export FAKE_MOUNT_EXISTS=true FAKE_CONFIG_EXISTS=true
run_bootstrap --force
assert_log_has "--force rewrites it" "database/config/appdata"

# ---------------------------------------------------------------------------
printf '\n=== Failures are not silent ===\n'
# ---------------------------------------------------------------------------
reset_scenario
export FAKE_CONFIG_RC=2
run_bootstrap
assert_rc        "a failed connection config aborts" 1
assert_says      "and points at the likely cause"    "is postgres reachable"
assert_log_lacks "and creates no roles"              "database/roles/"

reset_scenario
export FAKE_ROLE_RC=2
run_bootstrap
assert_rc        "a failed role creation aborts" 1
assert_log_lacks "and does not rotate the root"  "rotate-root"

reset_scenario
export FAKE_ROTATE_RC=2
run_bootstrap
assert_rc "a failed rotation aborts" 1

# ---------------------------------------------------------------------------
printf '\n=== TLS to the database ===\n'
# ---------------------------------------------------------------------------
# sslmode=disable is right for the local Docker profile and wrong
# everywhere else. It must be overridable, and the default must be
# visible in the connection string rather than implied.
reset_scenario
run_bootstrap
assert_log_has "the default sslmode is explicit" "sslmode=disable"

reset_scenario
run_bootstrap --sslmode verify-full
assert_log_has "sslmode is overridable" "sslmode=verify-full"


# ---------------------------------------------------------------------------
printf '\n=== MySQL is the same interface over a different database ===\n'
# ---------------------------------------------------------------------------
# The engine argument changes three things and nothing else: the plugin,
# the connection string, and the SQL. Mount, roles, policies and root
# rotation are shared, so these assert the three that differ and trust
# the sections above for the rest.
reset_scenario
run_bootstrap --engine mysql
assert_rc        "the mysql path configures cleanly" 0
assert_log_has   "selects the mysql plugin"          "plugin_name=mysql-database-plugin"
assert_log_lacks "and not the postgres one"          "plugin_name=postgresql-database-plugin"

# The MySQL driver takes a DSN, not a libpq URL. Getting this wrong fails
# at connection time with a parse error that names neither.
assert_log_has   "builds a mysql DSN"       "@tcp(mysql:3306)/appdata"
assert_log_lacks "not a postgresql:// URL"  "postgresql://"

assert_log_has "creates a MySQL user rather than a role" "CREATE USER '{{name}}'@'%'"
assert_log_has "and drops it on revocation"              "DROP USER IF EXISTS '{{name}}'@'%'"

# Scoped to the one database. GRANT ... ON *.* would hand every issued
# credential the run of the server.
# Backtick-quoted, matching the double-quoting the Postgres statements
# give the same variable. Unquoted, a hyphenated or reserved-word schema
# is a MySQL parse error at issuance naming neither the flag nor the
# value -- and the default `appdata` is a bare identifier, so nothing
# here would have noticed.
assert_log_has   "grants only on the target database" "ON \`appdata\`.*"
assert_log_lacks "never grants server-wide"           "ON *.*"

reset_scenario
run_bootstrap --engine mysql --database my-app
assert_log_has "a hyphenated database name is quoted, not a parse error" \
    "ON \`my-app\`.*"

# The other place the engines are not equivalent, and the reason it is not
# quietly fixed: MySQL grants privileges per schema, so CREATE/ALTER/DROP
# on the readwrite role would cover every table in the database. Postgres
# scopes the same capability by ownership, to the tables the credential
# itself created. They cannot be made equivalent, so MySQL readwrite is
# DML-only and docs/dynamic-secrets.md says so.
reset_scenario
run_bootstrap --engine mysql
# Pins the whole privilege list rather than naming the DDL keywords to
# reject. Listing them is circular -- the assertion catches exactly the
# string you thought to write down, and a grant of just CREATE walks
# through it. Anchoring on "DELETE ON" instead means any privilege added
# to the list breaks the match, whichever one it is.
assert_log_has "mysql readwrite grants DML and nothing more" "GRANT SELECT, INSERT, UPDATE, DELETE ON \`appdata\`.*"

reset_scenario
run_bootstrap
assert_log_has "while postgres readwrite creates within its own schema" \
    "GRANT USAGE, CREATE ON SCHEMA public"

# ---------------------------------------------------------------------------
printf '\n=== The difference between the engines is not hidden ===\n'
# ---------------------------------------------------------------------------
# This is the assertion worth reading. The Postgres roles carry VALID
# UNTIL, so the database enforces the expiry itself and a credential dies
# on schedule even if Vault is unreachable at lease end.
#
# MySQL cannot express that. CREATE USER takes no deadline, so a MySQL
# credential lives until Vault revokes it and no longer has a
# database-side backstop.
#
# The failure this guards against is someone "fixing" the asymmetry by
# pasting VALID UNTIL into the MySQL statements, where it is a syntax
# error, or quietly assuming the two paths are equivalent. They are not,
# and the docs say which is which.
# Its own run, not whatever the previous section happened to leave
# behind. Inheriting that state is how this assertion silently started
# reading a postgres log and reporting a failure about MySQL.
reset_scenario
run_bootstrap --engine mysql
assert_log_lacks "the mysql path claims no expiry MySQL cannot enforce" "VALID UNTIL"

reset_scenario
run_bootstrap
assert_log_has "while the postgres path still has its backstop" "VALID UNTIL '{{expiration}}'"

# ---------------------------------------------------------------------------
printf '\n=== Engine-specific defaults ===\n'
# ---------------------------------------------------------------------------
# vaultadmin is a shared default rather than something the mysql branch
# sets, so these two hold for either engine. They are not a claim about
# engine-specific behaviour -- they are a standing guard against the
# shortcut of pointing MySQL at root, wherever someone might reintroduce
# it. Vault needs CREATE USER and GRANT OPTION, which an ordinary
# per-database account lacks, and root is the obvious way to get them;
# but this script rotates the password of whatever account it connects
# as, and root's password is what the container healthcheck uses, so
# rotating it would leave the container unhealthy while MySQL was fine.
# docker/mysql/init/ creates vaultadmin for the purpose.
reset_scenario
run_bootstrap --engine mysql
assert_log_has   "no engine connects as root" "username=vaultadmin"
assert_log_lacks "so rotation cannot break the healthcheck" "username=root"

reset_scenario
run_bootstrap --engine mysql --username appuser
assert_log_has "an explicit username is still respected" "username=appuser"

# sslmode is libpq vocabulary; the MySQL driver wants tls.
reset_scenario
run_bootstrap --engine mysql
assert_log_has "sslmode disable becomes tls=false" "tls=false"

reset_scenario
run_bootstrap --engine mysql --sslmode verify-full
assert_log_has "and anything else turns TLS on" "tls=true"

reset_scenario
run_bootstrap --engine sqlite
assert_rc   "an unsupported engine is rejected" 1
assert_says "and says which are supported"      "must be postgres or mysql"
# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    red "FAILED"
    exit 1
fi
green "All ${PASS} assertions passed."
