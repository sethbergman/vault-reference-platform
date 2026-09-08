#!/usr/bin/env bash
#
# run-tests.sh — Rotating the barrier key, and re-issuing the recovery
#                key shares
#
# Usage:
#   ./tests/key-rotation/run-tests.sh [--keep-running]
#
# Against a real three-node cluster, because both operations are ones a
# shim would agree with. A stand-in `vault` can return whatever the
# script hopes for; the question here is whether the shares Vault issued
# actually replace the ones it had, and only Vault can answer it.
#
# WHY THIS EXISTS
#
# docs/roadmap.md lists key rotation as the one seam where the PKI
# migration path — scripted, sequenced and tested end to end — has no
# counterpart. Rotating a key or re-issuing shares can leave a cluster
# nobody can unseal, which is the failure this whole architecture is
# arranged to avoid.
#
# The two halves are not the same risk and the tests say so:
#
#   the barrier key   online, no shares, cannot lock anyone out. The
#                     property worth proving is that data written under
#                     the previous key version is still readable, since
#                     the fear that stops people rotating is that it
#                     would not be.
#
#   recovery shares   when it completes, the old shares are dead. The
#                     property worth proving is exactly that — and it is
#                     asserted by trying to mint a root token with the
#                     superseded shares and requiring the failure.
#
# WHAT A GREEN RUN DOES NOT MEAN
#
# Seal migration is not covered. Moving a cluster between seal types with
# -migrate is the operation most likely to produce a cluster that will
# not unseal, and nothing here exercises it. Neither is an unseal-key
# rekey: this cluster uses a Transit seal, so its shares are recovery
# keys, and the Shamir path has no coverage.
#
# Requirements: docker compose, vault CLI, jq

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/docker/dev/docker-compose.yml")
KEYS_FILE="${REPO_ROOT}/docker/dev/.recovery-keys.json"
ROTATE="${REPO_ROOT}/scripts/rotate-keys.sh"
GENROOT="${REPO_ROOT}/scripts/generate-root-token.sh"

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

