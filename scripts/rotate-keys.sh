#!/usr/bin/env bash
#
# rotate-keys.sh — Rotate the barrier key, or re-issue the recovery key
#                  shares
#
# Usage:
#   ./rotate-keys.sh --barrier
#   ./rotate-keys.sh --recovery-keys --keys-file <path> [options]
#
# Options:
#   --barrier              Rotate the barrier encryption key. Online, no
#                          shares needed, no downtime.
#   --recovery-keys        Re-issue the recovery key shares of an
#                          auto-unsealed cluster. Needs a quorum of the
#                          current ones.
#   --unseal-keys          Re-issue the unseal key shares of a
#                          Shamir-sealed Vault. Same ceremony, different
#                          endpoint; see below.
#   --keys-file <path>     JSON holding the current shares —
#                          recovery_keys_b64 with --recovery-keys,
#                          unseal_keys_b64 with --unseal-keys. Replaced
#                          with the new ones once they are verified; the
#                          previous file is kept as <path>.superseded.
#   --shares <n>           New share count (default: keep the current).
#   --threshold <n>        New threshold (default: keep the current).
#   --no-verify            Skip Vault's rekey verification. Refuses
#                          unless you also pass --i-have-the-new-keys.
#   --i-have-the-new-keys  Acknowledge what --no-verify gives up.
#
# Examples:
#   ./rotate-keys.sh --barrier
#   ./rotate-keys.sh --recovery-keys --keys-file docker/dev/.recovery-keys.json
#   ./rotate-keys.sh --recovery-keys --keys-file keys.json --shares 5 --threshold 3
#
# TWO OPERATIONS, AND THEY ARE NOT THE SAME RISK
#
# `--barrier` rotates the key Vault encrypts storage with. A new key
# version is created and used for new writes; every previous version
# stays in the keyring, so existing data is still readable. It needs no
# shares, takes no downtime, and cannot lock anyone out. It is routine,
# and the usual reason it has never been run is that it sounds like the
# other one.
#
# `--recovery-keys` re-issues the shares themselves. When it completes,
# the old shares are dead. If the new ones were not captured, nobody can
# generate a root token or unseal by recovery again — and nothing tells
# you until the emergency when you try. That is the same one-way door
# bootstrap-dev-cluster.sh used to leave by discarding the recovery keys,
# in a different place.
#
# WHY VERIFICATION IS ON BY DEFAULT
#
# Vault has a second phase for exactly this. With require_verification,
# the new shares are issued but do NOT take effect until a threshold of
# them is handed back. Fail that and the old shares still work. It turns
# "the new keys are wrong" from something found in an incident into
# something found during the ceremony, while the old keys still work.
#
# `vault operator rekey` cannot ask for it. The CLI has -verify for the
# second phase but no flag to require it at init, so this starts the
# ceremony through the API instead. That asymmetry is most of the reason
# this script exists rather than a runbook saying "run vault operator
# rekey": the safe form of the command is not reachable from the CLI.
#
# THREE THINGS VAULT DOES HERE THAT A SCRIPT HAS TO KNOW
#
#   The new shares come back as `keys_base64`. `operator init` calls the
#   same thing `recovery_keys_b64`. Reading the wrong name yields an
#   empty array and a rekey that looks complete with nothing to show.
#
#   The last verify prints English, not JSON. Every share before the
#   threshold returns a JSON progress object; the one that completes
#   prints "Rekey verification successful..." as plain text and ignores
#   -format=json. A loop watching for `.complete` therefore never sees
#   it, keeps submitting, and gets "no rekey configuration found" from
#   the next call — which reads as failure at the exact moment the
#   operation succeeded. That misreading is how you destroy a set of
#   recovery keys: the rekey took effect and the script threw the new
#   shares away. It is guarded below by matching the text as well.
#
#   require_verification is a bool. `vault write k=v` sends strings, and
#   the endpoint rejects a string, so the request body is typed JSON on
#   stdin.
#
# DELIBERATE BEHAVIOURS
#
#   The new shares are written to <keys-file>.new BEFORE verification,
#   and are never held only in memory. Verification is the step most
#   likely to fail, and it is also the step after which the old shares
#   may already be dead — so anything that exits between issuing and
#   committing must still leave the new shares on disk. This is the whole
#   failure above, made structurally impossible rather than handled.
#
#   An in-progress rekey is cancelled first, not joined. A half-finished
#   attempt from an interrupted run makes every share fail on a nonce
#   mismatch, which reads as "my keys are wrong" — the most alarming
#   possible misdiagnosis given what this script does.
#
#   Shares go to files, never to stdout. A recovery share in a CI log or
#   a scrollback buffer is a compromised share.
#
# RECOVERY KEYS AND UNSEAL KEYS ARE THE SAME CEREMONY
#
# Which one a Vault has depends only on how it is sealed. An
# auto-unsealed cluster has recovery keys; a Shamir-sealed one has unseal
# keys; scripts/migrate-seal.sh turns each into the other without
# changing their values. So this runs one ceremony against two endpoints:
#
#   --recovery-keys   sys/rekey-recovery-key/*   vault operator rekey -target=recovery
#   --unseal-keys     sys/rekey/*                vault operator rekey
#
# The CLI calls the second one "barrier" and makes it the default target,
# which is worth knowing because `vault operator rekey` with no arguments
# on an auto-unsealed cluster addresses a set of keys that cluster does
# not use.
#
# Requirements: vault, jq. VAULT_ADDR and a token with sudo on
# sys/rekey-recovery-key or sys/rekey, and on sys/rotate.

