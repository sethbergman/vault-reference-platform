# CLAUDE.md

Guidance for AI assistants working in this repository.

## What this is

A reference implementation of a self-managed, highly available HashiCorp
Vault deployment: Terraform provisions, Ansible configures and hardens,
Docker Compose stands up an equivalent cluster locally, and shell scripts
carry out the day-2 operations (bootstrap, rotation, snapshots, PKI, DR,
upgrades). There is no application code — the deliverable is
infrastructure, operational procedure, and the tests that keep both
honest.

Two consequences shape almost every decision here:

- **A quiet failure is the enemy.** Most of what this repository guards
  against is a green timer with no usable backup, a successful reload
  command with a stale certificate, three nodes that came up healthy as
  three separate single-node clusters. Comments throughout name the
  specific failure a piece of code exists to prevent; keep that habit.
- **"Shipped" means there is a test that fails if it breaks.** Code
  existing is not the bar. See `docs/roadmap.md`.

## Repository map

```text
terraform/
  aws/        VPC, ASG, NLB, KMS auto-unseal, versioned snapshot bucket
  azure/      VNet, VMSS, LB, Key Vault auto-unseal, blob container
  local/      Placeholder so fmt/validate has a target for every profile
  modules/    Provider-agnostic shape (cluster_name, node_count, tags)
ansible/
  playbooks/site.yml        vault, vault_hardening, vault_snapshots,
                            vault_pki, vault_audit — in that order
  roles/                    One role per concern; see "Ansible" below
  inventory/                local, aws.yml, azure.yml (dynamic, by tag)
  group_vars/*.example      Templates; the real files are generated
docker/
  vault/          Vault server image; entrypoint substitutes the
                  Transit token into vault.hcl at start
  vault-unseal/   Single Shamir-unsealed Vault providing Transit
                  auto-unseal for the dev cluster — the root of trust
  dev/            docker-compose.yml — every local/CI service
  dex/            OIDC identity provider for human-login tests
  vault-agent/    Agent rendering a secret to a file for an app
  audit-collector/  Socket audit sink; hash-chains entries (collect.sh)
                    and records chain heads (anchor.sh)
  alert-sink/     Records which Alertmanager receiver actually fired
  monitoring/     Prometheus, rules, Alertmanager, blackbox, Grafana
  mysql/          init SQL creating the account Vault connects as
scripts/          All operational scripts (see "Scripts" below)
tests/            17 suites; each is a self-contained run-tests.sh
examples/policies/  Least-privilege HCL policies used by scripts and CI
docs/             Runbooks and design notes — the operational half;
                  README.md is generated, see "Docs" below
diagrams/         architecture.md
```

## Common commands

`make` on its own prints every target, grouped. The ones worth knowing:

```bash
make deploy        # 3-node Raft cluster + monitoring
make deploy-full   # every optional service (superset of tests/integration)
make status        # compose ps, plus each node's seal and HA state
make destroy       # docker compose down -v

make test          # every suite that needs no cluster (seconds)
make test-suite SUITE=snapshot   # one suite
make test-cluster  # the integration suite against a real cluster
make dr-drill      # the restore drill

make lint          # every static check CI runs, and nothing weaker
make docs          # regenerate docs/README.md
```

`make test` changed meaning. It used to run the DR restore drill alone;
it now runs the shim suites, and the drill is `make dr-drill`. The narrow
version was surprising in the one way a `test` target should not be —
somebody who ran it and saw green had tested almost nothing.

Suites are discovered from `tests/*/run-tests.sh` rather than listed, so
a new one is picked up without editing the Makefile.
`make check-ci-coverage` fails if a suite exists that no CI job runs,
which is the gap this file warns about below.

`make test` is deliberately narrow. To run a test suite, call it
directly:

```bash
./tests/snapshot/run-tests.sh          # ~2s, shims, no cluster
./tests/integration/run-tests.sh       # minutes, real 3-node cluster
./tests/integration/run-tests.sh --keep-running
```

Bringing the cluster up with optional services:

```bash
./scripts/bootstrap-dev-cluster.sh --with-monitoring   # what make deploy runs
./scripts/bootstrap-dev-cluster.sh --nodes vault-0     # single node, CI
./scripts/bootstrap-dev-cluster.sh --with-oidc         # + Dex
./scripts/bootstrap-dev-cluster.sh --with-postgres     # + Postgres
./scripts/bootstrap-dev-cluster.sh --with-mysql        # + MySQL
./scripts/bootstrap-dev-cluster.sh --with-audit        # + audit collector
./scripts/bootstrap-dev-cluster.sh --with-agent        # + Vault Agent
```

This script is the single source of truth for standing the cluster up —
`make deploy` and every CI job call it, so neither can drift from what
the other exercises. A bare `docker compose up` will **not** produce a
working cluster: nothing mints the Transit token, initializes, or joins
peers.

Log output goes to stderr; the root token is the only thing on stdout,
so `ROOT_TOKEN=$(./scripts/bootstrap-dev-cluster.sh)` works. Preserve
that split when editing.

## The four profiles

| Profile | Provisioning | Seal | Proven by |
|---|---|---|---|
| local/CI | docker-compose | Vault Transit (`vault-unseal`) | integration suite, every PR |
| AWS | `terraform/aws` | AWS KMS | `terraform test` (mocked), plus an emulated apply — never a real account |
| Azure | `terraform/azure` | Azure Key Vault | `terraform test` with mocked providers only |
| bare/other | Ansible alone | Shamir (role default) | not exercised |

**Neither cloud profile has ever been applied to a real account.** Do
not describe them as working or proven. `docs/cloud-apply.md` lists
exactly what a first real apply would settle, per provider, and
`scripts/preflight-cloud.sh` / `scripts/teardown-cloud.sh` exist because
`terraform destroy` fails partway on both. These two applies are v1.0
blockers 1 and 2 in the README.

`tests/cloud-apply-emulated` narrows that gap for AWS only, and only so
far: it applies and destroys `terraform/aws` against an implementation
of the AWS API (moto), which settles that the profile applies in one
pass with every reference resolved and no value refused. An emulator
implements the API, not the service — nothing boots, no health check
runs, and KMS answers without performing cryptography — so a green run
is evidence the profile is *applyable*, never that the cluster works.
Keep that distinction in any sentence you write about it.

## How the pieces connect

**Local bootstrap order** — `vault-unseal` comes up first, is
Shamir-initialized and unsealed once, enables Transit, and mints an
orphan periodic token scoped to one key. That token is exported as
`VAULT_TRANSIT_TOKEN`, compose interpolates it into each node's
environment, and `docker/vault/docker-entrypoint.sh` substitutes it into
`vault.hcl`'s `seal "transit"` stanza before Vault starts. The first
node is then initialized and unseals itself; the rest join via
`retry_join` and are promoted to voters by autopilot.

**Terraform → Ansible handoff** — `scripts/terraform-to-ansible.sh`
generates `group_vars` from `terraform output -json`, so the KMS key id,
subscription id and scale set name cannot drift from what Terraform
built. `tests/ansible/` renders the *real* `vault.hcl.j2` with those
generated vars under `StrictUndefined`, against saved real `terraform
output -json` fixtures — so renaming an output on either side of the
seam fails there rather than producing a cluster that never forms.

**Node discovery** — `ansible/inventory/aws.yml` matches the same tag
that Raft's `auto_join` filters on (`terraform/aws/compute.tf`). One
tag, two consumers, deliberately: change it and both break together
instead of one drifting silently. Azure discovers peers through the
scale set instead, which is one of three mechanisms with no AWS
counterpart.

**TLS** — terminated at the Vault process, never at the load balancer,
which is why health checks must accept Vault's status codes (200 active,
429 standby, 472/473 DR/perf standby) rather than doing a TCP check.
Local TLS material is generated by `scripts/generate-dev-certs.sh` into
`docker/dev/tls/` (gitignored). Nothing may reach for `--insecure` or
`-tls-skip-verify`: verification that verifies nothing makes a TLS
rollout look finished when it isn't.