cleanup() {
    local rc=$?
    if [[ "$KEEP_RUNNING" == true ]]; then
        info "Leaving the cluster up (--keep-running)."
    else
        info "Tearing down..."
        "${COMPOSE[@]}" --profile spare down -v >/dev/null 2>&1
    fi
    rm -f "${KEYS_FILE}.superseded" "${KEYS_FILE}.new"
    rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT INT TERM

for dep in docker vault jq; do
    command -v "$dep" >/dev/null 2>&1 || { red "ERROR: ${dep} not found on PATH"; exit 1; }
done

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="${REPO_ROOT}/docker/dev/tls/ca.crt"

term() { vault read -format=json sys/key-status 2>/dev/null | jq -r '.data.term // empty'; }

# ---------------------------------------------------------------------------
info ""
info "=== A cluster to rotate ==="
# ---------------------------------------------------------------------------
info "  clearing any previous cluster..."
"${COMPOSE[@]}" --profile spare down -v >/dev/null 2>&1
rm -f "$KEYS_FILE" "${KEYS_FILE}.superseded" "${KEYS_FILE}.new"

if ! ROOT_TOKEN="$("${REPO_ROOT}/scripts/bootstrap-dev-cluster.sh" 2>"${WORK}/bootstrap.log")"; then
    bad "the cluster came up" "$(tail -12 "${WORK}/bootstrap.log")"
    printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
    red "FAILED"
    exit 1
fi
export VAULT_TOKEN="$ROOT_TOKEN"
ok "the cluster came up"

# ---------------------------------------------------------------------------
info ""
info "=== The barrier key ==="
# ---------------------------------------------------------------------------

# A mount of its own. There is no kv engine at secret/ on this cluster —
# nothing in the bootstrap enables one — so writing there fails silently
# and every read below returns empty, which looks exactly like a
# rotation that lost the data.
vault secrets enable -path=krot -version=2 kv >/dev/null 2>&1 || true
if vault kv put krot/pre-rotation value=written-under-the-old-key >/dev/null 2>&1; then
    ok "a secret can be written before rotating"
else
    bad "a secret can be written before rotating"         "without this the reads below prove nothing"
fi

BEFORE="$(term)"
if [[ -n "$BEFORE" ]]; then
    ok "sys/key-status reports a term (${BEFORE})"
else
    bad "sys/key-status reports a term"
fi

ROT_OUT="$(bash "$ROTATE" --barrier 2>&1)"; ROT_RC=$?
if [[ "$ROT_RC" -eq 0 ]]; then
    ok "rotate-keys.sh --barrier succeeds"
else
    bad "rotate-keys.sh --barrier succeeds" "$(tail -3 <<< "$ROT_OUT")"
fi

AFTER="$(term)"
if [[ -n "$AFTER" && "$AFTER" -gt "${BEFORE:-0}" ]]; then
    ok "and the barrier key term advanced (${BEFORE} -> ${AFTER})"
else
    bad "and the barrier key term advanced" "${BEFORE} -> ${AFTER}"
fi

READ_BACK="$(vault kv get -field=value krot/pre-rotation 2>/dev/null)"
if [[ "$READ_BACK" == "written-under-the-old-key" ]]; then
    ok "and data written under the previous key is still readable"
else
    bad "and data written under the previous key is still readable" \
        "got: ${READ_BACK}"
fi

if [[ "$(vault status -format=json 2>/dev/null | jq -r '.sealed')" == "false" ]]; then
    ok "and the cluster is still unsealed"
else
    bad "and the cluster is still unsealed"
fi

# Writes still work afterwards — a rotation that left the barrier in a
# state that accepted no new writes would pass every check above.
if vault kv put krot/post-rotation value=written-under-the-new-key >/dev/null 2>&1 \
   && [[ "$(vault kv get -field=value krot/post-rotation 2>/dev/null)" == "written-under-the-new-key" ]]; then
    ok "and new writes succeed under the new key version"
else
    bad "and new writes succeed under the new key version"
fi

# ---------------------------------------------------------------------------
info ""
info "=== --no-verify refuses to be casual ==="
# ---------------------------------------------------------------------------
# Checked before the real rekey, while the shares in the file are still
# the ones the cluster was built with.

NV_OUT="$(bash "$ROTATE" --recovery-keys --keys-file "$KEYS_FILE" --no-verify 2>&1)"; NV_RC=$?
if [[ "$NV_RC" -ne 0 ]]; then
    ok "--no-verify alone is refused"
else
    bad "--no-verify alone is refused" "it proceeded"
fi
if [[ "$NV_OUT" == *"--i-have-the-new-keys"* ]]; then
    ok "and names the flag that acknowledges the risk"
else
    bad "and names the flag that acknowledges the risk"
fi

# Refusing must not have started anything. A cancelled-but-begun rekey
# would make the real ceremony below fail on a nonce mismatch.
if [[ "$(vault operator rekey -target=recovery -status -format=json 2>/dev/null | jq -r '.started // false')" == "false" ]]; then
    ok "and started no rekey it then abandoned"
else
    bad "and started no rekey it then abandoned"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Re-issuing the recovery shares ==="
# ---------------------------------------------------------------------------

cp "$KEYS_FILE" "${WORK}/original-keys.json"
OLD_FIRST="$(jq -r '.recovery_keys_b64[0]' "$KEYS_FILE")"

REKEY_OUT="$(bash "$ROTATE" --recovery-keys --keys-file "$KEYS_FILE" 2>&1)"; REKEY_RC=$?
if [[ "$REKEY_RC" -eq 0 ]]; then
    ok "rotate-keys.sh --recovery-keys succeeds"
else
    bad "rotate-keys.sh --recovery-keys succeeds" "$(tail -5 <<< "$REKEY_OUT")"
fi

# The ceremony has to have actually verified. Without this, a run that
# skipped verification silently would look identical here.
if [[ "$REKEY_OUT" == *"Verified."* ]]; then
    ok "and verified the new shares before committing them"
else
    bad "and verified the new shares before committing them" \
        "no verification step in the output"
fi

NEW_FIRST="$(jq -r '.recovery_keys_b64[0]' "$KEYS_FILE" 2>/dev/null)"
if [[ -n "$NEW_FIRST" && "$NEW_FIRST" != "$OLD_FIRST" ]]; then
    ok "the shares in the keys file changed"
else
    bad "the shares in the keys file changed"
fi

if [[ "$(jq -r '.recovery_keys_b64 | length' "$KEYS_FILE" 2>/dev/null)" == "5" ]]; then
    ok "and there are still five of them"
else
    bad "and there are still five of them" \
        "$(jq -r '.recovery_keys_b64 | length' "$KEYS_FILE" 2>/dev/null)"
fi

if [[ "$(stat -c '%a' "$KEYS_FILE" 2>/dev/null)" == "600" ]]; then
    ok "and the file is still 0600"
else
    bad "and the file is still 0600" "$(stat -c '%a' "$KEYS_FILE" 2>/dev/null)"
fi

if [[ -f "${KEYS_FILE}.superseded" ]]; then
    ok "the previous shares were kept alongside"
else
    bad "the previous shares were kept alongside" \
        "an operator who needs to prove what changed has nothing to compare"
fi

# The pre-verification copy must not survive success: it holds the live
# shares, and a second copy nobody knows about is a second thing to leak.
if [[ ! -f "${KEYS_FILE}.new" ]]; then
    ok "and the pre-verification copy was consumed, not left behind"
else
    bad "and the pre-verification copy was consumed, not left behind"
fi

# Shares are secrets. stdout is for values a caller captures.
if [[ "$REKEY_OUT" != *"$NEW_FIRST"* ]]; then
    ok "no share appears in the script's output"
else
    bad "no share appears in the script's output" \
        "a recovery share in a CI log is a compromised share"
fi

# ---------------------------------------------------------------------------
info ""
info "=== The old shares are dead, and the new ones work ==="
# ---------------------------------------------------------------------------
# The assertion the whole operation is for. Everything above would pass
# if the file had been rewritten and Vault had not changed a thing.

bash "$GENROOT" --keys-file "${KEYS_FILE}.superseded" >/dev/null 2>&1; OLD_RC=$?
if [[ "$OLD_RC" -ne 0 ]]; then
    ok "the superseded shares can no longer mint a root token"
else
    bad "the superseded shares can no longer mint a root token" \
        "the rekey did not take effect; the file changed and the cluster did not"
fi

NEW_TOKEN="$(bash "$GENROOT" --keys-file "$KEYS_FILE" 2>"${WORK}/genroot.log")"; NEW_RC=$?
if [[ "$NEW_RC" -eq 0 && "$NEW_TOKEN" == hvs.* ]]; then
    ok "and the new shares can"
else
    bad "and the new shares can" "$(tail -3 "${WORK}/genroot.log")"
fi

# A cluster that rekeyed and then could not serve would be a worse
# outcome than not rekeying.
if [[ "$(vault status -format=json 2>/dev/null | jq -r '.sealed')" == "false" ]]; then
    ok "and the cluster is still unsealed"
else
    bad "and the cluster is still unsealed"
fi

if [[ "$(vault kv get -field=value krot/pre-rotation 2>/dev/null)" == "written-under-the-old-key" ]]; then
    ok "and its data is still readable"
else
    bad "and its data is still readable"
fi

# ---------------------------------------------------------------------------
info ""
info "=== A second rekey, back to back ==="
# ---------------------------------------------------------------------------
# The cancel-first behaviour. An attempt left over from the run above
# would make every share here fail on a nonce mismatch, which is the
# misdiagnosis the script exists to prevent.

SECOND_FIRST="$(jq -r '.recovery_keys_b64[0]' "$KEYS_FILE")"
SECOND_OUT="$(bash "$ROTATE" --recovery-keys --keys-file "$KEYS_FILE" 2>&1)"; SECOND_RC=$?
if [[ "$SECOND_RC" -eq 0 ]]; then
    ok "a second rekey immediately afterwards succeeds"
else
    bad "a second rekey immediately afterwards succeeds" "$(tail -4 <<< "$SECOND_OUT")"
fi

if [[ "$(jq -r '.recovery_keys_b64[0]' "$KEYS_FILE" 2>/dev/null)" != "$SECOND_FIRST" ]]; then
    ok "and rotated the shares again"
else
    bad "and rotated the shares again"
fi

# ---------------------------------------------------------------------------
info ""
info "=== The keys file stays out of version control ==="
# ---------------------------------------------------------------------------
# Both files. The superseded one holds shares that were live minutes ago.

for f in ".recovery-keys.json" ".recovery-keys.json.superseded" ".recovery-keys.json.new"; do
    if git -C "$REPO_ROOT" check-ignore -q "docker/dev/${f}"; then
        ok "docker/dev/${f} is gitignored"
    else
        bad "docker/dev/${f} is gitignored" \
            "a share in version control is compromised from the moment it lands"
    fi
done

# ---------------------------------------------------------------------------
printf '\n=== Results ===\npassed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
    green "All ${PASS} assertions passed."
else
    red "FAILED"
fi
[[ "$FAIL" -eq 0 ]]
