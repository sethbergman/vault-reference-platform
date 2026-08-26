# Contributing

Issues and PRs are welcome.

## Development

- Run `make lint` before opening a PR — it runs the same checks as CI.
- Terraform changes: run `terraform fmt -recursive` first.
- New Ansible tasks should pass `ansible-lint` cleanly; use `# noqa` sparingly
  and only with a comment explaining why.

## Writing tests

Two habits, both learned from assertions in this repository that passed
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

## Commit style

Keep commits scoped to one logical change, with a message that explains the
*why*, not just the *what* — the diff already shows the what.

## Adding a new cloud provider

New providers should live under `terraform/<provider>/` and consume the
shared `terraform/modules/vault-cluster` module rather than duplicating its
variables. Corresponding Ansible inventory goes under `ansible/inventory/<provider>`.
