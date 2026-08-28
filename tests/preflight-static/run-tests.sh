#!/usr/bin/env bash
#
# run-tests.sh — Everything about a cloud apply that can be settled
#                without performing one
#
# Usage:
#   ./tests/preflight-static/run-tests.sh
#
# Runs in seconds. No credentials, no cloud calls, nothing created.
#
# WHY THIS EXISTS
#
# scripts/preflight-cloud.sh checks what can be checked *with* credentials
# before spending. This checks what can be checked without them, and it is
# aimed at a different class of defect entirely.
#
# `terraform validate` sees one file at a time. `terraform test` with
# mocked providers sees the configuration's shape. Neither can see across
# the seam between Terraform, the cloud-init it renders, and the Ansible
# layer that finishes the node — and that seam is where every cloud bug
# this repository has produced actually lived:
#
#   - Azure's auto_join mixed tag and scale-set selectors, which
#     go-discover rejects outright. Terraform rendered it happily.
#   - The cloud templates asked for a leader_tls_servername that nothing
#     issued a certificate for, so no peer could ever have joined.
#
# Both are invisible to every other suite here, and both would otherwise
# have cost a real apply to discover.
#
# THE FAILURE SHAPE THEY SHARE
#
# Each is a string produced by one layer and consumed by another, where
# the consumer is strict and the producer has no idea. Nothing validates
# it in between, so it renders, applies, boots, and then a distributed
# system quietly fails to become one: every node healthy, alone.
#
# Requirements: bash, python3, shellcheck (shellcheck is skipped if absent)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

ok()  { PASS=$((PASS + 1)); green "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); red   "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

command -v python3 >/dev/null 2>&1 || { red "ERROR: python3 not found"; exit 1; }

AWS_TPL="${REPO_ROOT}/terraform/aws/templates/user-data.sh.tftpl"
AZ_TPL="${REPO_ROOT}/terraform/azure/templates/cloud-init.sh.tftpl"
PKI_DEFAULTS="${REPO_ROOT}/ansible/roles/vault_pki/defaults/main.yml"
VAULT_DEFAULTS="${REPO_ROOT}/ansible/roles/vault/defaults/main.yml"

for f in "$AWS_TPL" "$AZ_TPL" "$PKI_DEFAULTS" "$VAULT_DEFAULTS"; do
    [[ -f "$f" ]] || { red "ERROR: missing ${f}"; exit 1; }
done

# ---------------------------------------------------------------------------
printf '\n=== Terraform passes exactly what the templates ask for ===\n'
# ---------------------------------------------------------------------------
# A template reading a value templatefile() does not supply fails at plan
# time, which is survivable. The reverse — passing a value nothing reads —
# is silent, and usually means a rename landed on one side only.
VAR_OUT="$(python3 - "$REPO_ROOT" <<'PY'
import re, sys, os, glob
root = sys.argv[1]
problems = []
for cloud, tpl in (("aws", "terraform/aws/templates/user-data.sh.tftpl"),
                   ("azure", "terraform/azure/templates/cloud-init.sh.tftpl")):
    text = open(os.path.join(root, tpl), encoding="utf-8").read()
    # ${x} interpolates; $${x} is an escaped literal and is not a variable.
    referenced = set(re.findall(r'(?<!\$)\$\{([a-z_][a-z0-9_]*)\}', text))

    supplied = set()
    for tf in glob.glob(os.path.join(root, "terraform", cloud, "*.tf")):
        src = open(tf, encoding="utf-8").read()
        m = re.search(r'templatefile\(\s*"[^"]*'
                      + re.escape(os.path.basename(tpl))
                      + r'"\s*,\s*\{(.*?)\n\s*\}\)', src, re.S)
        if m:
            supplied |= set(re.findall(r'^\s*([a-z_][a-z0-9_]*)\s*=', m.group(1), re.M))

    for name in sorted(referenced - supplied):
        problems.append(f"{cloud}: template reads ${{{name}}} but Terraform does not pass it")
    for name in sorted(supplied - referenced):
        problems.append(f"{cloud}: Terraform passes {name} but the template never reads it")
    print(f"COUNT {cloud} {len(referenced)}")
for p in problems:
    print("PROBLEM " + p)
PY
)"

