#!/usr/bin/env bash
#
# generate-cloud-certs.sh — Issue bootstrap TLS material for a cloud
#                           cluster, named after the hosts that exist
#
# Usage:
#   ./generate-cloud-certs.sh --cluster-name vault-reference [options]
#
# Options:
#   --cluster-name <name>  Required. The cluster's name, which decides the
#                          servername every peer verifies a leader against.
#   --inventory <path>     Ansible inventory to read the hosts from
#                          (default: ansible/inventory/aws_ec2.yml).
#   --hosts-json <path>    Read `ansible-inventory --list` output from a
#                          file instead of running it. For testing, and
#                          for a control machine without the AWS
#                          collection installed.
#   --out <dir>            Where to write (default: ansible/files/tls).
#   --extra-san <name>     Additional DNS SAN on every leaf. Repeatable.
#                          See "the load balancer" below.
#   --days <n>             Leaf lifetime in days (default: 90).
#   --add-missing          Issue leaves only for hosts that have none, from
#                          the CA already in --out. For a replacement node.
#   --force                Replace an existing directory, CA and all.
#
# Examples:
#   ./generate-cloud-certs.sh --cluster-name vault-reference
#   ./generate-cloud-certs.sh --cluster-name vault-reference \
#       --extra-san vault-nlb-abc123.elb.us-east-1.amazonaws.com
#
#   # After the autoscaling group replaced a node:
#   ./generate-cloud-certs.sh --cluster-name vault-reference --add-missing
#   cd ansible && ansible-playbook -i inventory/aws_ec2.yml \
#       playbooks/site.yml --limit <new-instance-id>
#
# WHY THIS EXISTS
#
# The vault role copies files/tls/<inventory_hostname>.{crt,key} to each
# node. On the cloud profiles the inventory is dynamic and a host is named
# by its instance id, so the filenames are not knowable until after the
# apply -- there is nothing to pre-generate and commit, and a first real
# apply would otherwise stall here with a cluster running and no way to
# configure it.
#
# So the hosts come from the same inventory the playbook will use. Run it
# between terraform-to-ansible.sh and ansible-playbook.
#
# WHAT EACH LEAF CARRIES, AND WHY
#
#   IP:<private ip>        what the vault role verifies the delivered
#                          certificate against, with `openssl -checkip`
#   DNS:<inventory host>   the node's own name, and the common name the
#                          PKI role later issues it under
#   DNS:<cluster>.vault.internal
#                          leader_tls_servername -- the ONE name a
#                          follower verifies a leader against, whichever
#                          node that happens to be. A certificate without
#                          it forms no cluster, and every node reports
#                          healthy while it fails to
#   DNS:localhost, IP:127.0.0.1
#                          the node curling its own API
#
# That is deliberately the same set scripts/issue-node-cert.sh and the
# vault_pki role issue on renewal, so a bootstrap certificate and a
# renewed one are interchangeable. Let them diverge and the node that has
# renewed stops satisfying a check the node that has not still passes.
#
# THE LOAD BALANCER IS NOT IN THAT LIST
#
# `terraform output vault_addr` is the load balancer's DNS name, and a
# client dialling it verifies against that name. AWS generates it and it
# is unknowable before the apply, so it cannot be a default here: pass
# --extra-san for it, or point a CNAME you control at the cluster and
# pass that instead. Without one, clients get a name mismatch against a
# certificate that is otherwise correct, which reads as a broken cluster
# and is not one.
#
# THE REPLACEMENT NODE, WHICH IS WHY --add-missing EXISTS
#
# An autoscaling group replaces a node without asking, and the
# replacement boots with no certificate: the vault role delivers one, and
# the role runs when a person runs it. The first real apply found out the
# hard way -- a terminated leader was replaced in 75 seconds by an
# instance whose Vault exited with `error loading TLS cert` until systemd
# gave up. The cluster carried on with two voters; nothing recovered.
#
# This script kept the CA key for exactly that case and offered no way to
# use it. Its only other mode was --force, which mints a *new* CA: every
# node then needs the new material before any node presents it, so
# reaching for it to fix one node is how a working cluster becomes a
# cluster that cannot form. --add-missing signs one more leaf with the CA
# that is already trusted, and touches nothing else.
#
# It is still a person running a command. Unattended recovery would mean
# a node fetching its own material at boot, which is a different design
# and is not this.
#
# DELIBERATE BEHAVIOURS
#
#   - Refuses to overwrite without --force. It mints private keys, and a
#     re-run that silently replaced them would leave nodes serving
#     certificates the CA on disk no longer matches.
#   - --add-missing refuses a CA that is not this cluster's, by reading
#     the subject of ca.crt. The servername on a leaf comes from
#     --cluster-name, so a mistyped one signs a certificate for a name
#     nobody verifies -- and the node it lands on joins nothing while
#     reporting healthy.
#   - --add-missing carries over the extra SANs an existing leaf has. Pass
#     --extra-san for the load balancer once and a replacement gets it
#     too; forget it and clients through the load balancer fail against
#     that node alone, which reads as the node being broken.
#   - Writes the CA key, and keeps it. A replacement node needs a
#     certificate, and an autoscaling group produces replacements without
#     asking. The directory is gitignored; treat it as a secret.
#   - This is a bootstrap CA, not a permanent one. Vault's own PKI cannot
#     issue the certificates the cluster needs in order to start, so
#     something outside it has to go first.
#     scripts/migrate-to-vault-pki.sh sequences the handover.
#
# Requirements: openssl, jq, and ansible-inventory unless --hosts-json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_NAME=""
INVENTORY="${REPO_ROOT}/ansible/inventory/aws_ec2.yml"
HOSTS_JSON=""
OUT_DIR="${REPO_ROOT}/ansible/files/tls"
DAYS_LEAF=90
DAYS_CA=3650
FORCE=false
ADD_MISSING=false
EXTRA_SANS=()

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --inventory)    INVENTORY="$2"; shift 2 ;;
        --hosts-json)   HOSTS_JSON="$2"; shift 2 ;;
        --out)          OUT_DIR="$2"; shift 2 ;;
        --extra-san)    EXTRA_SANS+=("$2"); shift 2 ;;
        --days)         DAYS_LEAF="$2"; shift 2 ;;
        --add-missing)  ADD_MISSING=true; shift ;;
        --force)        FORCE=true; shift ;;
        -h|--help)      usage ;;
        *)              die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLUSTER_NAME" ]] || die "--cluster-name is required"

