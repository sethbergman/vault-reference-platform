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
#   --az-count <n>       AWS only. Check cost against this many availability
#                        zones (default: the profile's az_count). The Azure
#                        profile has no such variable and one NAT gateway
#                        regardless of zone spread, so it is ignored there.
#
# WHY THIS EXISTS
#
# An apply spends real money finding out what is wrong, and the failures
# that cost the most are the ones that happen twenty minutes in: a missing
# SSH key, an EIP quota that stops at two NAT gateways, a subscription
# that is not offered the VM size at all. terraform/aws has been applied
# twice, on 2026-09-17 and 2026-09-24, and this script's own first defect
# was among what the first of those found (docs/roadmap.md);
# terraform/azure never has.
#
# Preparing that Azure apply on 2026-09-25 found the next two, both the
# same shape: a check that cannot fail, and a heading with nothing under
# it. The "Quota that bites" section was AWS-only, so a subscription with
# 4 vCPUs for the region and the profile's default size marked
# NotAvailableForSubscription passed cleanly; and the role check looked
# the identity up by its sign-in name, which the directory does not hold
# for a guest account, so it warned identically whether the account was
# Owner or Contributor. tests/cloud-preflight/README.md has both in full.
#
# The Azure checks cost three API calls of about seven seconds. That is
# deliberate: `az vm list-skus` filters client-side, downloading every SKU
# in every region, and took 6m15s on a real subscription even with --size
# naming one.
#
# This checks what can be checked for free, and states plainly what an
# apply will cost and what a teardown will not remove.
#
# It does not apply anything. It runs `terraform plan`, which needs
# credentials and read access, and nothing else.
#
# WHICH VALUES IT CHECKS
#
# The ones `terraform` in this shell would use: a TF_VAR_<name> in the
# environment, else the default in variables.tf. Set inputs that way
# rather than with -var on the apply, so the pre-flight and the apply see
# the same thing:
#
#   export TF_VAR_az_count=2 TF_VAR_ssh_key_name=my-key
#
# It used to read defaults alone. The profile ships ssh_key_name empty and
# the documented apply passed the key with -var, so the check that exists
# to catch a missing key pair warned about an empty name on every correct
# run and never looked the key up. -var and .tfvars files are still not
# read; nothing here parses HCL.
#
# Run it twice. The plan needs an initialised backend, and the backend
# needs the bucket terraform/aws/bootstrap creates, so a first run before
# bootstrap checks everything except whether the profile plans. Run it
# again after `init`, before the apply.
#
# Requirements: terraform, and the CLI for the chosen cloud.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLOUD=""
TF_DIR=""
AZ_COUNT=""
# Whether --az-count was passed, as opposed to defaulted. After the fact the
# two are indistinguishable, and only the explicit case is worth warning about.
AZ_COUNT_GIVEN=false

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
        --az-count) AZ_COUNT="$2"; AZ_COUNT_GIVEN=true; shift 2 ;;
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

# tfvar <name> <fallback> — the value terraform would use from this shell:
# TF_VAR_<name> if it is set, even to empty, as Terraform treats it; else
# the profile's default.
tfvar() {
    local v env="TF_VAR_$1"
    if [[ -n "${!env+set}" ]]; then
        printf '%s' "${!env}"
        return 0
    fi
    v="$(grep -A6 "^variable \"$1\"" "${TF_DIR}/variables.tf" 2>/dev/null \
        | sed -n 's/^ *default *= *//p' | head -1 | tr -d '" ' || true)"
    printf '%s' "${v:-$2}"
}

# az_count is an AWS variable. terraform/azure has no such thing -- it has
# availability_zones, a list -- so reading it there resolved nothing and fell
# back to the literal 3, which then priced three NAT gateways for a profile
# that creates one. Resolve it only where it exists.
if [[ "$CLOUD" == "aws" ]]; then
    TF_AZ_COUNT="$(tfvar az_count 3)"
    [[ -n "$AZ_COUNT" ]] || AZ_COUNT="$TF_AZ_COUNT"
fi
NODE_COUNT="$(tfvar node_count 3)"
VM_SIZE="$(tfvar vm_size Standard_B2s)"
OS_DISK_GB="$(tfvar os_disk_size_gb 64)"

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

