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
# The single quotes are deliberate: sed must receive ${x} literally,
# not the empty expansion the shell would give it.
#
# ${bootstrap_cert_script} becomes a stub rather than the script. What
# templatefile() inserts there is a value, not template text, so its own
# lower-case ${tool} and ${extra} are never interpolated -- but this
# leftover check cannot tell them from a real one. The embedded code is
# checked where it lives: the shellcheck job lints
# scripts/issue-bootstrap-cert.sh, tests/bootstrap-cert runs it, and
# terraform/aws/tests/cluster.tftest.hcl asserts that stripping its
# comments for the 16 KB limit kept the code.
# shellcheck disable=SC2016
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
        -e 's|\${bootstrap_ca_prefix}|/vault-ref/tls|g' \
        -e 's|\${lb_dns_name}|vault-ref-nlb-0123456789.elb.us-east-1.amazonaws.com|g' \
        -e 's|^\${bootstrap_cert_script}$|echo "embedded: scripts/issue-bootstrap-cert.sh"|' \
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
PKI_DOMAIN="$(grep -E '^vault_pki_domain:' "$PKI_DEFAULTS" | cut -d: -f2- | xargs || true)"

# Resolve the domain before normalising, or both Jinja expressions
# collapse to the same token and the comparison stops meaning anything.
CLUSTER_SN_RESOLVED="${CLUSTER_SN//\{\{ vault_pki_domain \}\}/$PKI_DOMAIN}"
role_shape="$(sed -E 's/\{\{[^}]*\}\}/CLUSTER/g' <<< "$CLUSTER_SN_RESOLVED")"

if [[ "$tpl_shape" == "CLUSTER.vault.internal" ]]; then
    ok "the templates verify against <cluster>.vault.internal"
else
    bad "the templates verify against <cluster>.vault.internal" "got '${tpl_shape}'"
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

# A name every certificate must carry is worth nothing if the PKI role
# refuses to issue it. bootstrap-pki.sh sets allowed_domains to the PKI
# domain with allow_subdomains, so the servername has to sit inside that
# domain -- and the first attempt at this fix did not, which would have
# failed every issuance rather than only the joins.
sn_domain="${role_shape#CLUSTER.}"

if [[ -n "$PKI_DOMAIN" ]]; then
    ok "the PKI role declares a domain (${PKI_DOMAIN})"
else
    bad "the PKI role declares a domain" "vault_pki_domain has no default"
fi

if [[ "$sn_domain" == "$PKI_DOMAIN" || "$sn_domain" == *".${PKI_DOMAIN}" ]]; then
    ok "and the cluster servername sits inside it, so the role can issue it"
else
    bad "and the cluster servername sits inside it, so the role can issue it"         "'${CLUSTER_SN}' is not under '${PKI_DOMAIN}'; allowed_domains would refuse it"
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
printf '\n=== The inventory can tell the nodes apart ===\n'
# ---------------------------------------------------------------------------
# An Ansible inventory is keyed by host name, so two hosts with one name
# are one host. aws_ec2's `hostnames` is a list of *preferences*: it takes
# the first entry that resolves and stops.
#
# This profile is an autoscaling group, and a launch template has no
# per-instance interpolation — every instance it launches carries the same
# tags. So any `tag:` entry names every node identically, add_host()
# returns the host that already exists, and three instances collapse into
# the last one the paginator returned. site.yml then configures one node
# and exits 0, with snapshots, audit devices and PKI certificates on one
# machine out of three.
#
# Nothing else here can see it. terraform validate reads one file, the
# mocks read the configuration's shape, and tests/ansible checks this file
# parses as YAML. It is the Terraform/Ansible seam this suite is for.
INV="${REPO_ROOT}/ansible/inventory/aws_ec2.yml"
HOSTNAMES="$(python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
for entry in doc.get("hostnames") or []:
    print(entry if isinstance(entry, str) else entry.get("name", ""))
' "$INV" 2>/dev/null)"

if [[ -n "$HOSTNAMES" ]]; then
    ok "aws: the inventory declares how it names a host"
else
    bad "aws: the inventory declares how it names a host" \
        "no hostnames list — aws_ec2 then defaults to dns-name, which a private instance does not have"
fi

# Pin the values rather than forbidding the one spelling that bit us.
# tag:Name is not the only constant an ASG propagates; VaultCluster is
# another, and it is in this very file. The question is whether a value
# distinguishes instances at all, so allow only the ones that do.
UNIQUE_PER_INSTANCE=" instance-id private-ip-address private-dns-name network-interface.addresses.private-ip-address "
NOT_UNIQUE=""
while IFS= read -r pref; do
    [[ -z "$pref" ]] && continue
    [[ "$UNIQUE_PER_INSTANCE" == *" ${pref} "* ]] && continue
    NOT_UNIQUE="${NOT_UNIQUE}${pref} "
done <<< "$HOSTNAMES"

if [[ -z "$NOT_UNIQUE" ]]; then
    ok "aws: every hostname preference is unique per instance"
else
    bad "aws: every hostname preference is unique per instance" \
        "'${NOT_UNIQUE% }' is the same on every instance the ASG launches; the nodes merge into one host"
fi

# And the name it picks should be the name the cluster already uses, so an
# inventory host and a Raft voter can be matched up by eye. Both sides of
# the seam, each read from the file that owns it.
FIRST_PREF="$(head -1 <<< "$HOSTNAMES")"
NODE_ID_SRC="$(grep -oE 'INSTANCE_ID="\$\(imds [a-z-]+\)"' "$AWS_TPL" \
    | grep -oE 'imds [a-z-]+' | cut -d' ' -f2)"