while read -r _ cloud n; do
    [[ -n "${cloud:-}" ]] || continue
    if [[ "$n" -ge 3 ]]; then
        ok "${cloud}: the template reads ${n} Terraform values"
    else
        bad "${cloud}: template variables were found" "only ${n}; the pattern probably stopped matching"
    fi
done < <(grep '^COUNT ' <<< "$VAR_OUT")

VAR_PROBLEMS="$(grep '^PROBLEM ' <<< "$VAR_OUT" | sed 's/^PROBLEM //')"
if [[ -z "$VAR_PROBLEMS" ]]; then
    ok "every template variable is supplied, and every supplied value is read"
else
    while IFS= read -r line; do bad "template/Terraform variable mismatch" "$line"; done <<< "$VAR_PROBLEMS"
fi

# ---------------------------------------------------------------------------
printf '\n=== The rendered cloud-init is valid shell ===\n'
# ---------------------------------------------------------------------------
# These scripts boot every node and are linted nowhere else. The CI lint
# step covers scripts/ and the test harnesses; a .tftpl is neither. A bug
# here is a node that comes up without Vault — which on AWS the
# autoscaling group then replaces, and replaces, and replaces.
#
# (A comment line starting with the word shellcheck is read as a
# directive rather than as prose, which is how this file first failed the
# very lint job it was written to extend.)
#
# sed rather than a here-doc'd interpreter: nesting one language's quoting
# inside another's broke this function twice while it was being written,
# and the substitution is plain text replacement.
#
# Terraform interpolations are lower case; shell variables the template
# escapes as $${VAR} are upper case. The two cannot collide, so the escape
# is collapsed last, once no ${lower} remains.
render() {
    sed -e 's|\${aws_region}|us-east-1|g' \
        -e 's|\${cluster_name}|vault-ref|g' \
        -e 's|\${vault_version}|1.17.2|g' \
        -e 's|\${kms_key_id}|1234abcd-12ab-34cd-56ef-1234567890ab|g' \
        -e 's|\${key_name}|vault-unseal|g' \
        -e 's|\${key_vault_name}|vaultref-abcd1234|g' \
        -e 's|\${resource_group}|vault-ref-rg|g' \
        -e 's|\${vm_scale_set}|vault-ref-vmss|g' \
        -e 's|\${subscription_id}|00000000-0000-0000-0000-000000000000|g' \
        -e 's|\${tenant_id}|11111111-1111-1111-1111-111111111111|g' \
        -e 's|\$\${|${|g' \
        "$1"
}

for pair in "aws:${AWS_TPL}" "azure:${AZ_TPL}"; do
    cloud="${pair%%:*}"
    tpl="${pair#*:}"
    out="${WORK}/${cloud}.sh"

    render "$tpl" > "$out"

    if [[ ! -s "$out" ]]; then
        bad "${cloud}: renders to something" "rendered nothing"
        continue
    fi
    ok "${cloud}: renders to $(wc -l < "$out") lines"

    # A surviving ${lower} means Terraform names a value the template does
    # not, or an escape is wrong.
    LEFTOVER="$(grep -oE '(^|[^$])\$\{[a-z_]+\}' "$out" | head -3 | tr '\n' ' ')"
    if [[ -z "$LEFTOVER" ]]; then
        ok "${cloud}: no interpolation left behind"
    else
        bad "${cloud}: no interpolation left behind" "$LEFTOVER"
    fi

    if bash -n "$out" 2>"${WORK}/${cloud}.syntax"; then
        ok "${cloud}: the rendered script parses"
    else
        bad "${cloud}: the rendered script parses" "$(head -3 "${WORK}/${cloud}.syntax")"
    fi

    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck -s bash -S warning "$out" >"${WORK}/${cloud}.sc" 2>&1; then
            ok "${cloud}: shellcheck is clean at warning level"
        else
            bad "${cloud}: shellcheck is clean at warning level" "$(head -12 "${WORK}/${cloud}.sc")"
        fi
    else
        printf '  SKIP  %s: shellcheck not installed\n' "$cloud"
    fi
