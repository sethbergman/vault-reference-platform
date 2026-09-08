#!/usr/bin/env bash
#
# bootstrap-quotas.sh — Configure API rate limit quotas
#
# Usage:
#   ./bootstrap-quotas.sh [options]
#
# Options:
#   --rate <n>          Requests per interval for the global quota.
#                       Omit to configure exemptions and headers only.
#   --interval <dur>    Window for the global quota (default: 1s)
#   --name <name>       Quota name (default: global)
#   --path <prefix>     Limit one path prefix instead of everything
#   --exempt <path>     Extra path to exempt. Repeatable.
#   --no-headers        Do not enable rate limit response headers.
#                       Read what that costs below first.
#   --show              Print the current config and quotas, then exit
#   --remove            Delete the named quota and exit
#
# Examples:
#   ./bootstrap-quotas.sh --show
#   ./bootstrap-quotas.sh --rate 2000 --interval 1s
#   ./bootstrap-quotas.sh --rate 50 --interval 1s --path secret/
#   ./bootstrap-quotas.sh --remove --name global
#
# WHY THIS IS A SCRIPT AND NOT TWO CLI CALLS
#
# Rate limit quotas are two `vault write` calls, and both of them have a
# way of appearing to work while doing nothing or the wrong thing. Every
# one of the following was established by running it.
#
#   sys/quotas/config is REPLACED, not merged. Vault ships seven exempt
#   paths, among them sys/health, sys/seal-status and sys/unseal. Write a
#   single unrelated field to that endpoint --
#
#       vault write sys/quotas/config enable_rate_limit_response_headers=true
#
#   -- and the exempt list becomes empty. Nothing warns you. The next
#   global quota you set then applies to your load balancer's health
#   checks, and to unseal.
#
#   rate_limit_exempt_paths is a LIST, and the CLI's k=v syntax makes a
#   comma-joined value into one element rather than several:
#
#       rate_limit_exempt_paths="sys/health,sys/seal-status"
#         -> ["sys/health,sys/seal-status"]
#
#   which is a single path containing a comma, matching nothing. It
#   writes successfully and protects nothing. This script sends JSON so
#   the field is unambiguously a list, then reads it back and counts it.
#
#   A global quota rate limits sys/quotas/* as well. Once the budget is
#   spent you cannot read the quota, and you cannot delete it: the DELETE
#   is itself a request and answers 429. The quota defends itself.
#
# WHAT THIS SETS, AND WHY
#
# The exempt list is always written as: Vault's seven shipped defaults,
# plus sys/quotas/config and sys/quotas/rate-limit, plus anything given
# with --exempt.
#
# The two quota paths are the important addition. With them exempt, a
# quota set far too low is an inconvenience -- ordinary requests get 429
# and you delete the quota. Without them it is an outage you wait out.
#
# Response headers are on by default because a quota's 429 and a healthy
# standby's 429 are otherwise the same response. Vault answers 429 on
# sys/health from any standby, which is why the AWS target group in
# terraform/aws matches 200,429 -- so a 429 alone cannot tell you whether
# a node is a standby or is refusing traffic. With headers on, the quota
# response carries retry-after and x-ratelimit-*, and the standby's does
# not.
#
# IF YOU HAVE ALREADY LOCKED YOURSELF OUT
#
# Wait for the interval to elapse without sending anything, then spend
# the first request of the new window on the delete:
#
#     sleep <interval>
#     vault delete sys/quotas/rate-limit/<name>
#
# It returns 204. Any request before it consumes the budget and you wait
# again. Standby nodes do not help; they forward to the leader.
#
# Requirements: vault, jq. VAULT_ADDR and a token with sudo on
# sys/quotas.

set -euo pipefail

RATE=""
INTERVAL="1s"
NAME="global"
QPATH=""
HEADERS=true
SHOW=false
REMOVE=false
EXTRA_EXEMPT=()

# Vault's own defaults, restated because writing the config replaces them
# and this script always writes the config.
DEFAULT_EXEMPT=(
    "sys/generate-recovery-token/attempt"
    "sys/generate-recovery-token/update"
    "sys/generate-root/attempt"
    "sys/generate-root/update"
    "sys/health"
    "sys/seal-status"
    "sys/unseal"
)

# The two that turn a lockout into an inconvenience.
ADMIN_EXEMPT=(
    "sys/quotas/config"
    "sys/quotas/rate-limit"
)

log()  { printf '[quotas] %s\n' "$*" >&2; }
warn() { printf '\033[33m[quotas] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m[quotas] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rate)        RATE="$2"; shift 2 ;;
        --interval)    INTERVAL="$2"; shift 2 ;;
        --name)        NAME="$2"; shift 2 ;;
        --path)        QPATH="$2"; shift 2 ;;
        --exempt)      EXTRA_EXEMPT+=("$2"); shift 2 ;;
        --no-headers)  HEADERS=false; shift ;;
        --show)        SHOW=true; shift ;;
        --remove)      REMOVE=true; shift ;;
        -h|--help)     usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

