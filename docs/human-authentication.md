# Human authentication (OIDC)

People should not be handed Vault tokens. Tokens get pasted into shell
histories and chat threads, they outlive the person's need for them, and
revoking one means knowing it exists. OIDC pushes that problem to the
identity provider that already governs employment: someone logs in with
the company account they already have, and what they can do in Vault
follows from their group membership there.

The practical consequence is the one that matters on an offboarding day:
removing someone from a group in the IdP removes their Vault access. No
Vault-side cleanup, nothing to remember.

## Trying it locally

The local profile runs [Dex](https://dexidp.io/), a small OIDC provider,
standing in for Okta / Entra ID / Google Workspace. It's a real provider
running the real protocol — not a mock — so the flow exercised here is
the flow a production deployment runs.

One-time host setup:

```bash
echo "127.0.0.1 dex" | sudo tee -a /etc/hosts
```

See [Why /etc/hosts](#why-etchosts) below — it isn't optional.

```bash
./scripts/bootstrap-dev-cluster.sh --nodes vault-0 --with-oidc
```

Then configure the auth method and the group mapping:

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=$PWD/docker/dev/tls/ca.crt
export VAULT_TOKEN=<root token printed by the bootstrap script>

./scripts/bootstrap-oidc.sh \
  --discovery-url http://dex:5556/dex \
  --client-id vault \
  --client-secret vault-dev-client-secret \
  --group vault-developers:examples/policies/developer.hcl \
  --group vault-operators:examples/policies/operator.hcl
```

And log in as a human would:

```bash
vault login -method=oidc role=default
```

That opens a browser to Dex. Two accounts exist, both with password
`password`:

| Account | Group | Gets |
|---|---|---|
| `developer@example.com` | `vault-developers` | Read/write on `secret/app/*` |
| `operator@example.com` | `vault-operators` | Cluster operations, no secret reads |

Log in as each and compare `vault token lookup`. They are deliberately
disjoint — an operator can take a snapshot but cannot read a single
application secret, because running Vault shouldn't require access to
what's inside it.

## Groups do not map themselves

This is the part that silently doesn't work if you skip it.

Vault does not read policies out of a token's group claim. The claim
carries a group *name* from the IdP; Vault has to be told what that name
means. That mapping is an **external identity group** plus a **group
alias**:

```text
  IdP group name          group alias            identity group
  "vault-developers"  ──────────────────────►  (policies attached)
                       on the oidc/ mount
```

`bootstrap-oidc.sh --group` does all three steps (write policy, create
external group, create alias). Without the alias, **login still
succeeds** — the user just gets the `default` policy and can't do
anything. That reads like a broken login but is actually unmapped
groups, and it's worth recognising because the error message never
mentions groups.

To check a mapping:

```bash
vault read identity/group/name/vault-developers
vault list identity/group-alias/id
```

## Where the policies show up

Policies granted through a group appear under `identity_policies`, not
`policies`:

```console
$ vault token lookup -format=json | jq '.data | {policies, identity_policies}'
{
  "policies": ["default"],
  "identity_policies": ["vault-developers"]
}
```

`policies` holds only what's attached to the token itself. Looking at
`policies` alone makes a correctly-mapped login look like it granted
nothing.

## Why /etc/hosts

An OIDC issuer is a single URL that has to be reachable, and identical,
from two different places:

- **Vault**, which fetches discovery and validates that the token's
  issuer matches — from inside the Docker network.
- **The browser**, which gets redirected to it — from the host.

`localhost` doesn't satisfy both: inside the Vault container it means
the container. Docker Compose resolves `dex` on its internal network,
so mapping `dex` to `127.0.0.1` on the host makes one name work from
both sides, via the published port.

Production doesn't have this problem — the IdP has a real DNS name
reachable from everywhere.

## Pointing at a real identity provider

Only the arguments change:

```bash
./scripts/bootstrap-oidc.sh \
  --discovery-url https://your-org.okta.com \
  --client-id <from the IdP> \
  --client-secret <from the IdP> \
  --group engineering:examples/policies/developer.hcl \
  --group sre:examples/policies/operator.hcl
```

Things to line up on the IdP side:

- Register Vault as an OIDC application, with redirect URIs
  `http://localhost:8250/oidc/callback` (CLI) and
  `https://<vault>/ui/vault/auth/oidc/oidc/callback` (web UI).
- Make sure the provider actually **emits a groups claim**. Several
  don't by default — Okta needs a groups claim added to the token, Entra
  needs group claims enabled, and Google Workspace doesn't emit groups
  at all without extra work. If the claim isn't there, Vault fails the
  login with `failed to fetch groups`.
- Use `--groups-claim` if the provider names it something other than
  `groups`.

## CI coverage

`human-oidc-test` in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs the whole
flow headlessly against Dex on every PR, using
`scripts/oidc-login-test.sh` to drive the redirects that a browser
normally handles. It asserts more than "login worked":

- the developer's token actually carries `vault-developers`
- a developer **cannot** take a raft snapshot
- an operator gets the mirror image, and **cannot** read app secrets
- a wrong password is rejected

`oidc-login-test.sh` is a testing aid, not a login path. It only works
against a plain username/password form; against a real IdP with MFA it
won't work, and shouldn't.

## Troubleshooting

- **`failed to fetch groups: "groups" claim not found in token`** — the
  IdP isn't emitting groups. Locally this means a Dex older than
  v2.45.0, where `staticPasswords` silently ignores its `groups` field.
- **Login works but nothing is permitted** — group alias missing or the
  name doesn't match the IdP's exactly. Check `identity_policies`, not
  `policies`.
- **`redirect_uri is not allowed`** — the URI must be listed both on the
  Vault role (`allowed_redirect_uris`) and on the IdP's client.
- **Issuer mismatch / discovery failures locally** — the `/etc/hosts`
  entry above is missing.
