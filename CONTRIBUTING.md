# Contributing

Issues and PRs are welcome.

## Development

- Run `make lint` before opening a PR — it runs the same checks as CI.
- Terraform changes: run `terraform fmt -recursive` first.
- New Ansible tasks should pass `ansible-lint` cleanly; use `# noqa` sparingly
  and only with a comment explaining why.

## Commit style

Keep commits scoped to one logical change, with a message that explains the
*why*, not just the *what* — the diff already shows the what.

## Adding a new cloud provider

New providers should live under `terraform/<provider>/` and consume the
shared `terraform/modules/vault-cluster` module rather than duplicating its
variables. Corresponding Ansible inventory goes under `ansible/inventory/<provider>`.