**PKI ordering** — Vault's own PKI cannot issue the certificates the
cluster needs in order to start. The bootstrap CA stays load-bearing
until every node has been re-issued; the `vault_pki` role does renewal
only, is off by default, and refuses to run on a node with no existing
certificate. `scripts/migrate-to-vault-pki.sh` sequences the switchover.

## Scripts

All of `scripts/*.sh` follow one shape. Match it when adding a script:

- `#!/usr/bin/env bash` and `set -euo pipefail`.
- A header comment block giving usage, examples, what it does step by
  step, requirements — and, where it matters, a "deliberate behaviours"
  section naming the failure each choice prevents.
- `usage()` prints the header back by `grep '^#' "$0" | sed ...`, so the
  header *is* the help text. Keep them in sync by keeping them the same
  thing.
- `log()` / `die()` helpers; `log` writes to stderr wherever the script
  has a real stdout value (a token, a secret_id) to emit.
- Long-form `--flag value` argument parsing in a `while`/`case` loop,
  then explicit required-argument checks and a `command -v` check for
  each external tool.
- Idempotent where the operation is configuration; separate scripts for
  anything that mints a credential (`bootstrap-approle.sh` configures,
  `rotate-secret-id.sh` issues).

Notable scripts: `bootstrap-dev-cluster.sh` (cluster up),
`bootstrap-{approle,jwt-github,oidc,audit,pki,agent,database-secrets}.sh`
(one auth or secrets path each), `rotate-secret-id.sh`, `snapshot.sh`,
`dr-drill.sh`, `vault-upgrade.sh`, `issue-node-cert.sh`,
`migrate-to-vault-pki.sh`, `verify-audit-chain.sh`,
`preflight-cloud.sh`, `teardown-cloud.sh`, `terraform-to-ansible.sh`,
`oidc-login-test.sh`, `generate-docs-index.sh`.

Two report-style scripts are a deliberate second shape:
`preflight-cloud.sh` and `verify-audit-chain.sh` have no `log()` at all.
They report a series of findings rather than narrate one operation, so
they use the test harnesses' idiom instead — `ok()`/`warn()`/`bad()` over
`PASS`/`WARN`/`FAIL` counters, with the exit status driven by the
counts. Match whichever shape fits what the script is for.

## Testing

Three tiers, and the distinctions are load-bearing.

**Shim suites** (`tests/*/fake-bin/`) put stand-ins for `vault`, `aws`,
`curl`, `ssh`, `openssl` ahead of the real tools on `PATH`, log every
invocation, and answer from `FAKE_*` scenario variables. They run in
seconds, need no credentials, and can reach failure modes a live cluster
will not reproduce on demand. They prove a script *issues* the commands
you expected — nothing more.

**The integration suite** (`tests/integration/`) stands up the real
three-node cluster and runs the operational scripts against it as host
processes. It exists because shims agree with bugs: its first run found
that snapshots had never been taken on any node, because the leadership
check read a field that does not exist in `vault status -format=json`
and the shim emitted that field too. When adding a shim, model the real
tool's output, not the output the script wants.

**The emulated apply** (`tests/cloud-apply-emulated/`) sits between the
two for the cloud profiles, where neither tier reaches: there is no
cluster to stand up without spending money, and a shim would have the
same blind spot as the mocks. It applies and destroys `terraform/aws`
through the real AWS provider against an implementation of the AWS API,
so every request is built, sent and answered. It proves the profile
applies; it proves nothing about what the profile would run.

Harness conventions, shared by most `run-tests.sh` and worth keeping
when adding one:

- `SCRIPT_DIR` / `REPO_ROOT` resolved from `BASH_SOURCE`; `WORK=$(mktemp
  -d)` with a `trap 'rm -rf "$WORK"' EXIT`.
- `PASS`/`FAIL` counters, `ok()`/`bad()` printing green/red, and an exit
  status driven by `FAIL`.
- In the shim suites, a `reset_scenario()` re-exporting every `FAKE_*`
  default between cases, so one test cannot silently satisfy the next.
  `FAKE_*` must be **exported** — the shims are grandchildren of the
  test shell, so a `VAR=x run_thing` prefix does not reach them.
