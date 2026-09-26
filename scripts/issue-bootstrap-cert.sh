#!/usr/bin/env bash
#
# issue-bootstrap-cert.sh — Give a node the autoscaling group just launched
#                           its TLS certificate, before Vault starts
#
# Usage:
#   ./issue-bootstrap-cert.sh --cluster-name vault-reference \
#       --ca-parameter-prefix /vault-reference/tls [options]
#
# Options:
#   --cluster-name <name>         Required. Decides the servername on the
#                                 leaf, and which CA is acceptable.
#   --cloud <aws|azure>           Where the CA is kept (default: aws).
#   --key-vault <name>            Azure only, required there. The Key
#                                 Vault holding the CA as two secrets.
#   --secret-prefix <name>        Azure only. Secret name prefix
#                                 (default: bootstrap-ca, giving
#                                 bootstrap-ca-crt and bootstrap-ca-key).
#   --ca-parameter-prefix <path>  AWS only, required there. The SSM path holding
#                                 bootstrap-ca.crt and bootstrap-ca.key.
#   --region <region>             AWS region (default: from instance metadata).
#   --extra-san <name>            Additional DNS SAN. Repeatable. The load
#                                 balancer's name goes here, as it does on
#                                 generate-cloud-certs.sh.
#   --tls-dir <dir>               Where Vault reads TLS (default: /etc/vault.d/tls).
#   --owner <user:group>          Owner of what is written (default: vault:vault).
#   --days <n>                    Leaf lifetime in days (default: 90).
#
# Runs from user-data on every node the autoscaling group launches, just
# before Vault starts. Exits 0 when it wrote a certificate and when there
# was nothing for it to do; non-zero only when something is wrong.
#
# WHY THIS EXISTS
#
# A node's certificate used to come from one place: an Ansible run, keyed
# to an instance id that does not exist until the launch. The first real
# apply terminated a leader to see what happened, and the autoscaling group
# replaced it in 75 seconds with an instance whose Vault exited with
# `error loading TLS cert` until systemd stopped retrying. The cluster was
# not self-healing; it was self-replacing, and the replacement sat there.
#
# So the bootstrap CA -- which generate-cloud-certs.sh already keeps, for
# exactly this -- is published to SSM by publish-bootstrap-ca.sh, the node
# role may read it, and a new node signs its own leaf with it at boot.
#
# What it does:
#   1. If a certificate is already in --tls-dir, does nothing. Renewal and
#      the Ansible role own an existing certificate; this only fills a gap.
#   2. Reads the CA certificate and key from SSM. If they are still the
#      placeholder Terraform created, says so and exits 0: this is a first
#      apply, and the certificates will come from Ansible as before.
#   3. Refuses a CA that is not this cluster's, or a key that is not that
#      CA's.
#   4. Signs a leaf carrying exactly the SANs generate-cloud-certs.sh puts
#      on every leaf, plus the extra ones, and verifies it before writing.
#   5. Writes the leaf, its key and the CA certificate where vault.hcl
#      expects them, and deletes the CA key.
#
# DELIBERATE BEHAVIOURS
#
#   - The SAN set is generate-cloud-certs.sh's, name for name. A leaf this
#     issues and a leaf that issues are interchangeable, and tests/
#     bootstrap-cert holds them to it. Let them drift and a self-healed
#     node fails a check its peers pass -- or the reverse.
#   - The CA key lives only in a private temporary directory and is gone
#     when the script exits, success or not. It is on a node for seconds.
#   - Nothing is written until the leaf verifies against the CA and
#     carries the node's own address and the cluster servername. A leaf
#     that fails those is worse than none: Vault would start, and never
#     join.
#   - An unpublished CA is not an error. On a first apply the nodes boot
#     before any CA exists, and failing user-data there would bury the one
#     message that matters under a red one that does not.
#
# Requirements: bash, openssl, curl; the aws CLI v2 on AWS; jq on Azure.
#               The Azure path needs no az CLI and nothing the image
#               lacks: the managed identity's token comes from IMDS and
#               the CA from the Key Vault REST API, both over curl.
#
# WHY AZURE KEEPS THE CA IN SECRETS TERRAFORM DOES NOT OWN
#
# On AWS, Terraform creates both SSM parameters with a placeholder and
# the publish script overwrites them, so a teardown removes them and a
# write-only argument keeps the key out of state. azurerm has no such
# argument for azurerm_key_vault_secret: `value` is required, and the
# provider reads it back on refresh. A placeholder secret would
# therefore put the published CA key into Terraform state on the next
# apply -- the defect fixed for AWS in #105, with no fix available here.
#
# So on Azure the two secrets are created by publish-bootstrap-ca.sh and
# Terraform never names them. Nothing is orphaned: they live in the
# cluster's own Key Vault and die with it. What is lost is the
# placeholder's other job -- `terraform plan` no longer shows whether a
# CA has been published. Ask the vault, or the pre-flight.

