# Vault Reference Platform

A reference implementation for deploying and operating a highly available
[HashiCorp Vault](https://www.vaultproject.io/) cluster using Infrastructure
as Code and standard platform-engineering practices.

## Overview

This project packages a self-managed Vault deployment — Terraform for
provisioning, Ansible for configuration and hardening, Docker for local
development, and CI checks to keep it all honest — into something that can
be stood up repeatably instead of hand-built once and forgotten.

## Why this exists

Most public Vault examples stop at "here's a `vault server -dev` command."
Running Vault in production means dealing with unsealing, storage backends,
TLS, access policies, backups, and upgrades — the operational half of the
job that rarely makes it into a README. This repo is an attempt to write
that part down.

## Design goals

- **Reproducible** — the local profile stands up a real 3-node,
  auto-unsealed Raft cluster from a clean checkout with one command
  (`make deploy`). `terraform/aws` builds the equivalent on AWS —
  network, autoscaling group, load balancer, KMS auto-unseal, snapshot
  bucket. Azure is still a stub; see Roadmap.
- **HA by default** — the reference topology is a multi-node Raft cluster
  behind a load balancer from the start, not bolted on as a "v2" feature.
- **Operable, not just deployable** — runbooks and disaster-recovery
  procedures are first-class, not an afterthought.
- **Cloud-agnostic core** — Terraform modules are structured so the Vault
  and Ansible layers don't care whether the nodes came from AWS, Azure, or
  a local Docker Compose stack.

## Architecture

This is the topology `make deploy` actually stands up (local/CI). The AWS
profile builds the same shape with a load balancer and KMS auto-unseal in
front of it — see [`diagrams/architecture.md`](diagrams/architecture.md)
and [`docs/deployment.md`](docs/deployment.md):

```text
            vault CLI / apps
                    │
    ┌───────────────┬───────────────┐
    │               │               │
 vault-0         vault-1         vault-2
(leader)       (follower)      (follower)
    │               │               │
    └───────────────┴───────────────┘
                    │
              Raft cluster
                    │
           Transit auto-unseal
                    │
              vault-unseal
         (Shamir-unsealed once —
           the root of trust)
```

## Repository structure

```text
vault-reference-platform/
├── terraform/
│   ├── aws/        # AWS: VPC, ASG, NLB, KMS, snapshot bucket
│   ├── azure/      # Azure: VNet, VMSS, LB, Key Vault, snapshots
│   ├── local/       # Local/Docker provider for dev + CI
│   └── modules/     # Shared, provider-agnostic modules
├── ansible/
│   ├── playbooks/
│   ├── roles/
│   └── inventory/
├── docker/
│   ├── vault/         # Vault server image + config
│   ├── vault-unseal/  # Transit auto-unseal backend for the dev cluster
│   ├── dex/           # OIDC identity provider for human login
│   ├── monitoring/    # Prometheus + Grafana config
│   ├── tooling/       # CLI/dev tooling image
│   └── dev/           # docker-compose for local dev
├── scripts/           # bootstrap, auth setup, rotation, DR drill
├── examples/          # example least-privilege policies
├── docs/              # runbooks and guides
├── diagrams/
├── .github/workflows/
├── Makefile
├── LICENSE
└── CONTRIBUTING.md
```

## Quick start

```bash
git clone https://github.com/sethbergman/vault-reference-platform.git
cd vault-reference-platform
make deploy   # 3-node Raft cluster, auto-unsealed, via Docker Compose
```

See [`docs/deployment.md`](docs/deployment.md) for cloud deployment via
Terraform + Ansible.

## Security

See [`docs/security.md`](docs/security.md) for the threat model, auto-unseal
approach, TLS handling, and policy structure.

## Auto-unseal

See [`docs/auto-unseal.md`](docs/auto-unseal.md) for how each profile
auto-unseals — Vault Transit locally/in CI, AWS KMS or Azure Key Vault in
the cloud profiles.

## Human authentication

See [`docs/human-authentication.md`](docs/human-authentication.md) for
OIDC login, with identity-provider groups mapped to Vault policies —
access is granted and revoked in the IdP, not per-person in Vault.

## CI authentication

See [`docs/ci-authentication.md`](docs/ci-authentication.md) for letting
GitHub Actions authenticate via OIDC — short-lived tokens minted per job,
no stored credential to leak or rotate.

## Secret rotation

See [`docs/secret-rotation.md`](docs/secret-rotation.md) for bootstrapping
AppRole roles and rotating `secret_id`s on a recurring cadence via
`scripts/bootstrap-approle.sh` and `scripts/rotate-secret-id.sh` — the
path for workloads that can't use OIDC.

## Disaster recovery

See [`docs/disaster-recovery.md`](docs/disaster-recovery.md) for backup and
restore procedures. `make test` runs the restore drill end to end — take a
snapshot, destroy the node and its storage, restore, verify the data came
back — and CI runs it on every PR, so the procedure can't rot unnoticed.

## Operations

See [`docs/operations.md`](docs/operations.md) for day-2 runbooks: health
checks, upgrades, capacity planning, and common incident response steps.

## CI/CD

GitHub Actions runs eleven checks on every PR. Five are static:
`terraform fmt`/`validate`/`test`, `ansible-lint`, `shellcheck`,
`markdownlint`, and security scanning (gitleaks for committed secrets,
Trivy for Terraform and Dockerfile misconfigurations — see
[`docs/security.md`](docs/security.md)). The other six deploy the Docker
Compose cluster and actually exercise it:

- **Deploy + smoke test** — auto-unseals the full 3-node Raft cluster and
  does a live secret write/read.
- **AppRole rotation** — issues a `secret_id`, uses it, rotates it, and
  confirms the old one is rejected.
- **GitHub Actions OIDC** — logs in with a real GitHub-minted OIDC token,
  then confirms a role bound to a different repository rejects that same
  token and that the read-only policy denies writes.
- **Human OIDC** — runs a full browser-style login against a real OIDC
  provider, then confirms a developer and an operator get genuinely
  different access and that a wrong password fails.
- **DR restore drill** — snapshots a cluster, destroys the node and its
  storage, restores into a replacement, and verifies a secret written
  before the disaster reads back.
- **Rolling upgrade tests** — proves a bad checksum aborts before any
  node is touched, and that an unhealthy node stops the rollout rather
  than costing a second node and quorum.

See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Roadmap

- **v0.1** — local Docker Compose deployment, base Terraform + docs (done)
- **v0.2** — HA cluster (done), auto-unseal (done), monitoring (done)
- **v0.3** — automated tests (done), CI security scanning (done)
- **v1.0** — production-ready reference architecture

## License

MIT — see [`LICENSE`](LICENSE).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).