- Named assertions, reused across suites: `assert_rc`, `assert_says`,
  `assert_log_has`, `assert_log_lacks`.

Two rules from `CONTRIBUTING.md`, both learned from assertions here that
passed while the thing they described was broken:

1. **Prefer pinning the value to naming what to exclude.**
   `assert_log_lacks "..." "aws s3 cp"` looks like it forbids uploading,
   but `aws s3api put-object` sails through. Widen to the shortest
   prefix covering every spelling (`aws s3`), or assert the positive form
   and pin the whole value. Where an exclusion must name output text,
   pair it with a positive assertion on the same string.
2. **Mutate with something the assertion does not name.** Breaking the
   code in exactly the way the test greps for proves nothing. Reject
   `CREATE, ALTER, DROP`, then verify by granting only `CREATE` — the
   neighbouring change a future contributor actually makes.

`terraform test` runs against mocked providers, so the same trap
applies there: **assert on config values and locals, never on a mocked
data source's output.** Two of the three cloud bugs found so far were
invisible to the mocks for exactly that reason, which is what
`tests/cloud-apply-emulated` and `tests/preflight-static` exist to
catch — the first by making every request real, the second by checking
across the Terraform/cloud-init/Ansible seam that no single tool sees.

`terraform/aws/tests/README.md` has the mutation table showing which
deliberate break each test catches, every row confirmed by watching it
fail; extend it when adding assertions.
`terraform/azure/tests/README.md` covers the Azure suite and the three
mechanisms with no AWS counterpart, and its mutation table is now
verified the same way — every row watched to fail. Verifying it the
first time broke five of the thirteen claims, including an assertion on
the Key Vault name limit that could not fail at all; that README says
what each was and what changed. The suite runs in about two seconds, so
re-run the table when you add an assertion rather than adding a row you
have not watched fail.

Per-suite requirements:

| Suite | Needs |
|---|---|
| agent, database, snapshot | bash, jq |
| audit | bash, jq, python3 |
| audit-chain | bash, sha256sum |
| docs-index | bash, awk, diff |
| cloud-preflight | bash |
| lint | bash, python3 |
| preflight-static | bash, python3; shellcheck if present |
| pki | bash, jq, openssl |
| pki-migration | bash, jq, python3, openssl |
| ansible | bash, jq, python3 with jinja2 + pyyaml |
| alert-routing | bash, python3 + PyYAML; Docker for the amtool cases |
| alerting | promtool (Prometheus distribution), python3 |
| upgrade | bash, curl, unzip, jq, sha256sum, python3 |
| integration | docker compose, vault CLI, jq, openssl, curl |
| cloud-apply-emulated | terraform, python3 with `moto[server]`, curl |

## CI

`.github/workflows/ci.yml` runs 27 jobs on every PR and on pushes to
`main`. Eight are static (`terraform` fmt/validate/test, `ansible-lint`
plus `--syntax-check`, `shellcheck`, `lint-invariants`,
`preflight-static`, `markdownlint`, `docs-index`, and `security-scan`
with gitleaks and Trivy); one (`emulated-apply`) applies the AWS profile
against an emulated API; the rest each run one suite from `tests/`, or
bring up the compose cluster and exercise it live (smoke test, AppRole
rotation, GitHub OIDC, human OIDC via Dex, DR drill, integration).

Adding a suite under `tests/` does **not** wire it into CI — add the job
too. Shellcheck, by contrast, discovers test scripts via `git ls-files`
rather than an enumerated list, so new harnesses are linted
automatically.

Versions are pinned on purpose (Terraform 1.15.9, Vault CLI 1.17.2,
Prometheus/promtool 2.54.1, Alertmanager 0.27.0, and the compose image
tags): a floating version makes failures hard to attribute and lets an
upstream outage redden `main`. Keep the CLI version in a job matching
the image version the compose profile runs.

CI enforces several invariants worth knowing before you push:

- **Every shell script must be executable** (`100755`), including
  `tests/*/fake-bin/*` shims, which deliberately have no `.sh` suffix
  because they must be named `vault`, `aws`, `curl` to be found on
  `PATH`. Fix with `git update-index --chmod=+x <path>`.
- **No trap handler may end in a bare conditional**
  (`tests/lint/check_trap_exit.py`). `cleanup() { [[ -n "$D" ]] && rm
  -rf "$D"; }` returns 1 when the test is false, and bash applies that
  to the script's exit status from an `EXIT` trap — a successful run
  reports failure, and an explicit `exit 0` does not save it.
- **Trivy findings at HIGH or above fail the build.** Accepted findings
  go in `.trivyignore.yaml` *with the reason* — an unjustified
  suppression is indistinguishable from never having run the scanner.
- **gitleaks scans full history** (`fetch-depth: 0`). A secret committed
  and later removed is still leaked.
- **Every alert rule needs a severity route of its own** and every
  freshness alert needs a paired `absent()` alert; the alerting and
  alert-routing suites fail if a new one arrives without its partner. A
  threshold alert on a metric nobody reports never fires.

### Watching a PR without burning the context window

27 jobs means any "list the check runs" call returns 27 records, which
makes it the most expensive question available about this repository.
Ask it when you need a per-job conclusion, and once.

- **A completion event has already answered it.** `check_suite.completed`
  says nothing on that head is still running or failed. Re-listing every
  run to confirm costs thousands of tokens to learn what woke you.
- **`get_status` is not the cheap version.** It reads the legacy commit
  status API, which nothing here writes to, so it returns
  `total_count: 0` and a permanent `pending` — indistinguishable at a
  glance from a job still running, and a reason to make the expensive
  call anyway. Two calls where none was needed.
- **A green, mergeable PR waiting on a human needs no polling.** The
  merge, a review, and a conflict from a moved base all arrive as
  events. A scheduled re-read is watching for the thing that would have
  woken you regardless. Schedule one only while something genuinely
  unobserved is in flight — an external job nothing reports back from —
  and match the interval to how fast that changes.

The general form: prefer the cheapest call that answers the question,
and do not re-verify what an event already told you. Context spent
re-reading state is context unavailable for the work.

## Conventions

**Shell** — bash with `set -euo pipefail`, shellcheck-clean under
`-s bash`. See "Scripts" above for the script shape.

**Terraform** — `terraform fmt -recursive` before committing; CI runs
`fmt -check`. `required_version >= 1.7`, providers pinned with `~>`.
`.terraform.lock.hcl` is committed deliberately (see `.gitignore`);
regenerate with `terraform providers lock`, never by hand — and pass
every platform, not just the one you are on:

```bash
PLATFORMS="-platform=linux_amd64 -platform=linux_arm64"
PLATFORMS="$PLATFORMS -platform=darwin_amd64 -platform=darwin_arm64"
PLATFORMS="$PLATFORMS -platform=windows_amd64"

# shellcheck disable=SC2086  # word splitting is the point here
terraform -chdir=terraform/aws   providers lock $PLATFORMS
terraform -chdir=terraform/azure providers lock $PLATFORMS
```

Not `windows_arm64`. Neither `hashicorp/aws` nor `hashicorp/random`
publishes a build for it, and asking for one fails the whole command:

```text
provider registry.terraform.io/hashicorp/aws 5.100.0 is not available
for windows_arm64
```

Which is why a Windows-on-ARM machine runs Terraform inside WSL and locks
`linux_arm64` instead. Adding a platform to that list is a claim the
registry has to agree with.

The registry `zh:` hashes cover every published platform, so `init`
succeeds anywhere regardless. What it then does is append an `h1:` hash
for whichever platform you are on, leaving the lock file modified in
`git status` — which reads as "I broke something" to whoever hits it, and
is most likely on an architecture nobody has developed on before. CI runs
`linux_amd64` only, so it will never surface there. Locking every
platform up front costs one line each and removes the surprise. New cloud
providers go under `terraform/<provider>/` and consume
`terraform/modules/vault-cluster` rather than duplicating its variables;
the shared module defines shape only and creates no cloud resources.
Provider-specific concerns are split by file rather than piled into
`main.tf` — `terraform/aws` is the fullest example (`network.tf`,
`compute.tf`, `security.tf`, `storage.tf`, `iam.tf`, `lb.tf`). Split by
what a provider actually has, not by that list: Azure has no `iam.tf`
or `security.tf` because it expresses neither concern separately.