done

# ---------------------------------------------------------------------------
printf '\n=== auto_join says something go-discover accepts ===\n'
# ---------------------------------------------------------------------------
# go-discover rejects an unclear configuration rather than guessing, and
# the rejection surfaces as one line in one node's log while the cluster
# silently never forms.
#
# The accepted keys are recorded from the provider sources rather than
# from memory, which is how the Azure bug was found in the first place:
#
#   aws    provider/aws/aws_discover.go
#   azure  provider/azure/azure_discover.go
AWS_KEYS=" provider region tag_key tag_value addr_type access_key_id secret_access_key session_token service ecs_cluster ecs_family endpoint "
AZ_KEYS=" provider tenant_id client_id secret_access_key subscription_id tag_name tag_value resource_group vm_scale_set environment "

check_join() {
    local cloud="$1" out="${WORK}/$1.sh" allowed raw keys k
    [[ -s "$out" ]] || { bad "${cloud}: has an auto_join to check" "nothing rendered"; return; }

    case "$cloud" in
        aws)   allowed="$AWS_KEYS" ;;
        azure) allowed="$AZ_KEYS" ;;
    esac

    raw="$(grep -oE 'auto_join[[:space:]]*=[[:space:]]*"[^"]+"' "$out" | head -1 | sed 's/.*"\(.*\)"/\1/')"
    if [[ -z "$raw" ]]; then
        bad "${cloud}: declares an auto_join string" "none found in the rendered config"
        return
    fi
    ok "${cloud}: declares an auto_join string"

    keys="$(tr ' ' '\n' <<< "$raw" | grep '=' | cut -d= -f1)"

    local unknown=""
    while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        [[ "$allowed" == *" ${k} "* ]] || unknown="${unknown}${k} "
    done <<< "$keys"

    if [[ -z "$unknown" ]]; then
        ok "${cloud}: every auto_join key is one the provider accepts"
    else
        bad "${cloud}: every auto_join key is one the provider accepts" \
            "go-discover does not read: ${unknown}"
    fi

    if [[ "$cloud" == "azure" ]]; then
        local tagmode=0 ssmode=0
        [[ "$keys" == *tag_name* ]] && tagmode=1
        [[ "$keys" == *resource_group* || "$keys" == *vm_scale_set* ]] && ssmode=1
        if (( tagmode && ssmode )); then
            bad "azure: selects by one mechanism, not two" \
                "mixing tag and scale-set selectors is rejected as an unclear configuration"
        elif (( tagmode || ssmode )); then
            ok "azure: selects by one mechanism, not two"
        else
            bad "azure: selects by one mechanism, not two" "it selects nothing"
        fi
    fi

    if [[ "$cloud" == "aws" ]]; then
        if [[ "$keys" == *tag_key* && "$keys" == *tag_value* ]]; then
            ok "aws: filters on both tag_key and tag_value"
        else
            bad "aws: filters on both tag_key and tag_value" "one of them is missing"
        fi
    fi
}

check_join aws
check_join azure

# The tag auto_join filters on must be a tag Terraform actually sets, or
# discovery matches nothing. AWS only: Azure discovers by scale set.
AWS_TAG="$(grep -oE 'tag_key=[A-Za-z]+' "${WORK}/aws.sh" | head -1 | cut -d= -f2)"
if [[ -n "$AWS_TAG" ]] && grep -q "${AWS_TAG} *=" "${REPO_ROOT}/terraform/aws/compute.tf"; then
    ok "aws: the tag auto_join filters on (${AWS_TAG}) is one compute.tf sets"
else
    bad "aws: the tag auto_join filters on is one compute.tf sets" \
        "nothing in compute.tf sets '${AWS_TAG:-<none>}'"
