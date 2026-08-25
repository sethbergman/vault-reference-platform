#!/usr/bin/env bash
#
# preflight-cloud.sh — Check a cloud profile is ready to apply, before
#                      spending money finding out it is not
#
# Usage:
#   ./preflight-cloud.sh --cloud aws|azure [options]
#
# Options:
#   --cloud <aws|azure>  Required.
#   --dir <path>         Terraform directory (default: terraform/<cloud>)
#   --az-count <n>       Check cost against this many availability zones
#                        (default: read from the profile's variable)
#
# WHY THIS EXISTS
#
# Neither cloud profile in this repository has ever been applied. The
# first person to try will be spending real money to find out what is
# wrong, and the failures that cost the most are the ones that happen
# twenty minutes in: a missing SSH key, an EIP quota that stops at two
# NAT gateways, a subscription without the permissions to create a role
# assignment.
#
# This checks what can be checked for free, and states plainly what an
# apply will cost and what a teardown will not remove.
#
# It does not apply anything. It runs `terraform plan`, which needs
# credentials and read access, and nothing else.
#
# Requirements: terraform, and the CLI for the chosen cloud.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLOUD=""
TF_DIR=""
AZ_COUNT=""

PASS=0
WARN=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m%s\033[0m\n' "$*"; }

ok()   { PASS=$((PASS + 1)); green "  ok    $1"; }
warn() { WARN=$((WARN + 1)); amber "  warn  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }
bad()  { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

die() { red "ERROR: $*"; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cloud)    CLOUD="$2"; shift 2 ;;
        --dir)      TF_DIR="$2"; shift 2 ;;
        --az-count) AZ_COUNT="$2"; shift 2 ;;
        -h|--help)  usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLOUD" ]] || die "--cloud is required (aws or azure)"
case "$CLOUD" in
    aws|azure) ;;
    *) die "--cloud must be aws or azure, got: ${CLOUD}" ;;
esac

[[ -n "$TF_DIR" ]] || TF_DIR="${REPO_ROOT}/terraform/${CLOUD}"
[[ -d "$TF_DIR" ]] || die "No Terraform directory at ${TF_DIR}"

tf() { terraform -chdir="$TF_DIR" "$@"; }

# tfvar <name> <fallback> — the profile's default for a variable.
tfvar() {
    local v
    v="$(grep -A6 "^variable \"$1\"" "${TF_DIR}/variables.tf" 2>/dev/null \
        | sed -n 's/^ *default *= *//p' | head -1 | tr -d '" ' || true)"
    printf '%s' "${v:-$2}"
}

[[ -n "$AZ_COUNT" ]] || AZ_COUNT="$(tfvar az_count 3)"
NODE_COUNT="$(tfvar node_count 3)"

# ---------------------------------------------------------------------------
info ""
info "=== Tooling ==="
# ---------------------------------------------------------------------------
if command -v terraform >/dev/null 2>&1; then
    ok "terraform ($(terraform version 2>/dev/null | head -1))"
else
    bad "terraform is not on PATH" "nothing else here can run without it"
fi

CLI="aws"; [[ "$CLOUD" == "azure" ]] && CLI="az"
if command -v "$CLI" >/dev/null 2>&1; then
    ok "${CLI} CLI"
else
    bad "${CLI} CLI is not on PATH" "needed to check identity and quota, and by teardown-cloud.sh"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Credentials ==="