**Ansible** — must pass `ansible-lint` cleanly; `# noqa` only with a
comment explaining why. Roles are off by default when enabling them
changes a cluster's availability or trust characteristics
(`vault_audit_enabled`, `vault_pki_enabled`, `vault_snapshots_enabled`
all default to `false`, and the defaults files explain why at length).
Role defaults are documented in prose in `defaults/main.yml` — that file
is the reference, so extend it rather than adding a separate note. New
inventory for a provider goes under `ansible/inventory/<provider>`.

**Markdown** — `markdownlint-cli2` runs over `**/*.md`, including this
file. Wrap prose at 80 columns; tables are exempt (`MD013: tables:
false`) and use the compact delimiter (`|---|---|`, `MD060` disabled
deliberately — see `.markdownlint.yaml`). Fenced blocks need a language.

**Docs** — every feature has a `docs/*.md` that states the tradeoff, not
just the procedure, and says plainly what is *not* proven. That is the
house voice; match it. Prefer amending the existing doc for a topic over
adding a new one.

`docs/README.md` is **generated** from each document's own H1 and H2
headings by `scripts/generate-docs-index.sh`. Do not edit it by hand —
run `make docs` after adding, renaming or re-sectioning a document, or
CI's `docs-index` job fails on the diff. The reason it is derived rather
than written is the reason this file no longer carries an index of its
own: a hand-maintained index stops covering each new document silently,
and the omission is invisible to everyone except the reader who needed
that document.

**Commits** — one logical change per commit, with a message explaining
the *why*; the diff already shows the what. Subject lines here are
imperative and specific ("Stop two cleanup handlers from turning success
into failure", "Quote MySQL identifiers, and name the second place the
engines differ"). Do not use a `type:` prefix. Branch names do use one
(`fix/`, `docs/`, `test/`).

## Project state and gaps

`docs/roadmap.md` is the authority on what is done and what "not"
means; the README's Roadmap section lists the five things standing
between here and v1.0:

1. A real AWS apply.
2. A real Azure apply — a separate item, because Azure's peer discovery,
   health probe and instance reconciliation have no AWS counterpart.
3. Off-host audit shipping. The trail is now hash-chained and anchored
   where the collector cannot write, but both volumes still sit on one
   Docker daemon — tamper *evidence*, not tamper proofing.
4. Terraform state that survives a team. No profile declares a
   `backend`, so state is local and unlocked. CI's `-backend=false` is
   what keeps `validate` runnable without credentials; do not regress it
   while adding one.
5. An upgrade path matching how the profiles deploy. `vault-upgrade.sh`
   is leader-aware SSH; the cloud profiles replace nodes through ASG
   instance refresh and a manual-upgrade scale set, which are not.

Items 4 and 5 were added after the first three and are about operating a
cluster over time, so neither is reachable by `tests/cloud-apply-emulated`.
`docs/roadmap.md` also carries an "After v1.0: production operations"
list — cloud monitoring, the root token after bootstrap, seal migration
and key rotation, quorum-loss recovery, and restore verification at the
cloud destination. Those are deferred deliberately, not forgotten.

When touching any of these, keep the documentation's precision about
what is proven versus what is merely configured. Overstating it is the
one change that would make this repository less useful than saying
nothing.

## Where to read next

`docs/README.md` is the index — generated, so it always covers every
document and lists the sections each one actually contains. Four
starting points, because they are the ones that change what you write
rather than only what you know:

| Question | Read |
|---|---|
| What is proven versus merely configured? | `docs/roadmap.md` |
| What would a first cloud apply settle? | `docs/cloud-apply.md` |
| Why is TLS terminated where it is, and PKI ordered as it is? | `docs/security.md` |
| Something is broken and I need the first step | `docs/troubleshooting.md` |
