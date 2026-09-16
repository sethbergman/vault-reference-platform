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
#                          (default: ansible/inventory/aws.yml).
#   --hosts-json <path>    Read `ansible-inventory --list` output from a
#                          file instead of running it. For testing, and
#                          for a control machine without the AWS
#                          collection installed.
#   --out <dir>            Where to write (default: ansible/files/tls).
#   --extra-san <name>     Additional DNS SAN on every leaf. Repeatable.
#                          See "the load balancer" below.
#   --days <n>             Leaf lifetime in days (default: 90).
#   --force                Replace an existing directory.
#
# Examples:
#   ./generate-cloud-certs.sh --cluster-name vault-reference
#   ./generate-cloud-certs.sh --cluster-name vault-reference \
#       --extra-san vault-nlb-abc123.elb.us-east-1.amazonaws.com
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
# DELIBERATE BEHAVIOURS
#
#   - Refuses to overwrite without --force. It mints private keys, and a
#     re-run that silently replaced them would leave nodes serving
#     certificates the CA on disk no longer matches.
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
INVENTORY="${REPO_ROOT}/ansible/inventory/aws.yml"
HOSTS_JSON=""
OUT_DIR="${REPO_ROOT}/ansible/files/tls"
DAYS_LEAF=90
DAYS_CA=3650
FORCE=false
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
        --force)        FORCE=true; shift ;;
        -h|--help)      usage ;;
        *)              die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLUSTER_NAME" ]] || die "--cluster-name is required"

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
if [[ -d "$OUT_DIR" ]] && [[ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]]; then
    if [[ "$FORCE" != true ]]; then
        die "${OUT_DIR} is not empty — pass --force to replace it.
       Replacing it issues a new CA, so every node needs the new material.
       Delivering it to some of them leaves a cluster that cannot form."
    fi
    log "Replacing the contents of ${OUT_DIR}..."
    rm -f "${OUT_DIR}"/*.crt "${OUT_DIR}"/*.key "${OUT_DIR}"/*.srl
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
cd "$OUT_DIR"

# ---------------------------------------------------------------------------
# The CA
# ---------------------------------------------------------------------------
log "Issuing a bootstrap CA for ${CLUSTER_NAME}..."

openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
    -keyout ca.key -out ca.crt -days "$DAYS_CA" \
    -subj "/CN=${CLUSTER_NAME} bootstrap CA/O=vault-reference-platform" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    2>/dev/null || die "Failed to generate the CA"

chmod 600 ca.key
chmod 644 ca.crt

CLUSTER_SERVERNAME="${CLUSTER_NAME}.vault.internal"

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
log "Wrote ${OUT_DIR}:"
log "  ca.crt / ca.key           the bootstrap CA"
log "  <instance-id>.crt / .key  one leaf per node"
log ""
log "Every leaf carries ${CLUSTER_SERVERNAME}, the name a follower verifies"
log "a leader against. Nothing forms a cluster without it."
log ""
log "Next: cd ansible && ansible-playbook -i inventory/aws.yml playbooks/site.yml"