set -euo pipefail

CLUSTER_NAME=""
CLOUD="aws"
PREFIX=""
REGION=""
KEY_VAULT=""
SECRET_PREFIX="bootstrap-ca"
TLS_DIR="/etc/vault.d/tls"
OWNER="vault:vault"
DAYS_LEAF=90
EXTRA_SANS=()

# What Terraform writes into both parameters until the CA is published.
PLACEHOLDER="UNPUBLISHED"
IMDS="http://169.254.169.254"

log() { printf '[bootstrap-cert] %s\n' "$*" >&2; }
die() { printf '[bootstrap-cert] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name)        CLUSTER_NAME="$2"; shift 2 ;;
        --cloud)               CLOUD="$2"; shift 2 ;;
        --key-vault)           KEY_VAULT="$2"; shift 2 ;;
        --secret-prefix)       SECRET_PREFIX="$2"; shift 2 ;;
        --ca-parameter-prefix) PREFIX="${2%/}"; shift 2 ;;
        --region)              REGION="$2"; shift 2 ;;
        --extra-san)           EXTRA_SANS+=("$2"); shift 2 ;;
        --tls-dir)             TLS_DIR="$2"; shift 2 ;;
        --owner)               OWNER="$2"; shift 2 ;;
        --days)                DAYS_LEAF="$2"; shift 2 ;;
        -h|--help)             usage ;;
        *)                     die "Unknown argument: $1" ;;
    esac
done

[[ -n "$CLUSTER_NAME" ]] || die "--cluster-name is required"

case "$CLOUD" in
    aws)
        [[ -n "$PREFIX" ]] || die "--ca-parameter-prefix is required on aws"
        REQUIRED_TOOLS=(openssl aws curl)
        ;;
    azure)
        [[ -n "$KEY_VAULT" ]] || die "--key-vault is required on azure"
        # jq rather than sed through the JSON: the response carries a PEM
        # with its newlines escaped, and unescaping that by hand is how a
        # CA key arrives subtly corrupt with openssl blaming the key.
        REQUIRED_TOOLS=(openssl curl jq)
        ;;
    *) die "--cloud must be aws or azure, got: ${CLOUD}" ;;
esac

for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || die "${tool} is not on PATH"
done

# ---------------------------------------------------------------------------
# 1. Only fill a gap
# ---------------------------------------------------------------------------
if [[ -f "${TLS_DIR}/vault.crt" ]]; then
    log "A certificate is already present at ${TLS_DIR}/vault.crt; leaving it alone."
    exit 0
fi

# ---------------------------------------------------------------------------
# Who this node is
# ---------------------------------------------------------------------------
if [[ "$CLOUD" == "aws" ]]; then
    IMDS_TOKEN="$(curl -sS -f -X PUT "${IMDS}/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 300")" \
        || die "Could not get an IMDSv2 token"

    imds() {
        curl -sS -f -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" "${IMDS}/latest/meta-data/$1"
    }

    INSTANCE_ID="$(imds instance-id)" || die "Could not read the instance id"
    LOCAL_IPV4="$(imds local-ipv4)" || die "Could not read the private address"
    [[ -n "$REGION" ]] || REGION="$(imds placement/region)" || die "Could not read the region"
else
    # Azure's IMDS is a different protocol: a Metadata header rather than
    # a PUT-issued token, and the VM's name where AWS has an instance id.
    # The name is the part that matters -- cloud-init derives Raft's
    # node_id from compute/name, so a leaf whose CN is anything else
    # names a node the cluster does not have.
    azmeta() {
        curl -sS -f -H "Metadata: true" \
            "${IMDS}/metadata/instance/$1?api-version=2021-02-01&format=text"
    }

    INSTANCE_ID="$(azmeta compute/name)" || die "Could not read the VM name from IMDS"
    LOCAL_IPV4="$(azmeta network/interface/0/ipv4/ipAddress/0/privateIpAddress)" \
        || die "Could not read the private address from IMDS"
    [[ -n "$REGION" ]] || REGION="$(azmeta compute/location)" || die "Could not read the location"
