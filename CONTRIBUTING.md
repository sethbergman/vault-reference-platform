# Contributing

Issues and PRs are welcome.

## Development

- Run `make lint` before opening a PR — it runs the same checks as CI.
- Terraform changes: run `terraform fmt -recursive` first.
- Adding, renaming or re-sectioning a document under `docs/`: run
  `make docs`. `docs/README.md` is generated from the H1 and H2 headings
  of that directory, and CI fails when it is stale rather than letting
  the index quietly describe documents as something they no longer are.
- New Ansible tasks should pass `ansible-lint` cleanly; use `# noqa` sparingly
  and only with a comment explaining why.

## Writing tests

Three habits, all learned from assertions in this repository that passed
while the thing they described was broken.

**Prefer pinning the value to naming what to exclude.** An assertion of
the form "the output must not contain X" is only as strong as the
spelling its author thought of. `assert_log_lacks "... " "aws s3 cp"`
looks like it forbids uploading, but an upload via `aws s3api put-object`
sails through it. Either widen to the shortest prefix covering every way
of doing the same thing (`aws s3`), or assert the positive form and pin
the whole value — any change then breaks the match, whichever change it
is.

Where an exclusion has to name output text rather than a command, pair it
with a positive assertion on the same string. If the wording drifts, the
positive fails loudly instead of the exclusion quietly passing on a
phrase nothing prints any more.

**Mutate with something the assertion does not name.** Breaking the code
and watching a test fail proves nothing if the break was chosen to match
what the test greps for. That is self-fulfilling, and it is easy to do by
accident: write an assertion rejecting `CREATE, ALTER, DROP`, then
"verify" it by granting exactly `CREATE, ALTER, DROP`. The useful
mutation is the neighbouring one the assertion never mentions — granting
only `CREATE` — because that is the change a future contributor actually
makes.

**Check that the assertion has a reachable failure.** Some cannot fail at
all, and they look exactly like the ones that can. Two shapes have turned
up here so far:

- *It restates the code's arithmetic instead of reading it.* An assertion
  that a Key Vault name fits Azure's 24-character limit re-derived
  `substr(cluster_name, 0, 15)` in the test file and asserted
  `15 + 1 + 8 <= 24`. `substr` caps its result, so that held whatever the
  module did — widening the module's own budget to 20 left it green. If a
  test recomputes what the code computes, it is testing the arithmetic,
  not the code. Expose the value as a local or an output and read it.
- *It sits on a bound something else already enforces.* Asserting
  `soft_delete_retention_days >= 7` cannot fail, because the azurerm
  provider refuses anything outside 7-90 before the assertion runs.
  Provider schemas, platform floors and variable validations all do this.
  An assertion has to sit above the enforced bound to mean anything.

The mutation tables in `terraform/*/tests/README.md` exist for this: a
row is added only after the mutation has been applied and the named run
watched to fail. A table of rows nobody has run is worse than no table,
because it reads as evidence. The Azure table was written that way, and
six assertions did not survive the first run of it.

## Commit style

Keep commits scoped to one logical change, with a message that explains the
*why*, not just the *what* — the diff already shows the what.

## Adding a new cloud provider

New providers should live under `terraform/<provider>/` and consume the
shared `terraform/modules/vault-cluster` module rather than duplicating its
variables. Corresponding Ansible inventory goes under `ansible/inventory/<provider>`.