# The nodes have no public address and no inbound port 22, so Ansible
# reaches them by tunnelling SSH through SSM Session Manager -- see
# ansible/inventory/aws_ec2.yml. The AWS CLI does not implement that itself;
# it shells out to session-manager-plugin, and without it every
# connection fails naming the plugin rather than the thing you were
# doing, which is a slow way to learn this with the meter running.
#
# A warning rather than a failure: running the playbook from inside the
# VPC is a legitimate arrangement and needs none of this.
if [[ "$CLOUD" == "aws" ]]; then
    if command -v session-manager-plugin >/dev/null 2>&1; then
        ok "session-manager-plugin"
    else
        warn "session-manager-plugin is not on PATH"             "ansible-playbook cannot reach the nodes without it, unless you are running from inside the VPC"
    fi
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

    # The tunnel every Ansible connection goes through is an extension, not
    # core az. Missing, it fails after the apply has built everything --
    # and az's own answer is to install it mid-command, which cannot work
    # inside a ProxyCommand: no tty to confirm on, and parallel connections
    # racing to install the same thing.
    if [[ "$(az extension show --name bastion --query name -o tsv 2>/dev/null)" == "bastion" ]]; then
        ok "the az bastion extension is installed"
    else
        bad "the az bastion extension is missing" \
            "run: az extension add --name bastion — ansible/inventory/azure_rm.yml reaches every node through 'az network bastion tunnel', which lives in it"
    fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== Inputs this profile needs ==="
# ---------------------------------------------------------------------------
if [[ "$CLOUD" == "aws" ]]; then
    # --az-count prices and quota-checks a zone count; the plan below, and
    # the apply after it, use whatever terraform sees. When those differ
    # the cost and EIP lines describe a cluster nobody is about to build.
    if [[ "$AZ_COUNT_GIVEN" == true && "$AZ_COUNT" != "$TF_AZ_COUNT" ]]; then
        warn "--az-count ${AZ_COUNT} checks a cluster terraform will not build" \
            "terraform in this shell sees az_count=${TF_AZ_COUNT}; export TF_VAR_az_count=${AZ_COUNT} so the plan and the apply match"
    fi

    # An empty ssh_key_name applies fine and produces instances nobody can
    # reach. Since the whole point of the exercise is to get onto a node
    # and check things, that is worth catching before the apply.
    SSH_KEY="$(tfvar ssh_key_name "")"
    if [[ -z "$SSH_KEY" ]]; then
        warn "ssh_key_name is empty" \
            "the apply will succeed and you will not be able to log in to verify anything; export TF_VAR_ssh_key_name=<key pair>"
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
        #
        # --assignee wants the name the directory holds, which is not the
        # name you sign in with. A guest identity signs in as
        # someone@outlook.com and the directory knows it as
        # someone_outlook.com#EXT#@tenant.onmicrosoft.com, so the lookup
        # fails outright:
        #
        #   ERROR: Cannot find user or service principal in graph database
        #
        # That went to /dev/null, `|| true` turned the failure into an
        # empty string, and the pre-flight warned it "could not confirm"
        # Owner on an account that held Owner twice at subscription scope.
        # The real defect was not the false warning: a Contributor-only
        # identity produced the identical one, so the check could not
        # distinguish the case it exists to catch from the case it exists
        # to pass. Resolve the object id and match on that, and keep the
        # three outcomes apart — could not check, checked and short,
        # checked and fine.
        AZ_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
        if [[ -z "$AZ_OID" ]]; then
            warn "could not resolve the signed-in identity's object id" \
                "so its roles were not checked; this profile creates a role assignment, which needs Owner or User Access Administrator"
        else
            AZ_ROLE_RC=0
            ROLES="$(az role assignment list --all --assignee-object-id "$AZ_OID" \
                --query '[].roleDefinitionName' -o tsv 2>/dev/null)" || AZ_ROLE_RC=$?
            if [[ "$AZ_ROLE_RC" != "0" ]]; then
                warn "could not read the signed-in identity's role assignments" \
                    "so whether it can create one was not checked; this profile needs Owner or User Access Administrator"
            elif grep -qiE 'Owner|User Access Administrator' <<< "${ROLES:-}"; then
                ok "the signed-in identity can create role assignments"
            else
                bad "the signed-in identity has neither Owner nor User Access Administrator" \
                    "this profile creates a role assignment; Contributor alone applies most of it and then fails"
            fi
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
                "raise the limit, release unused EIPs, or apply with --az-count 2"
        else
            ok "Elastic IP headroom looks sufficient"
        fi
    fi
fi


