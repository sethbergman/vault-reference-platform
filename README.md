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
  (`make deploy`). The AWS/Azure profiles aren't there yet — see Roadmap.
- **HA by default** — the reference topology is a multi-node Raft cluster
  from the start, not bolted on as a "v2" feature. A load balancer in
  front of it is still a `TODO` in `terraform/aws` and `terraform/azure`.
- **Operable, not just deployable** — runbooks and disaster-recovery
  procedures are first-class, not an afterthought.
- **Cloud-agnostic core** — Terraform modules are structured so the Vault
  and Ansible layers don't care whether the nodes came from AWS, Azure, or
  a local Docker Compose stack.

## Architecture

See [`diagrams/architecture.md`](diagrams/architecture.md) for the full
diagram. At a high level:

```text
                Users
                  │
           Load Balancer
                  │
      ┌───────────┴───────────┐
      │                       │
 Vault Node 1            Vault Node 2
      │                       │
      └───────────┬───────────┘
                  │
             Raft Storage
                  │
        Snapshot / Backup
```

## Repository structure

```text
vault-reference-platform/
├── terraform/
│   ├── aws/        # AWS provider implementation
│   ├── azure/      # Azure provider implementation
│   ├── local/       # Local/Docker provider for dev + CI
│   └── modules/     # Shared, provider-agnostic modules
├── ansible/
│   ├── playbooks/
│   ├── roles/
│   └── inventory/
├── docker/
│   ├── vault/         # Vault server image + config
│   ├── vault-unseal/  # Transit auto-unseal backend for the dev cluster
│   ├── tooling/       # CLI/dev tooling image
│   └── dev/           # docker-compose for local dev
├── scripts/
├── examples/
├── docs/
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

## Secret rotation

See [`docs/secret-rotation.md`](docs/secret-rotation.md) for bootstrapping
AppRole roles and rotating `secret_id`s on a recurring cadence via
`scripts/bootstrap-approle.sh` and `scripts/rotate-secret-id.sh`.

## Disaster recovery

See [`docs/disaster-recovery.md`](docs/disaster-recovery.md) for backup and
restore procedures.

## Operations

See [`docs/operations.md`](docs/operations.md) for day-2 runbooks: health
checks, upgrades, capacity planning, and common incident response steps.

## CI/CD

GitHub Actions runs six checks on every PR: `terraform fmt`/`validate`,
`ansible-lint`, `shellcheck`, and `markdownlint`, plus two jobs that
actually deploy the Docker Compose cluster and exercise it — one brings
up and auto-unseals the full 3-node Raft cluster and does a live
secret write/read, the other bootstraps an AppRole and proves
`secret_id` rotation end to end (issue, use, rotate, confirm the old
one is rejected). See
[`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Roadmap

- **v0.1** — local Docker Compose deployment, base Terraform + docs (done)
- **v0.2** — HA cluster (done), auto-unseal (done), monitoring (open)
- **v0.3** — CI security scanning, automated tests
- **v1.0** — production-ready reference architecture

## License

MIT — see [`LICENSE`](LICENSE).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).