set -euo pipefail

MODE=""
KEYS_FILE=""
SHARES=""
THRESHOLD=""
VERIFY=true
ACKNOWLEDGED=false

log()  { printf '[rotate-keys] %s\n' "$*" >&2; }
warn() { printf '\033[33m[rotate-keys] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m[rotate-keys] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --barrier)             MODE="barrier"; shift ;;
        --recovery-keys)       MODE="recovery"; shift ;;
        --unseal-keys)         MODE="unseal"; shift ;;
        --keys-file)           KEYS_FILE="$2"; shift 2 ;;
        --shares)              SHARES="$2"; shift 2 ;;
        --threshold)           THRESHOLD="$2"; shift 2 ;;
        --no-verify)           VERIFY=false; shift ;;
        --i-have-the-new-keys) ACKNOWLEDGED=true; shift ;;
        -h|--help)             usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$MODE" ]] \
    || die "one of --barrier, --recovery-keys or --unseal-keys is required"
for dep in vault jq; do
    command -v "$dep" >/dev/null 2>&1 || die "${dep} not found on PATH"
done
[[ -n "${VAULT_ADDR:-}" ]] || die "VAULT_ADDR is not set"

# ---------------------------------------------------------------------------
# The barrier key
# ---------------------------------------------------------------------------

if [[ "$MODE" == "barrier" ]]; then
    BEFORE="$(vault read -format=json sys/key-status 2>/dev/null | jq -r '.data.term // empty')" \
        || die "could not read sys/key-status"
    [[ -n "$BEFORE" ]] || die "sys/key-status returned no term; is the token authorised?"

    log "Barrier key is at term ${BEFORE}."
    vault operator rotate >/dev/null 2>&1 || die "rotate failed"

    AFTER="$(vault read -format=json sys/key-status 2>/dev/null | jq -r '.data.term // empty')"
    [[ -n "$AFTER" ]] || die "could not read sys/key-status after rotating"

    # Asserted rather than assumed: a rotation that did not happen is
    # indistinguishable from one that did, by exit status alone.
    [[ "$AFTER" -gt "$BEFORE" ]] \
        || die "the term did not advance (${BEFORE} -> ${AFTER}); nothing was rotated"

    log "Rotated to term ${AFTER}."
    log "Previous key versions stay in the keyring, so existing data is still readable."
    exit 0
fi

# ---------------------------------------------------------------------------
# The recovery key shares
# ---------------------------------------------------------------------------

[[ -n "$KEYS_FILE" ]] || die "--${MODE}-keys needs --keys-file"
[[ -f "$KEYS_FILE" ]] || die "keys file not found: ${KEYS_FILE}"