if [[ "$CLOUD" == "azure" ]] && command -v az >/dev/null 2>&1; then
    # Every check in this block is a failure a real subscription produced
    # on 2026-09-25, and every one of them would have happened after the
    # VNet, NAT gateway, load balancer and Bastion were billing. Until
    # then this heading printed nothing at all on Azure: the section above
    # is guarded `if [[ "$CLOUD" == "aws" ]]`, so a subscription that
    # could not run the profile at any size got a clean pre-flight and a
    # scale set that failed twenty minutes in.
    #
    # A fresh subscription is the hostile case, not the exotic one. That
    # one had 4 vCPUs for the whole region against a profile wanting 6,
    # two families capped at 0 while the regional total looked roomy, and
    # the B-series the profile defaults to marked
    # NotAvailableForSubscription across entire regions.
    #
    # `az rest` rather than `az vm list-skus`, which filters client-side:
    # it downloads every SKU in every region and took 6m15s here, even
    # with --size naming one. The API takes a $filter and answers one
    # region in seven seconds.
    LOCATION="$(tfvar location eastus)"
    AZ_SUB_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
    SKU_URL="https://management.azure.com/subscriptions/${AZ_SUB_ID}/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location%20eq%20'${LOCATION}'"
    SKU_SEL="value[?resourceType=='virtualMachines' && name=='${VM_SIZE}']"

    # Only the *last* field of a multiselect may be variable-length. `-o
    # tsv` renders one line per field and prints nothing for an empty
    # array, so a middle field that happens to be empty shifts every line
    # after it — and the check then reads the wrong line and still says ok.
    SKU_FACTS="$(az rest --method get --url "$SKU_URL" \
        --query "${SKU_SEL} | [0].[family, restrictions[].join(':', [type, reasonCode])]" \
        -o tsv 2>/dev/null || true)"
    VM_FAMILY="$(sed -n 1p <<< "$SKU_FACTS")"
    SKU_RESTRICTIONS="$(sed -n 2p <<< "$SKU_FACTS")"

    if [[ -z "$VM_FAMILY" ]]; then
        bad "this subscription is not offered ${VM_SIZE} in ${LOCATION}" \
            "the apply fails creating the scale set; export TF_VAR_vm_size and TF_VAR_location, and note the profile defaults to Standard_B2s in eastus"
    else
        if [[ -n "$SKU_RESTRICTIONS" ]]; then
            bad "${VM_SIZE} is restricted in ${LOCATION}: ${SKU_RESTRICTIONS//$'\t'/, }" \
                "NotAvailableForSubscription means this subscription rather than the region, and a Location restriction rules out every zone in it — a quota increase does not lift it, another size or another region does"
        else
            ok "${VM_SIZE} is offered to this subscription in ${LOCATION}"
        fi

        # Zones are their own array, so they come back one per line rather
        # than tab-separated. The profile pins availability_zones to three
        # and sets zone_balance, which fails on a size the region offers
        # in fewer.
        SKU_ZONES="$(az rest --method get --url "$SKU_URL" \
            --query "${SKU_SEL} | [0].locationInfo[0].zones" -o tsv 2>/dev/null || true)"
        ZONE_COUNT="$(grep -c . <<< "$SKU_ZONES" || true)"
        if [[ "$ZONE_COUNT" -ge 3 ]]; then
            ok "${VM_SIZE} is offered in ${ZONE_COUNT} availability zones in ${LOCATION}"
        elif [[ "$ZONE_COUNT" -eq 0 ]]; then
            bad "${VM_SIZE} is offered in no availability zone in ${LOCATION}" \
                "availability_zones and zone_balance both fail; pick a region that offers this size zonally"
        else
            warn "${VM_SIZE} is offered in only ${ZONE_COUNT} zone(s) in ${LOCATION}" \
                "the profile pins availability_zones to three; set TF_VAR_availability_zones to the ones that exist or zone_balance will fail"
        fi

        # Self-labelling name/value lines, so nothing here depends on
        # field order or on a capability being present.
        SKU_CAPS="$(az rest --method get --url "$SKU_URL" \
            --query "${SKU_SEL} | [0].capabilities[].[name,value]" -o tsv 2>/dev/null || true)"
        SKU_VCPUS="$(grep -m1 -- $'^vCPUs\t' <<< "$SKU_CAPS" | cut -f2 || true)"
        SKU_PREMIUM="$(grep -m1 -- $'^PremiumIO\t' <<< "$SKU_CAPS" | cut -f2 || true)"

        # os_disk.storage_account_type is Premium_LRS, which a size
        # without premium storage support cannot attach.
        if [[ "$SKU_PREMIUM" == "False" ]]; then
            bad "${VM_SIZE} does not support premium storage" \
                "terraform/azure/compute.tf sets os_disk.storage_account_type = Premium_LRS; the scale set is refused at creation"
        fi

        if [[ -z "$SKU_VCPUS" ]]; then
            warn "could not read the vCPU count for ${VM_SIZE}" \
                "so quota was not checked against it"
        else
            NEED_VCPUS=$((NODE_COUNT * SKU_VCPUS))
            info "        ${NODE_COUNT} × ${VM_SIZE} needs ${NEED_VCPUS} vCPUs in ${LOCATION}"

            # Two ceilings, and the regional one is the famous one. A
            # family capped at 0 with regional headroom to spare is what
            # makes the second worth checking separately: the numbers
            # agree there is room and the apply still cannot have any.
            VM_USAGE="$(az vm list-usage --location "$LOCATION" \
                --query "[].[name.value,currentValue,limit]" -o tsv 2>/dev/null || true)"

            # check_vcpu_quota <row> <label> <hint>
            check_vcpu_quota() {
                local row="$1" label="$2" hint="$3" used limit free
                if [[ -z "$row" ]]; then
                    warn "could not read ${label}" "so it was not checked against ${NEED_VCPUS} vCPUs"
                    return 0
                fi
                used="$(cut -f2 <<< "$row")"
                limit="$(cut -f3 <<< "$row")"
                free=$((limit - used))
                if [[ "$free" -ge "$NEED_VCPUS" ]]; then
                    ok "${label}: ${used}/${limit} used, ${free} free"
                else
                    bad "${label}: ${used}/${limit} used, ${free} free — ${NEED_VCPUS} needed" "$hint"
                fi
            }

            check_vcpu_quota "$(grep -m1 -- $'^cores\t' <<< "$VM_USAGE" || true)" \
                "total regional vCPUs in ${LOCATION}" \
                "raise the quota, drop vm_size, or pick another region; node_count cannot go below 3 and stay a Raft majority"
            check_vcpu_quota "$(grep -im1 -- "^${VM_FAMILY}"$'\t' <<< "$VM_USAGE" || true)" \
                "${VM_FAMILY} vCPUs in ${LOCATION}" \
                "each family has a limit of its own, and a fresh subscription has several at 0 — regional headroom does not lift it"
        fi
    fi

    # One Standard public IP for the NAT gateway, one for the Bastion, and
    # a third only if the load balancer is internet-facing. Standard has a
    # quota separate from Basic and from the total.
    NEED_IPS=2
    [[ "$(tfvar internal_lb true)" == "false" ]] && NEED_IPS=3
    NET_USAGE="$(az network list-usages --location "$LOCATION" \
        --query "[].[name.value,currentValue,limit]" -o tsv 2>/dev/null || true)"
    IP_ROW="$(grep -im1 -- $'^IPv4StandardSkuPublicIpAddresses\t' <<< "$NET_USAGE" || true)"
    if [[ -z "$IP_ROW" ]]; then
        warn "could not read the Standard public IP quota in ${LOCATION}" \
            "so it was not checked against the ${NEED_IPS} this apply needs"
    else
        IP_USED="$(cut -f2 <<< "$IP_ROW")"
        IP_LIMIT="$(cut -f3 <<< "$IP_ROW")"
        IP_FREE=$((IP_LIMIT - IP_USED))
        if [[ "$IP_FREE" -ge "$NEED_IPS" ]]; then
            ok "Standard public IPs in ${LOCATION}: ${IP_USED}/${IP_LIMIT} used, ${IP_FREE} free, ${NEED_IPS} needed"
        else
            bad "Standard public IPs in ${LOCATION}: ${IP_USED}/${IP_LIMIT} used, ${IP_FREE} free — ${NEED_IPS} needed" \
                "the NAT gateway and the Bastion each take one; releasing an unused address is faster than a quota request"
        fi
    fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== What this will cost ==="
