# Replacement node certificate tests

`scripts/issue-bootstrap-cert.sh` runs from user-data on every node the
autoscaling group launches and signs that node's own TLS leaf, from a
bootstrap CA that `scripts/publish-bootstrap-ca.sh` put in SSM. These
tests drive both.

```bash
./tests/bootstrap-cert/run-tests.sh
```

## Why these exist

The first real AWS apply terminated a leader to see what would happen.
The autoscaling group replaced it in 75 seconds, and the replacement's
Vault never started: certificates came only from an Ansible run keyed to
an instance id that did not exist until the launch. See
[`docs/cloud-apply.md`](../../docs/cloud-apply.md#the-cluster-is-not-self-healing).

Both scripts handle a CA key, and both fail quietly in ordinary ways — a
put under the wrong KMS key, a SecureString read without decryption, a
leaf missing one SAN its peers carry. Most of what is asserted is what
they must refuse.

The property the design rests on is interchangeability: a leaf issued at
boot must be indistinguishable from one `generate-cloud-certs.sh` issues
for the same node. The suite issues one of each and compares their SAN
sets, then pins the three SANs that matter so two scripts cannot agree by
both dropping one.

## What is real and what is faked

Real: every CA and leaf is `openssl` output, and the fixture CAs are
issued by `generate-cloud-certs.sh` itself.

Faked, in `fake-bin/`, and modelled on the real services rather than on
what the scripts want:

| Shim | What it models that matters |
|---|---|
| `aws` | A SecureString read without `--with-decryption` returns ciphertext. `put-parameter --type SecureString` with no `--key-id` encrypts under `alias/aws/ssm`, which is the trap `publish-bootstrap-ca.sh` exists to avoid. A missing parameter is `ParameterNotFound`, exit 254 |
| `curl` | IMDSv2 as the launch template enforces it: a `GET` without the token header is refused with 401 |

## Checking the tests still fail

Every row was run and watched to fail:

| Mutation | Caught by |
|---|---|
| Boot script reads the key without `--with-decryption` | `it writes a certificate…`, `the leaf verifies…` |
| Boot script's SANs drop `localhost` | `its SANs are exactly generate-cloud-certs.sh's` |
| Boot script accepts any CA's subject | `another cluster's CA is refused` |
| Boot script overwrites an existing certificate | `a certificate already present is left alone` |
| Boot script copies the CA key into the TLS directory | `no copy of the CA key survives the run` |
| Publish without `--key-id` | `the key goes back under the KMS key it was created with`, and the stored-key check |
| Publish skips the key's read-back | `a bootstrap-ca.key that does not read back is a failure` |
| Publish skips the certificate's read-back | `a bootstrap-ca.crt that does not read back is a failure` |
| `tls.tf`'s placeholder renamed | `tls.tf and the boot script agree on the placeholder`, and three first-apply cases |

The read-back rows were written after a mutation survived. The first
version corrupted both parameters in one scenario, so the certificate's
check failed first and stood in for the key's: removing the key's
read-back entirely still passed.

## What these do not cover

A node on AWS doing any of this. The shims catch a missing flag or token,
but no instance boots, no KMS key decrypts anything, and nothing checks
that the node role's grant is enough. A replacement issuing its own
certificate on a real cluster is checklist item 10 in
[`docs/cloud-apply.md`](../../docs/cloud-apply.md), and it has not been
observed. The Terraform half — the parameters, the IAM grant, and the
user-data that embeds the script — is asserted in
`terraform/aws/tests`.
