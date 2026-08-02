# Local provider

The local/dev profile is driven primarily by `docker/dev/docker-compose.yml`
rather than Terraform. This directory exists so `terraform fmt`/`validate`
CI checks have a consistent target across all three profiles, and as a
place to grow local provisioning (e.g. `docker` Terraform provider) if
useful later.