# One mints a CA, the other reuses one. Together they read as "add what is
# missing" and would replace everything.
if [[ "$ADD_MISSING" == true && "$FORCE" == true ]]; then
    die "--add-missing and --force are opposites: --force mints a new CA and
       replaces every leaf, --add-missing signs one more with the CA on disk."
fi

command -v openssl >/dev/null 2>&1 || die "openssl is not on PATH"
command -v jq >/dev/null 2>&1 || die "jq is not on PATH"

# ---------------------------------------------------------------------------
# The hosts
# ---------------------------------------------------------------------------
if [[ -n "$HOSTS_JSON" ]]; then
    [[ -f "$HOSTS_JSON" ]] || die "No such file: ${HOSTS_JSON}"
    INVENTORY_JSON="$(cat "$HOSTS_JSON")"
else
    command -v ansible-inventory >/dev/null 2>&1 \
        || die "ansible-inventory is not on PATH (or pass --hosts-json)"
    [[ -f "$INVENTORY" ]] || die "No such inventory: ${INVENTORY}"
    log "Reading hosts from ${INVENTORY}..."
    INVENTORY_JSON="$(ansible-inventory -i "$INVENTORY" --list 2>/dev/null)" \
        || die "ansible-inventory failed against ${INVENTORY}"
fi