if [[ "$VERIFY" == false && "$ACKNOWLEDGED" == false ]]; then
    die "--no-verify skips the phase that proves the new shares work.

       Without it, a mis-transcribed or truncated share is discovered the
       next time somebody needs to generate a root token, by which point
       the old shares are already dead. Pass --i-have-the-new-keys as
       well if that is genuinely what you want."
fi

# The only differences between the two ceremonies, in one place. Getting
# these crossed addresses a set of keys the Vault in front of you does
# not use, and the error it produces says nothing about which set.
if [[ "$MODE" == "recovery" ]]; then
    REKEY_PATH="sys/rekey-recovery-key"
    TARGET_ARGS=(-target=recovery)
    KEY_FIELD="recovery_keys_b64"
    SHARES_FIELD="recovery_keys_shares"
    THRESHOLD_FIELD="recovery_keys_threshold"
    KIND="recovery"
else
    REKEY_PATH="sys/rekey"
    TARGET_ARGS=()
    KEY_FIELD="unseal_keys_b64"
    SHARES_FIELD="unseal_keys_shares"
    THRESHOLD_FIELD="unseal_threshold"
    KIND="unseal"
fi

mapfile -t OLD_KEYS < <(jq -r ".${KEY_FIELD}[]? // empty" "$KEYS_FILE")
[[ ${#OLD_KEYS[@]} -gt 0 ]] || die "no ${KEY_FIELD} found in ${KEYS_FILE}.

       That file holds the other kind of key. An auto-unsealed cluster
       has recovery keys and a Shamir-sealed one has unseal keys; check
       which this Vault is with 'vault status'."

# Default to the shape already in use rather than Vault's defaults.
# Silently turning a 5-of-3 into Vault's default hands back a different
# number of shares than the holders expect, and nobody counts them.
CUR_SHARES="$(jq -r ".${SHARES_FIELD} // empty" "$KEYS_FILE")"
CUR_THRESHOLD="$(jq -r ".${THRESHOLD_FIELD} // empty" "$KEYS_FILE")"
SHARES="${SHARES:-${CUR_SHARES:-${#OLD_KEYS[@]}}}"
THRESHOLD="${THRESHOLD:-${CUR_THRESHOLD:-3}}"

[[ "$SHARES" =~ ^[0-9]+$ && "$THRESHOLD" =~ ^[0-9]+$ ]] \
    || die "--shares and --threshold must be numbers"
[[ "$THRESHOLD" -le "$SHARES" ]] \
    || die "--threshold ${THRESHOLD} exceeds --shares ${SHARES}"

NEW_FILE="${KEYS_FILE}.new"

vault operator rekey "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" -cancel >/dev/null 2>&1 || true

INIT_BODY="$(jq -n --argjson shares "$SHARES" --argjson threshold "$THRESHOLD" \
    --argjson verify "$VERIFY" \
    '{secret_shares: $shares, secret_threshold: $threshold, require_verification: $verify}')"

INIT_JSON="$(printf '%s' "$INIT_BODY" \
    | vault write -format=json "${REKEY_PATH}/init" - 2>&1)" \
    || die "could not start a rekey: ${INIT_JSON}"

NONCE="$(jq -r '.data.nonce // .nonce // empty' <<< "$INIT_JSON")"
[[ -n "$NONCE" ]] || die "rekey init returned no nonce: ${INIT_JSON}"

# Asserted, not assumed. If the field were ever ignored rather than
# rejected, the ceremony would run with no verification phase and the new
# shares would take effect unchecked — the one thing this is avoiding.
if [[ "$VERIFY" == true ]]; then
    GOT_VREQ="$(jq -r '.data.verification_required // .verification_required // empty' <<< "$INIT_JSON")"
    [[ "$GOT_VREQ" == "true" ]] \
        || die "asked for verification and Vault did not enable it: ${INIT_JSON}"
fi

log "Started a ${KIND}-key rekey (nonce ${NONCE}), ${THRESHOLD} of ${SHARES}."

OUT=""
USED=0
for KEY in "${OLD_KEYS[@]}"; do
    [[ -n "$KEY" ]] || continue
    USED=$((USED + 1))
    OUT="$(vault operator rekey "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" -nonce="$NONCE" -format=json "$KEY" 2>&1)" || {
        vault operator rekey "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" -cancel >/dev/null 2>&1 || true
        die "share ${USED} was rejected: ${OUT}"
    }
    [[ "$(jq -r '.complete // false' <<< "$OUT" 2>/dev/null)" == "true" ]] && break
done

if [[ "$(jq -r '.complete // false' <<< "$OUT" 2>/dev/null)" != "true" ]]; then
    vault operator rekey "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" -cancel >/dev/null 2>&1 || true
    die "ran out of shares after ${USED} without reaching the threshold"
fi

# keys_base64, not keys_b64 — see the header.
mapfile -t NEW_KEYS < <(jq -r '.keys_base64[]? // empty' <<< "$OUT")
[[ ${#NEW_KEYS[@]} -eq "$SHARES" ]] \
    || die "expected ${SHARES} new shares, got ${#NEW_KEYS[@]}: ${OUT}"

# On disk before verification, and deliberately not in a temp directory
# that a trap removes. Everything after this line can fail; none of it
# may lose the shares.
( umask 077; jq -n \
    --argjson keys "$(jq -n '$ARGS.positional' --args "${NEW_KEYS[@]}")" \
    --argjson shares "$SHARES" --argjson threshold "$THRESHOLD" \
    --arg kf "$KEY_FIELD" --arg sf "$SHARES_FIELD" --arg tf "$THRESHOLD_FIELD" '{($kf): $keys, ($sf): $shares, ($tf): $threshold}' \
    > "$NEW_FILE" ) || die "could not write the new shares to ${NEW_FILE}"
chmod 0600 "$NEW_FILE"
log "New shares written to ${NEW_FILE} (0600), before verification."

if [[ "$VERIFY" == true ]]; then
    V_NONCE="$(jq -r '.verification_nonce // empty' <<< "$OUT")"
    [[ -n "$V_NONCE" ]] \
        || die "verification was requested but Vault returned no verification_nonce"

    log "Verifying the new shares (nonce ${V_NONCE})..."

    VERIFIED=false
    V_USED=0
    for KEY in "${NEW_KEYS[@]}"; do
        # Never submit more than the threshold. Past it the attempt is
        # already gone and the next call answers "no rekey configuration
        # found" — an error about success.
        [[ "$V_USED" -ge "$THRESHOLD" ]] && break
        V_USED=$((V_USED + 1))

        V_OUT="$(vault operator rekey "${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}" -verify -nonce="$V_NONCE" \
                 -format=json "$KEY" 2>&1)" || {
            die "the new share ${V_USED} was rejected during verification:
       ${V_OUT}

       The rekey has NOT taken effect. The shares in ${KEYS_FILE} are
       still the live ones, and the rejected new set is in ${NEW_FILE}."
        }

        # Two completion signals, because the last one is not JSON.
        if [[ "$(jq -r '.complete // false' <<< "$V_OUT" 2>/dev/null)" == "true" ]] \
           || [[ "$V_OUT" == *"verification successful"* ]]; then
            VERIFIED=true
            break
        fi
    done

    [[ "$VERIFIED" == true ]] || die "verification did not complete after ${V_USED} share(s).
       The rekey has NOT taken effect; the old shares still work.
       The unverified new set is in ${NEW_FILE}."

    log "Verified. The new shares are now the live ones."
else
    warn "Verification skipped. The new shares took effect unverified."
fi

cp "$KEYS_FILE" "${KEYS_FILE}.superseded" \
    || die "could not preserve the previous keys file; the new shares are in ${NEW_FILE}"
chmod 0600 "${KEYS_FILE}.superseded"
mv "$NEW_FILE" "$KEYS_FILE" \
    || die "could not install the new keys file; they are in ${NEW_FILE}"
chmod 0600 "$KEYS_FILE"

log "Wrote ${SHARES} new ${KIND} shares to ${KEYS_FILE} (0600)."
log "The previous shares are at ${KEYS_FILE}.superseded and no longer work."
log "Distribute the new shares and delete both copies from this host."