fi

# ---------------------------------------------------------------------------
printf '\n=== The leader can actually be verified ===\n'
# ---------------------------------------------------------------------------
# retry_join's leader_tls_servername is the ONE name a follower verifies
# the leader against, whichever node that happens to be — so every node's
# certificate has to carry it.
#
# It did not. The templates asked for vault.<cluster>.internal while the
# PKI role issued <host>.vault.internal with SANs <host>,localhost, so no
# certificate anywhere bore the name. Every join would have failed TLS and
# the cluster would never have formed, while each node reported healthy on
# its own. These assertions are why that cannot recur quietly.
SERVERNAME_TPL="$(grep -hoE 'leader_tls_servername[^"]*"[^"]+"' "$AWS_TPL" "$AZ_TPL" \
    | grep -oE '"[^"]+"$' | tr -d '"' | sort -u)"

if [[ -n "$SERVERNAME_TPL" && "$(wc -l <<< "$SERVERNAME_TPL")" == "1" ]]; then
    ok "both profiles verify the leader against the same name"
else
    bad "both profiles verify the leader against the same name" \
        "found: $(tr '\n' ' ' <<< "$SERVERNAME_TPL")"
fi

# One side interpolates with shell, the other with Jinja. Compare the
# shape, so the assertion is about agreement rather than templating style.
tpl_shape="$(sed -E 's/[$]+\{?[A-Za-z_]+\}?/CLUSTER/g' <<< "$SERVERNAME_TPL")"
ALT_NAMES="$(grep -E '^vault_pki_alt_names:' "$PKI_DEFAULTS" | cut -d: -f2- | tr -d '"' | xargs || true)"
CLUSTER_SN="$(grep -E '^vault_pki_cluster_servername:' "$PKI_DEFAULTS" | cut -d: -f2- | tr -d '"' | xargs || true)"
role_shape="$(sed -E 's/\{\{[^}]*\}\}/CLUSTER/g' <<< "$CLUSTER_SN")"

if [[ "$tpl_shape" == "vault.CLUSTER.internal" ]]; then
    ok "the templates verify against vault.<cluster>.internal"
else
    bad "the templates verify against vault.<cluster>.internal" "got '${tpl_shape}'"
fi

if [[ "$ALT_NAMES" == *vault_pki_cluster_servername* ]]; then
    ok "the PKI role puts that name in every certificate's SANs"
else
    bad "the PKI role puts that name in every certificate's SANs" \
        "alt_names is '${ALT_NAMES}' — a follower cannot verify a leader against a name nobody issues"
fi

if [[ -n "$role_shape" && "$role_shape" == "$tpl_shape" ]]; then
    ok "and the two names are the same"
else
    bad "and the two names are the same" \
        "role issues '${role_shape:-<unset>}', templates want '${tpl_shape}'"
fi

# The CA a follower verifies against has to be where the config looks for
# it. Ansible writes that path through a variable, so resolve it rather
# than grepping for a literal.
CA_TPL="$(grep -hoE 'leader_ca_cert_file[^"]*"[^"]+"' "$AWS_TPL" "$AZ_TPL" \
    | grep -oE '"[^"]+"$' | tr -d '"' | sort -u)"
TLS_DIR="$(grep -E '^vault_tls_dir:' "$VAULT_DEFAULTS" | cut -d: -f2- | xargs || true)"

if [[ -n "$TLS_DIR" ]]; then
    ok "the Ansible layer defines where TLS material lives (${TLS_DIR})"
else
    bad "the Ansible layer defines where TLS material lives" "vault_tls_dir has no default"
fi

if [[ "${TLS_DIR}/ca.crt" == "$CA_TPL" ]]; then
    ok "and it is the CA path retry_join reads (${CA_TPL})"
else
    bad "and it is the CA path retry_join reads" \
        "templates read '${CA_TPL}', Ansible writes '${TLS_DIR}/ca.crt'"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed."
