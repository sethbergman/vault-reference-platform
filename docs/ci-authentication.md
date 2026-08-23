# CI authentication (GitHub Actions OIDC)

CI pipelines need to read secrets from Vault, which raises an awkward
question: how does the pipeline authenticate without a secret of its own?
Storing a Vault credential in GitHub secrets to fetch other credentials
from Vault just moves the problem.

GitHub Actions OIDC removes the credential entirely. GitHub mints a
short-lived, signed JWT for each job; Vault verifies the signature against
GitHub's published keys and issues a Vault token in exchange. Nothing is
stored, so nothing can leak and nothing needs rotating.

## Versus AppRole

Both are supported here — they solve different problems.

| | AppRole | GitHub Actions OIDC |
|---|---|---|
| Credential | `secret_id`, long-lived | JWT minted per job, expires in minutes |
| Storage | Must be delivered and stored somewhere | Never stored |
| Rotation | Required on a cadence (`rotate-secret-id.sh`) | Nothing to rotate |
| Works for | Any workload | Workloads on an OIDC-capable platform |

Use OIDC when the platform supports it. Use AppRole
([`docs/secret-rotation.md`](secret-rotation.md)) for everything else —
VMs, on-prem runners, anything without a trustworthy token issuer.

## Setup

```bash
export VAULT_ADDR=https://vault.internal:8200
export VAULT_TOKEN=<token that can write sys/policies, sys/auth, auth/jwt/*>

./scripts/bootstrap-jwt-github.sh \
  --role github-ci \
  --policy-file examples/policies/ci-readonly.hcl \
  --repository your-org/your-repo \
  --bound-ref refs/heads/main
```

This enables the JWT auth method, points it at GitHub's OIDC discovery
endpoint, and creates a role that only accepts tokens from the repository
you named.

| Flag | Default | Description |
|---|---|---|
| `--role` | *(required)* | Vault role name |
| `--policy-file` | *(required)* | Policy the role grants |
| `--repository` | *(required)* | `owner/repo` allowed to authenticate |
| `--bound-ref` | *(any ref)* | Restrict further to one branch/tag, e.g. `refs/heads/main` |
| `--audience` | `vault` | Must match the `audience` the workflow requests |
| `--token-ttl` | `15m` | TTL of issued Vault tokens |
| `--token-max-ttl` | `30m` | Max TTL including renewals |

Vault must be able to reach `https://token.actions.githubusercontent.com`
to fetch GitHub's signing keys. It refreshes them automatically, so
GitHub rotating its keys needs no action here.

## Bound claims are the security boundary

This is the part worth getting right. A valid signature only proves
*GitHub* issued the token — not that it was issued to **you**. Every
GitHub Actions job on the platform gets a legitimately signed token.

Without `--repository`, any repository on GitHub could authenticate to
your role. The bound claim is what makes the role yours. Bind as tightly
as the workflow allows:

- `--repository` — the minimum. Always set it.
- `--bound-ref` — add it when only one branch should have access, e.g. a
  role that can read production secrets should be bound to
  `refs/heads/main` so a branch can't reach them.

CI covers this: `jwt-github-oidc-test` in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) creates a
second role bound to a *different* repository and asserts the same token
is rejected by it. If bound claims ever silently stopped being enforced,
that test fails.

## Using it in a workflow

The job needs `id-token: write`, which is not granted by default:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - name: Authenticate to Vault
        run: |
          JWT=$(curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=vault" | jq -r '.value')
          VAULT_TOKEN=$(vault write -field=token auth/jwt/login \
            role=github-ci jwt="$JWT")
          echo "::add-mask::$VAULT_TOKEN"
          echo "VAULT_TOKEN=$VAULT_TOKEN" >> "$GITHUB_ENV"
```

The `audience` in the request must match `--audience` on the role, or
Vault rejects the login.

## Troubleshooting

- **`invalid audience`** — the workflow's `audience=` doesn't match the
  role's `bound_audiences`.
- **`claim "repository" does not match`** — the role is bound to a
  different repo than the one running the workflow. The CI job prints the
  token's decoded claims before login, which is usually the fastest way
  to see what Vault is actually comparing.
- **`ACTIONS_ID_TOKEN_REQUEST_URL: unbound variable`** — the job is
  missing `permissions: id-token: write`.
- **Fork pull requests can't authenticate** — GitHub never grants
  `id-token: write` to fork PRs. That's deliberate on GitHub's part, and
  it means fork contributors can't reach your secrets.
- **`error fetching public keys`** — Vault can't reach
  `token.actions.githubusercontent.com`; check egress rules.