# ---------------------------------------------------------------------------
if [[ "$CLOUD" == "azure" && "$AZ_COUNT_GIVEN" == true ]]; then
    warn "--az-count has no effect on the Azure profile" \
        "one NAT gateway serves the whole VNet regardless of zone spread"
fi
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
    # Two, not one. terraform/aws/variables.tf validates az_count between
    # 2 and 4, so suggesting 1 recommended an apply that fails before it
    # creates anything -- which this script said for several releases.
    if [[ "$AZ_COUNT" -gt 2 ]]; then
        info "        --az-count 2 removes \$$(( (AZ_COUNT - 2) * 33 ))/month of that."
        info "        Two is the floor the profile allows: a cluster that cannot"
        info "        survive losing a zone is not what this is describing."
    fi
else
    # One NAT gateway, not one per zone. terraform/azure/network.tf declares
    # a single azurerm_nat_gateway with no count, for the whole VNet. This
    # used to multiply by az_count -- a variable the profile does not
    # define -- and so quoted three of them and called the result the
    # largest line, which pointed the reader's cost-cutting at the one line
    # they cannot cut.
    AZ_NAT_MONTH=33
    AZ_VM_MONTH=$((NODE_COUNT * 30))
    # Premium_LRS at the default 64 GB is a P6 per node, and the previous
    # estimate omitted disks entirely.
    AZ_DISK_MONTH=$((NODE_COUNT * 9))
    # Azure Bastion, Standard: about $0.19/hour for the host, so ~$140 a
    # month if left up. bastion_enabled defaults to true because without it
    # nothing can reach a node, which makes this the largest line in the
    # profile rather than a footnote -- and the one most worth destroying
    # promptly.
    AZ_BASTION_MONTH=140
    [[ "${BASTION_ENABLED:-true}" == "false" ]] && AZ_BASTION_MONTH=0
    AZ_TOTAL=$((AZ_NAT_MONTH + AZ_VM_MONTH + AZ_DISK_MONTH + AZ_BASTION_MONTH + 20))
    if [[ "$AZ_BASTION_MONTH" != "0" ]]; then
        info "        1 Azure Bastion (Standard) ~\$${AZ_BASTION_MONTH}/month  <-- the largest line"
    else
        info "        Azure Bastion             disabled (bastion_enabled = false)"
        info "        NOTE: nothing can reach the nodes without another route into the VNet."
    fi
    info "        1 NAT gateway             ~\$${AZ_NAT_MONTH}/month"
    info "        ${NODE_COUNT} VM(s) (${VM_SIZE})  ~\$${AZ_VM_MONTH}/month"
    info "        ${NODE_COUNT} OS disk(s) (${OS_DISK_GB}GB Premium) ~\$${AZ_DISK_MONTH}/month"
    info "        1 standard load balancer  ~\$18/month"
    info "        Key Vault, storage, flow logs  a few dollars"
    info "        ------------------------------------"
    info "        roughly \$${AZ_TOTAL}/month"
    info ""
    # The AWS branch has a lever worth pulling; this one has to say that the
    # obvious lever does nothing, or a reader will reach for it by analogy.
    info "        Zone spread is free here: the NAT gateway is regional, so"
    info "        fewer zones save nothing. node_count cannot go below 3 and"
    info "        stay a Raft majority, which leaves vm_size,"
    info "        os_disk_size_gb, and destroying the Bastion with the"
    info "        cluster rather than leaving it up between sessions."
    if [[ "$VM_SIZE" != "Standard_B2s" ]]; then
        info ""
        info "        NOTE: the per-VM figure assumes the default Standard_B2s."
        info "        This profile is set to ${VM_SIZE}, so treat the compute"
        info "        line as a placeholder rather than an estimate."
    fi
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
info "=== Where does the state go? ==="
# ---------------------------------------------------------------------------
# Worth answering before the apply rather than after. Applying with local
# state produces a running Vault cluster whose only record of itself is a
# file on this machine — recoverable by importing every resource by hand,
# and not at all if the machine is a CI runner that is about to be
# destroyed.
if [[ -f "${TF_DIR}/backend.hcl" ]]; then
    ok "backend.hcl is present, so state has somewhere to go"
    if [[ -d "${TF_DIR}/.terraform" ]] && grep -q '"backend"' "${TF_DIR}/.terraform/terraform.tfstate" 2>/dev/null; then
        ok "the backend is initialised"
    else
        warn "backend.hcl exists but the backend is not initialised" \
            "run: terraform -chdir=${TF_DIR} init -backend-config=backend.hcl"
    fi
    if [[ -f "${TF_DIR}/terraform.tfstate" ]]; then
        warn "a local terraform.tfstate is also present in ${TF_DIR}" \
            "left over from a local-state apply; migrate it before applying again, or it is ignored and the cluster gets built twice"
    fi
else
    warn "no backend.hcl in ${TF_DIR} — this apply would use local state" \
        "apply terraform/${CLOUD}/bootstrap first; see docs/terraform-state.md"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Does it plan? ==="
# ---------------------------------------------------------------------------
if command -v terraform >/dev/null 2>&1; then
    if ! tf providers >/dev/null 2>&1; then
        # A warning, but the one that most needs reading: everything above
        # passing says nothing about whether the profile plans, and a
        # reader skimming for FAIL will take this run as the whole check.
        warn "terraform is not initialised in ${TF_DIR}, so whether it plans was not checked" \
            "initialise it (after the bootstrap module, for the backend), then run this pre-flight again"
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