echo "$INVENTORY_JSON" | jq -e . >/dev/null 2>&1 \
    || die "Inventory output is not valid JSON"

# A host with no private_ip_address is dropped rather than issued a
# certificate missing the SAN the role checks. The alternative fails on
# the node, after the key has been written, instead of here.
HOSTS="$(echo "$INVENTORY_JSON" | jq -r '
    (.vault_nodes.hosts // [])[] as $h
    | (._meta.hostvars[$h] // {})
    | select(.private_ip_address != null)
    | "\($h) \(.private_ip_address)"
')"

if [[ -z "$HOSTS" ]]; then
    die "No host in the vault_nodes group has a private_ip_address.
       An empty inventory is the usual cause: the cluster has not finished
       booting, or these credentials cannot see it. Check with
         ansible-inventory -i ${INVENTORY} --graph"
fi

NODE_COUNT="$(grep -c . <<< "$HOSTS")"
log "Found ${NODE_COUNT} node(s)."

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------
CA_SUBJECT="${CLUSTER_NAME} bootstrap CA"

if [[ "$ADD_MISSING" == true ]]; then
    for f in ca.crt ca.key; do
        [[ -f "${OUT_DIR}/${f}" ]] || die "No ${f} in ${OUT_DIR}.
       --add-missing signs a leaf with the CA that is already on disk and
       already trusted by the running nodes. There is none here, so this is
       a first run: drop --add-missing."
    done

    ON_DISK="$(openssl x509 -in "${OUT_DIR}/ca.crt" -noout -subject 2>/dev/null || true)"
    if [[ "$ON_DISK" != *"${CA_SUBJECT}"* ]]; then
        die "The CA in ${OUT_DIR} is not ${CLUSTER_NAME}'s.
       Its subject is: ${ON_DISK:-<unreadable>}
       A leaf's servername comes from --cluster-name, so signing one here
       would produce a certificate for a name no node verifies."
    fi
    log "Reusing the bootstrap CA in ${OUT_DIR} (${CA_SUBJECT})."
elif [[ -d "$OUT_DIR" ]] && [[ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]]; then
    if [[ "$FORCE" != true ]]; then
        die "${OUT_DIR} is not empty — pass --force to replace it, or
       --add-missing to issue only for hosts that have no certificate.
       Replacing it issues a new CA, so every node needs the new material.
       Delivering it to some of them leaves a cluster that cannot form."
    fi
    log "Replacing the contents of ${OUT_DIR}..."
    rm -f "${OUT_DIR}"/*.crt "${OUT_DIR}"/*.key "${OUT_DIR}"/*.srl
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
cd "$OUT_DIR"

CLUSTER_SERVERNAME="${CLUSTER_NAME}.vault.internal"

# ---------------------------------------------------------------------------
# The CA
# ---------------------------------------------------------------------------
if [[ "$ADD_MISSING" != true ]]; then
    log "Issuing a bootstrap CA for ${CLUSTER_NAME}..."

    openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
        -keyout ca.key -out ca.crt -days "$DAYS_CA" \
        -subj "/CN=${CA_SUBJECT}/O=vault-reference-platform" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        2>/dev/null || die "Failed to generate the CA"

    chmod 600 ca.key
    chmod 644 ca.crt
fi

# ---------------------------------------------------------------------------
# Which hosts, and which SANs, when adding to an existing set
# ---------------------------------------------------------------------------
if [[ "$ADD_MISSING" == true ]]; then
    # Any DNS name on an existing leaf that is not that node's own name and
    # not one this script puts on every leaf is an --extra-san somebody
    # passed. Carrying it over is the difference between a replacement
    # clients can reach through the load balancer and one they cannot.
    EXISTING_LEAF=""
    while read -r node _; do
        [[ -n "$node" ]] || continue
        if [[ -f "${node}.crt" ]]; then EXISTING_LEAF="${node}.crt"; break; fi
    done <<< "$HOSTS"

    if [[ -n "$EXISTING_LEAF" ]]; then
        CARRIED="$(openssl x509 -in "$EXISTING_LEAF" -noout -ext subjectAltName 2>/dev/null \
            | tr ',' '\n' | sed -n 's/^ *DNS://p' \
            | grep -vxF -e "${EXISTING_LEAF%.crt}" -e "$CLUSTER_SERVERNAME" -e localhost || true)"
        while read -r name; do
            [[ -n "$name" ]] || continue
            if [[ " ${EXTRA_SANS[*]-} " == *" ${name} "* ]]; then continue; fi
            EXTRA_SANS+=("$name")
            log "Carrying over --extra-san ${name} from ${EXISTING_LEAF}."
        done <<< "$CARRIED"
    fi

    MISSING=""
    while read -r node ip; do
        [[ -n "$node" ]] || continue
        if [[ -f "${node}.crt" || -f "${node}.key" ]]; then continue; fi
        MISSING="${MISSING}${node} ${ip}"$'\n'
    done <<< "$HOSTS"

    if [[ -z "${MISSING//[[:space:]]/}" ]]; then
        log "Every host in the inventory already has a certificate. Nothing to do."
        exit 0
    fi
    HOSTS="${MISSING%$'\n'}"
    log "Issuing for $(grep -c . <<< "$HOSTS") host(s) without one."
fi

# ---------------------------------------------------------------------------
# Leaf certificates
# ---------------------------------------------------------------------------
while read -r node ip; do
    [[ -n "$node" ]] || continue
    log "Issuing a certificate for ${node} (${ip})..."

    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout "${node}.key" -out "${node}.csr" \
        -subj "/CN=${node}/O=vault-reference-platform" \
        2>/dev/null || die "Failed to generate a key for ${node}"

    SAN="IP:${ip},DNS:${node},DNS:${CLUSTER_SERVERNAME},DNS:localhost,IP:127.0.0.1"
    for extra in ${EXTRA_SANS+"${EXTRA_SANS[@]}"}; do
        SAN="${SAN},DNS:${extra}"
    done

    # serverAuth,clientAuth: Raft peers authenticate to each other, so a
    # server-only certificate leaves the cluster unable to form.
    cat > "${node}.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=${SAN}
EOF

    openssl x509 -req -in "${node}.csr" -CA ca.crt -CAkey ca.key \
        -CAcreateserial -out "${node}.crt" -days "$DAYS_LEAF" -sha256 \
        -extfile "${node}.ext" \
        2>/dev/null || die "Failed to sign the certificate for ${node}"

    rm -f "${node}.csr" "${node}.ext"

    chmod 600 "${node}.key"
    chmod 644 "${node}.crt"
done <<< "$HOSTS"

rm -f ca.srl

log ""
if [[ "$ADD_MISSING" == true ]]; then
    log "Added to ${OUT_DIR}, signed by the CA already there:"
    while read -r node _; do
        [[ -n "$node" ]] || continue
        log "  ${node}.crt / .key"
    done <<< "$HOSTS"
else
    log "Wrote ${OUT_DIR}:"
    log "  ca.crt / ca.key           the bootstrap CA"
    log "  <instance-id>.crt / .key  one leaf per node"
fi
log ""
log "Every leaf carries ${CLUSTER_SERVERNAME}, the name a follower verifies"
log "a leader against. Nothing forms a cluster without it."
log ""
if [[ "$ADD_MISSING" == true ]]; then
    log "Next, for the new host only -- the others are configured already:"
    while read -r node _; do
        [[ -n "$node" ]] || continue
        log "  cd ansible && ansible-playbook -i inventory/aws_ec2.yml \\"
        log "      playbooks/site.yml --limit ${node}"
    done <<< "$HOSTS"
else
    log "Next: cd ansible && ansible-playbook -i inventory/aws_ec2.yml playbooks/site.yml"
fi