for dep in vault jq; do
    command -v "$dep" >/dev/null 2>&1 || die "${dep} not found on PATH"
done
[[ -n "${VAULT_ADDR:-}" ]] || die "VAULT_ADDR is not set"

# ---------------------------------------------------------------------------

if [[ "$SHOW" == true ]]; then
    log "Quota config:"
    vault read -format=json sys/quotas/config 2>/dev/null \
        | jq '.data | {rate_limit_exempt_paths, enable_rate_limit_response_headers,
                       enable_rate_limit_audit_logging}' \
        || die "could not read sys/quotas/config. If a quota is already too
       tight this read is itself rate limited — see the header."
    log "Quotas:"
    vault list -format=json sys/quotas/rate-limit 2>/dev/null | jq '.' || echo "  (none)"
    exit 0
fi

if [[ "$REMOVE" == true ]]; then
    log "Deleting quota ${NAME}..."
    OUT="$(vault delete "sys/quotas/rate-limit/${NAME}" 2>&1)" || die "could not delete ${NAME}:
       ${OUT}

       A 429 here means the quota is blocking its own removal. Send
       nothing for one full interval, then run this again — the first
       request of a new window succeeds."
    log "Deleted."
    exit 0
fi

# ---------------------------------------------------------------------------
# The config, as JSON, because the list field cannot be set any other way
# ---------------------------------------------------------------------------

EXEMPT=("${DEFAULT_EXEMPT[@]}" "${ADMIN_EXEMPT[@]}")
[[ ${#EXTRA_EXEMPT[@]} -gt 0 ]] && EXEMPT+=("${EXTRA_EXEMPT[@]}")

BODY="$(jq -n \
    --argjson paths "$(jq -n '$ARGS.positional' --args "${EXEMPT[@]}")" \
    --argjson headers "$HEADERS" \
    '{rate_limit_exempt_paths: $paths, enable_rate_limit_response_headers: $headers}')"

log "Writing quota config with ${#EXEMPT[@]} exempt paths..."
printf '%s' "$BODY" | vault write sys/quotas/config - >/dev/null 2>&1 \
    || die "could not write sys/quotas/config"

# Read back and count. A comma-joined value writes successfully and
# produces one element; the count is what distinguishes that from a list.
GOT="$(vault read -format=json sys/quotas/config 2>/dev/null \
    | jq -r '.data.rate_limit_exempt_paths | length')"
[[ "$GOT" == "${#EXEMPT[@]}" ]] \
    || die "wrote ${#EXEMPT[@]} exempt paths and read back ${GOT}.
       A single element usually means the list arrived comma-joined."

vault read -format=json sys/quotas/config 2>/dev/null \
    | jq -e '.data.rate_limit_exempt_paths | index("sys/health")' >/dev/null \
    || die "sys/health is not in the exempt list after writing it.
       Health checks would consume the quota, and a load balancer cannot
       tell a quota's 429 from a standby's."

log "Exempt paths verified, including sys/health and sys/quotas."
if [[ "$HEADERS" == true ]]; then
    log "Response headers on: a quota 429 carries retry-after and x-ratelimit-*."
else
    warn "Response headers off. A quota 429 is now indistinguishable from a"
    warn "standby's, and the load balancer matches both as healthy."
fi

# ---------------------------------------------------------------------------
# The quota itself
# ---------------------------------------------------------------------------

if [[ -z "$RATE" ]]; then
    log "No --rate given; configured exemptions and headers only."
    exit 0
fi

[[ "$RATE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--rate must be a number, got: ${RATE}"

ARGS=(rate="$RATE" interval="$INTERVAL")
[[ -n "$QPATH" ]] && ARGS+=(path="$QPATH")

log "Setting quota ${NAME}: ${RATE} per ${INTERVAL}${QPATH:+ on ${QPATH}}"
vault write "sys/quotas/rate-limit/${NAME}" "${ARGS[@]}" >/dev/null 2>&1 \
    || die "could not write the quota"

vault read -format=json "sys/quotas/rate-limit/${NAME}" 2>/dev/null \
    | jq -e --argjson r "$RATE" '.data.rate == $r' >/dev/null \
    || die "the quota did not read back with rate ${RATE}"

log "Quota ${NAME} is in force."
log ""
log "If it turns out to be too tight: send nothing for one interval, then"
log "  vault delete sys/quotas/rate-limit/${NAME}"
log "The first request of a new window succeeds; anything before it does not."