fi

[[ -n "$INSTANCE_ID" && -n "$LOCAL_IPV4" ]] || die "Instance metadata answered with nothing"

log "Node ${INSTANCE_ID} (${LOCAL_IPV4}) in ${REGION}."

# ---------------------------------------------------------------------------
# 2. The CA, from SSM
# ---------------------------------------------------------------------------
SCRATCH="$(mktemp -d)"
chmod 700 "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

if [[ "$CLOUD" == "aws" ]]; then
    param() {
        aws ssm get-parameter --region "$REGION" --name "$1" "${@:2}" \
            --query Parameter.Value --output text
    }

    CA_CERT_VALUE="$(param "${PREFIX}/bootstrap-ca.crt")" \
        || die "Could not read ${PREFIX}/bootstrap-ca.crt. Check the node role may call ssm:GetParameter on it."
    CA_KEY_SOURCE="${PREFIX}/bootstrap-ca.key"
    CA_LOCATION="$PREFIX"
else
    # A managed-identity token for Key Vault, then the secrets. The
    # identity is granted Get on secrets and nothing else (see
    # terraform/azure/compute.tf): a node cannot overwrite the CA it is
    # about to trust, and cannot list what else the vault holds.
    KV_TOKEN="$(curl -sS -f -H "Metadata: true" \
        "${IMDS}/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
        | jq -r '.access_token')" \
        || die "Could not get a managed-identity token for Key Vault. Check the VM carries the cluster identity."
    [[ -n "$KV_TOKEN" && "$KV_TOKEN" != "null" ]] \
        || die "IMDS returned no access token for Key Vault"

    secret() {
        # A 404 and a 403 are different problems, and both look like an
        # empty value if the status is dropped. --fail alone would also
        # discard the body that says which one happened.
        local name body status
        name="$1"
        body="$(curl -sS -w '\n%{http_code}' \
            -H "Authorization: Bearer ${KV_TOKEN}" \
            "https://${KEY_VAULT}.vault.azure.net/secrets/${name}?api-version=7.4")" || return 1
        status="$(tail -1 <<< "$body")"
        body="$(sed '$d' <<< "$body")"
        case "$status" in
            200) jq -r '.value' <<< "$body" ;;
            404) printf '%s' "$PLACEHOLDER" ;;
            403) log "Key Vault refused the read: $(jq -r '.error.message // empty' <<< "$body")"; return 1 ;;
            *)   log "Key Vault answered ${status}: $(jq -r '.error.message // empty' <<< "$body")"; return 1 ;;
        esac
    }

    CA_CERT_VALUE="$(secret "${SECRET_PREFIX}-crt")" \
        || die "Could not read secret ${SECRET_PREFIX}-crt from ${KEY_VAULT}. The identity needs Get on secrets."
    CA_KEY_SOURCE="${SECRET_PREFIX}-key"
    CA_LOCATION="$KEY_VAULT"
fi

# An unpublished CA is not an error. On a first apply the nodes boot
# before any CA exists, and failing here would bury the one message that
# matters under a red one that does not.
if [[ "$CA_CERT_VALUE" == "$PLACEHOLDER" ]]; then
    log "The bootstrap CA has not been published to ${CA_LOCATION} yet."
    log "This is expected on a first apply: certificates come from the Ansible"
    log "layer as before. Once scripts/publish-bootstrap-ca.sh has run, nodes"
    log "launched after it issue their own."
    exit 0
fi

if [[ "$CLOUD" == "aws" ]]; then
    CA_KEY_VALUE="$(param "$CA_KEY_SOURCE" --with-decryption)" \
        || die "Could not read ${CA_KEY_SOURCE}. The node role needs kms:Decrypt on the key it is encrypted under."
else
    CA_KEY_VALUE="$(secret "$CA_KEY_SOURCE")" \
        || die "Could not read secret ${CA_KEY_SOURCE} from ${KEY_VAULT}. The identity needs Get on secrets."
fi

[[ "$CA_KEY_VALUE" != "$PLACEHOLDER" ]] \
    || die "The CA certificate is published but its key is not. Re-run scripts/publish-bootstrap-ca.sh."

printf '%s\n' "$CA_CERT_VALUE" > "${SCRATCH}/ca.crt"
( umask 077; printf '%s\n' "$CA_KEY_VALUE" > "${SCRATCH}/ca.key" )
unset CA_KEY_VALUE