if [[ -n "$NODE_ID_SRC" ]] && grep -qE 'node_id *= *"\$+\{INSTANCE_ID\}"' "$AWS_TPL"; then
    ok "aws: user-data derives Raft's node_id from ${NODE_ID_SRC}"
else
    bad "aws: user-data derives Raft's node_id from the instance id" \
        "the pattern stopped matching in $(basename "$AWS_TPL") — this assertion is no longer reading anything"
fi

if [[ "$FIRST_PREF" == "$NODE_ID_SRC" ]]; then
    ok "and the inventory names hosts by the same value (${FIRST_PREF})"
else
    bad "and the inventory names hosts by the same value" \
        "inventory prefers '${FIRST_PREF:-<none>}', node_id is '${NODE_ID_SRC:-<none>}'"
fi

# ---------------------------------------------------------------------------
printf '\n=== Every inventory a command names is a file that exists ===\n'
# ---------------------------------------------------------------------------
# The same seam as the section above, walked the other way. There the
# question was whether the inventory can tell the nodes apart; here it is
# whether anything telling a reader to run ansible-playbook names an
# inventory Ansible will actually open.
#
# The file name is load-bearing, and it is not the cloud's name:
# amazon.aws's aws_ec2 plugin reads only *aws_ec2.yml, and
# azure.azcollection's azure_rm only *azure_rm.yml. Each rejects any
# other name before looking inside it, so a wrong name is not a typo that
# fails loudly -- it is a run that configures zero hosts and exits 0.
# That is bug 6 in docs/roadmap.md, and it cost a real apply to find.
#
# It came back in a softer form. scripts/terraform-to-ansible.sh built
# its own next-step hint by interpolating the cloud, so it printed
# `inventory/aws.yml` -- a file that has never existed -- at the moment a
# reader is most likely to copy the line it prints. Two inventory headers
# carried the same dead names in their Usage blocks.
#
# Scanning every tracked file rather than a list of the ones known to
# carry such a line: the defect is a name going stale, and the file that
# goes stale unnoticed is by definition the one nobody thought to check.
INV_OUT="$(python3 - "$REPO_ROOT" <<'PY'
import os, re, subprocess, sys

root = sys.argv[1]
present = set(os.listdir(os.path.join(root, "ansible", "inventory")))

# The form a reader copies: an -i flag naming something under inventory/.
# Anchored on -i rather than on the bare path so that prose recording a
# name that used to be wrong is not read as an instruction to use it.
ref = re.compile(r'-i\s+(?:\S*/)?inventory/(\S+)')
var = re.compile(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?')

# Tracked files, not a walk of the directory: a walk would wander into
# .terraform's provider binaries and a developer's untracked scratch.
# If git cannot answer, say so -- a zero-file scan otherwise reads as
# "nothing names an inventory", which is the vacuous pass this whole
# section exists to avoid.
listing = subprocess.run(["git", "-C", root, "ls-files"],
                         capture_output=True, text=True)
if listing.returncode != 0:
    print("COUNT 0")
    print("PROBLEM could not list tracked files: "
          + (listing.stderr.strip().splitlines() or ["git ls-files failed"])[-1])
    sys.exit(0)
files = listing.stdout.split()

total = 0
problems = []
for rel in files:
    try:
        text = open(os.path.join(root, rel), encoding="utf-8").read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    for m in ref.finditer(text):
        # Trailing punctuation belongs to the prose around the name,
        # not to the name itself: a markdown backtick, a quote, a line
        # continuation, the comma that ends a sentence.
        raw = re.sub(r"""[`"'\\,;)]+$""", "", m.group(1))
        line = text.count("\n", 0, m.start()) + 1
        total += 1

        # A shell variable in the path is resolved from every literal
        # assignment to it in the same file, and every value it can take
        # has to name a real file. That is what lets this see through
        # `inventory/${CLOUD}.yml`, which resolves to nothing that
        # exists, instead of waving it through as unexaminable.
        names = [raw]
        for name in var.findall(raw):
            values = re.findall(r'\b' + name + r'=(["\']?)([^"\'\s;]+)\1', text)
            if not values:
                problems.append(f"{rel}:{line}: names inventory/{raw}, and "
                                f"${name} is never given a literal value in that file")
                names = []
                break
            names = [n.replace("${" + name + "}", v).replace("$" + name, v)
                     for n in names for _, v in values]

        for name in names:
            if "$" in name:
                problems.append(f"{rel}:{line}: names inventory/{name}, which no "
                                "value of the variables in it resolves")
            elif name not in present:
                problems.append(f"{rel}:{line}: names inventory/{name}, which is not "
                                f"in ansible/inventory/ ({', '.join(sorted(present))})")

print(f"COUNT {total}")
for p in problems:
    print("PROBLEM " + p)
PY
)"

INV_TOTAL="$(grep '^COUNT ' <<< "$INV_OUT" | cut -d' ' -f2)"
if [[ "${INV_TOTAL:-0}" -ge 10 ]]; then
    ok "${INV_TOTAL} commands across the repository name an inventory"
else
    bad "the repository's inventory references were found" \
        "only ${INV_TOTAL:-0}; either the pattern stopped matching or the files were never read, so this section is asserting nothing"
fi

INV_PROBLEMS="$(grep '^PROBLEM ' <<< "$INV_OUT" | sed 's/^PROBLEM //')"
if [[ -z "$INV_PROBLEMS" ]]; then
    ok "and every one of them resolves to a file in ansible/inventory/"
else
    while IFS= read -r line; do
        bad "an inventory is named that does not exist" "$line"
    done <<< "$INV_PROBLEMS"
fi

# ---------------------------------------------------------------------------
printf '\n=== Results ===\n'
# ---------------------------------------------------------------------------
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then red "FAILED"; exit 1; fi
green "All ${PASS} assertions passed."