# ---------------------------------------------------------------------------
# Resolving an identity is the cheapest way to find out the credentials
# work. It is also the only way to find out *which* account you are about
# to spend money in, which is worth printing rather than assuming.
if [[ "$CLOUD" == "aws" ]] && command -v aws >/dev/null 2>&1; then
    IDENT="$(aws sts get-caller-identity --output json 2>/dev/null || true)"
    if [[ -n "$IDENT" ]]; then
        ACCT="$(sed -n 's/.*"Account": *"\([^"]*\)".*/\1/p' <<< "$IDENT" | head -1)"
        ARN="$(sed -n 's/.*"Arn": *"\([^"]*\)".*/\1/p' <<< "$IDENT" | head -1)"
        ok "authenticated as ${ARN}"
        info "        account: ${ACCT} — check this is the one you meant"
    else
        bad "could not resolve an AWS identity" "aws sts get-caller-identity failed"
    fi
elif [[ "$CLOUD" == "azure" ]] && command -v az >/dev/null 2>&1; then
    SUB="$(az account show --query '{name:name,id:id}' -o json 2>/dev/null || true)"
    if [[ -n "$SUB" ]]; then
        ok "authenticated to Azure"
        info "        subscription: $(tr -d '\n' <<< "$SUB")"
    else
        bad "could not resolve an Azure subscription" "run: az login"
    fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== Inputs this profile needs ==="
# ---------------------------------------------------------------------------
if [[ "$CLOUD" == "aws" ]]; then
    # An empty ssh_key_name applies fine and produces instances nobody can
    # reach. Since the whole point of the exercise is to get onto a node
    # and check things, that is worth catching before the apply.
    SSH_KEY="$(tfvar ssh_key_name "")"
    if [[ -z "$SSH_KEY" ]]; then
        warn "ssh_key_name is empty" \
            "the apply will succeed and you will not be able to log in to verify anything"
    else
        ok "ssh_key_name is set (${SSH_KEY})"
        if command -v aws >/dev/null 2>&1; then
            if aws ec2 describe-key-pairs --key-names "$SSH_KEY" >/dev/null 2>&1; then
                ok "and that key pair exists in this account"
            else
                bad "the key pair '${SSH_KEY}' does not exist in this account/region" \
                    "the apply fails at instance launch, after the VPC and NAT gateways are billing"
            fi
        fi
    fi
else
    if command -v az >/dev/null 2>&1; then
        # A role assignment needs Owner or User Access Administrator.
        # Contributor is enough for everything else, which is why this
        # fails late and confusingly.
        ROLES="$(az role assignment list --assignee "$(az account show --query user.name -o tsv 2>/dev/null)" \
            --query '[].roleDefinitionName' -o tsv 2>/dev/null || true)"
        if grep -qiE 'Owner|User Access Administrator' <<< "${ROLES:-}"; then
            ok "the signed-in identity can create role assignments"
        else
            warn "could not confirm Owner or User Access Administrator" \
                "this profile creates role assignments; Contributor alone applies most of it and then fails"
        fi
    fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== Quota that bites ==="
# ---------------------------------------------------------------------------
if [[ "$CLOUD" == "aws" ]] && command -v aws >/dev/null 2>&1; then
    # One Elastic IP per NAT gateway, one NAT gateway per AZ. The default
    # account limit is 5 EIPs, and anything already using them counts.
    EIP_USED="$(aws ec2 describe-addresses --query 'length(Addresses)' --output text 2>/dev/null || echo "?")"
    if [[ "$EIP_USED" == "?" ]]; then
        warn "could not read Elastic IP usage" "check manually if the apply fails allocating one"
    else
        info "        Elastic IPs in use: ${EIP_USED}; this apply needs ${AZ_COUNT} more"
        if [[ "$((EIP_USED + AZ_COUNT))" -gt 5 ]]; then
            warn "that may exceed the default limit of 5" \
                "raise the limit, release unused EIPs, or apply with --az-count 1"
        else
            ok "Elastic IP headroom looks sufficient"
        fi
    fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== What this will cost ==="
# ---------------------------------------------------------------------------
# Rough, on-demand, us-east-1-ish. The point is not precision — it is
# that the dominant line item is not the thing people expect.
if [[ "$CLOUD" == "aws" ]]; then
    NAT_MONTH=$((AZ_COUNT * 33))
    NODE_MONTH=$((NODE_COUNT * 15))
    info "        ${AZ_COUNT} NAT gateway(s)      ~\$${NAT_MONTH}/month   <-- usually the largest line"
    info "        ${NODE_COUNT} t3.small instance(s) ~\$${NODE_MONTH}/month"
    info "        1 network load balancer  ~\$16/month"
    info "        1 KMS key                 ~\$1/month"
    info "        EBS, S3, flow logs        a few dollars"
    TOTAL=$((NAT_MONTH + NODE_MONTH + 17))
    # Cents per hour, printed as dollars. Integer arithmetic throughout:
    # this is a comparison aid, and a fake decimal point would suggest a
    # precision these numbers do not have.
    CENTS_HR=$(( (TOTAL * 100) / 730 ))
    info "        ------------------------------------"
    info "        roughly \$${TOTAL}/month — about \$0.$(printf '%02d' $((CENTS_HR % 100)))/hour if under a dollar,"
    info "        i.e. a few dollars for an afternoon of testing"
    info ""
    if [[ "$AZ_COUNT" -gt 1 ]]; then
        info "        --az-count 1 removes \$$(( (AZ_COUNT - 1) * 33 ))/month of that."
        info "        It also removes the AZ independence the default is for, so"
        info "        it is a fine choice for a few hours and a bad one to keep."
    fi
else
    # Arithmetic, not string concatenation. The first draft of this
    # printed "$32/month" by gluing az_count onto a literal 2, which is
    # right for three zones and nonsense for any other number.
    AZ_NAT_MONTH=$((AZ_COUNT * 32))
    AZ_VM_MONTH=$((NODE_COUNT * 30))
    AZ_TOTAL=$((AZ_NAT_MONTH + AZ_VM_MONTH + 20))
    info "        ${AZ_COUNT} NAT gateway(s)      ~\$${AZ_NAT_MONTH}/month   <-- usually the largest line"
    info "        ${NODE_COUNT} VM(s) (B2s-ish)     ~\$${AZ_VM_MONTH}/month"
    info "        1 standard load balancer  ~\$18/month"
    info "        Key Vault, storage        a few dollars"
    info "        ------------------------------------"
    info "        roughly \$${AZ_TOTAL}/month"
fi

info ""
info "        These are estimates for comparison, not a quote. Costs are"
info "        hourly — an apply left running over a weekend is the real risk,"
info "        not the apply itself."

# ---------------------------------------------------------------------------
info ""
info "=== What a teardown will not remove ==="
# ---------------------------------------------------------------------------
if [[ "$CLOUD" == "aws" ]]; then
    warn "the snapshot bucket blocks terraform destroy once it holds anything" \
        "versioning is on and force_destroy is not set; use scripts/teardown-cloud.sh"
    info "        the KMS key enters a 7-day deletion window rather than being deleted"
else
    warn "the Key Vault cannot be purged for 90 days" \
        "purge_protection_enabled is on and cannot be turned off — each apply leaves a soft-deleted vault behind"
    info "        the name carries a random suffix, so re-applying still works"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Does it plan? ==="
# ---------------------------------------------------------------------------
if command -v terraform >/dev/null 2>&1; then
    if ! tf providers >/dev/null 2>&1; then
        warn "terraform is not initialised in ${TF_DIR}" "run: terraform -chdir=${TF_DIR} init"
    else
        info "        running terraform plan (no changes are made)..."
        if tf plan -no-color -input=false >/dev/null 2>&1; then
            ok "the profile plans cleanly against this account"
        else
            bad "terraform plan failed" \
                "run it directly to see why: terraform -chdir=${TF_DIR} plan"
        fi
    fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== Result ==="
# ---------------------------------------------------------------------------
printf 'ok: %d   warnings: %d   failures: %d\n' "$PASS" "$WARN" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    red "Not ready. Fix the failures above before applying."
    exit 1
fi
if [[ "$WARN" -gt 0 ]]; then
    amber "Ready, with warnings. Read them — most describe something that"
    amber "costs money or cannot be undone."
    exit 0
fi
green "Ready. See docs/cloud-apply.md for what to verify while it is up."