# ---------------------------------------------------------------------------
# 3. The right CA, with the right key
# ---------------------------------------------------------------------------
SUBJECT="$(openssl x509 -in "${SCRATCH}/ca.crt" -noout -subject 2>/dev/null)" \
    || die "The published CA certificate does not parse"
[[ "$SUBJECT" == *"${CLUSTER_NAME} bootstrap CA"* ]] \
    || die "The published CA is not ${CLUSTER_NAME}'s: ${SUBJECT}"

CERT_PUB="$(openssl x509 -in "${SCRATCH}/ca.crt" -noout -pubkey 2>/dev/null)"
KEY_PUB="$(openssl pkey -in "${SCRATCH}/ca.key" -pubout 2>/dev/null)" \
    || die "The published CA key does not parse"
[[ -n "$CERT_PUB" && "$CERT_PUB" == "$KEY_PUB" ]] \
    || die "The published CA key does not belong to the published CA certificate"

# ---------------------------------------------------------------------------
# 4. The leaf -- generate-cloud-certs.sh's recipe, and its SAN set
# ---------------------------------------------------------------------------
CLUSTER_SERVERNAME="${CLUSTER_NAME}.vault.internal"
SAN="IP:${LOCAL_IPV4},DNS:${INSTANCE_ID},DNS:${CLUSTER_SERVERNAME},DNS:localhost,IP:127.0.0.1"
# An extra SAN is usually a name -- the AWS load balancer's -- but Azure's
# load balancer has no name to give, only an address, and openssl needs
# IP: for one of those. A DNS entry holding an address matches nothing: the
# leaf would verify for every client except the ones arriving through the
# load balancer, which is the traffic it was added for.
for extra in ${EXTRA_SANS+"${EXTRA_SANS[@]}"}; do
    if [[ "$extra" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        SAN="${SAN},IP:${extra}"
    else
        SAN="${SAN},DNS:${extra}"
    fi
done

openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout "${SCRATCH}/vault.key" -out "${SCRATCH}/vault.csr" \
    -subj "/CN=${INSTANCE_ID}/O=vault-reference-platform" \
    2>/dev/null || die "Failed to generate the node key"

# serverAuth,clientAuth: Raft peers authenticate to each other.
cat > "${SCRATCH}/leaf.ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=${SAN}
EOF

openssl x509 -req -in "${SCRATCH}/vault.csr" \
    -CA "${SCRATCH}/ca.crt" -CAkey "${SCRATCH}/ca.key" -CAcreateserial \
    -out "${SCRATCH}/vault.crt" -days "$DAYS_LEAF" -sha256 \
    -extfile "${SCRATCH}/leaf.ext" \
    2>/dev/null || die "Failed to sign the node certificate"

# Before anything is written: a leaf Vault would start with and no peer
# would accept is worse than no leaf at all.
openssl verify -CAfile "${SCRATCH}/ca.crt" "${SCRATCH}/vault.crt" >/dev/null 2>&1 \
    || die "The signed certificate does not verify against the CA"
openssl x509 -in "${SCRATCH}/vault.crt" -noout -checkhost "$CLUSTER_SERVERNAME" 2>/dev/null \
    | grep -q "does match" || die "The signed certificate lacks ${CLUSTER_SERVERNAME}"
openssl x509 -in "${SCRATCH}/vault.crt" -noout -checkip "$LOCAL_IPV4" 2>/dev/null \
    | grep -q "does match" || die "The signed certificate lacks ${LOCAL_IPV4}"

# ---------------------------------------------------------------------------
# 5. Where vault.hcl looks for it
# ---------------------------------------------------------------------------
OWNER_USER="${OWNER%%:*}"
OWNER_GROUP="${OWNER##*:}"

install -d -m 0750 -o "$OWNER_USER" -g "$OWNER_GROUP" "$TLS_DIR"
install -m 0644 -o "$OWNER_USER" -g "$OWNER_GROUP" "${SCRATCH}/ca.crt" "${TLS_DIR}/ca.crt"
install -m 0600 -o "$OWNER_USER" -g "$OWNER_GROUP" "${SCRATCH}/vault.key" "${TLS_DIR}/vault.key"
install -m 0644 -o "$OWNER_USER" -g "$OWNER_GROUP" "${SCRATCH}/vault.crt" "${TLS_DIR}/vault.crt"

log "Wrote ${TLS_DIR}/vault.crt for ${INSTANCE_ID}, signed by the ${CLUSTER_NAME} bootstrap CA."
log "The CA key was never written outside a private directory, and is now deleted."
