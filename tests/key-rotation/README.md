# tests/key-rotation

Rotating the barrier key, and re-issuing both kinds of key share —
the cluster's recovery keys and `vault-unseal`'s unseal keys.

```bash
./tests/key-rotation/run-tests.sh
./tests/key-rotation/run-tests.sh --keep-running
```

Needs `docker compose`, the `vault` CLI and `jq`. Runs against a real
three-node cluster and takes a few minutes.

## Why a real cluster

Both operations are ones a shim would agree with. A stand-in `vault` can
return whatever the script hopes for, and the question here is whether
the shares Vault issued actually replaced the ones it had. Only Vault can
answer that, so the suite asks it the only way that means anything: by
requiring the superseded shares to stop working.

## Three things, not two

| | |
|---|---|
| The barrier key | Online, no shares, cannot lock anyone out |
| Recovery keys | The cluster's, because it is auto-unsealed |
| Unseal keys | `vault-unseal`'s, because it is Shamir-sealed |

The last two are the same ceremony against different endpoints —
`sys/rekey-recovery-key` and `sys/rekey` — and which kind a Vault has
depends only on how it is sealed. `scripts/migrate-seal.sh` turns each
into the other without changing their values.

## The two halves are not the same risk

**The barrier key** is online, needs no shares and cannot lock anyone
out. The fear that stops people rotating it is that existing data becomes
unreadable, so the suite writes a secret, rotates, and reads it back —
previous key versions stay in the keyring, and that is what makes it
safe.

**The recovery shares** are the other one. When a rekey completes the old
shares are dead, and if the new ones were not captured, nobody can
generate a root token again — discovered in the emergency where you
needed them.

## The root of trust keeps its own key now

`vault-unseal` holds the Transit key every cluster node auto-unseals
against, and its unseal key used to live in a shell variable inside
`bootstrap-dev-cluster.sh` and nowhere else. A single
`docker compose restart vault-unseal` was therefore unrecoverable — and
that is what a Docker Desktop restart or a host reboot does.

The failure is not graceful. `vault-unseal` comes back sealed, and a
cluster node restarted afterwards does not come back sealed; it fails to
start, with `error parsing Seal configuration: ... 503 Vault is sealed`,
and no key anywhere to fix it.

This suite restarts `vault-unseal` on every run and requires that the
kept keys open it, and that a cluster node auto-unseals against it
afterwards. It is also what makes the Shamir rekey testable: rekeying
needs a quorum of the current shares, and before this there were none.

## One stale share proves nothing

The suite rekeys `vault-unseal` **twice** — 1-of-1 to 5-of-3, then again
— so that a full quorum of the superseded generation exists to try.

That is not thoroughness for its own sake. Vault accepts unseal shares
and only validates the combination once the threshold is reached, so
submitting a single stale share returns success and 1/3 progress. An
assertion built on one old share would pass whether or not the rekey did
anything, and would also leave that progress behind to break the next
unseal.

## What a green run does not mean

Seal migration is not covered here. Moving a cluster between seal types
with `-migrate` is the operation most likely to produce a cluster that
will not unseal, and it has a suite of its own in
`tests/seal-migration`.

The Shamir path this suite does exercise is `vault-unseal`'s, which is
a single node. A rekey of a Shamir-sealed *cluster* — several nodes,
each needing the new shares before any of them can start — is not
covered by anything here.

## Three things Vault does that a script has to know

All three were found by running it, not by reading the docs.

| | What happens |
|---|---|
| `keys_base64` | The new shares come back under that name. `operator init` calls the same thing `recovery_keys_b64`. Read the wrong one and you get an empty array from a rekey that reported success |
| The last verify prints English | Shares before the threshold return JSON progress; the one that completes ignores `-format=json` and prints `Rekey verification successful...` |
| `require_verification` is API-only | `vault operator rekey` has `-verify` for the second phase and no flag to require it at init, so the safe form of the ceremony is unreachable from the CLI |

The second one destroyed a keyset here. A loop watching `.complete` never
sees completion, submits another share, and gets `no rekey configuration
found` — an error that means the operation succeeded. The first version
of `rotate-keys.sh` read that as failure and discarded the new shares
while the rekey had already taken effect.

That is why the new shares are now written to `<keys-file>.new` **before**
verification rather than held in memory until after it: everything after
the shares are issued can fail, and none of it may lose them.

## Mutation table

Every row was watched to fail.

| # | Mutation | Caught by |
|---|---|---|
| K1 | The pre-verification copy is deleted the moment it is written | rotate-keys.sh --recovery-keys succeeds; the shares in the keys file changed; and the new shares can |
| K2 | Only a JSON `.complete` counts as verified — the bug above, restored | and verified the new shares before committing them; and the new shares can; the previous shares were kept alongside (8 in total) |
| K3 | New shares read from `keys_b64` instead of `keys_base64` | rotate-keys.sh --recovery-keys succeeds; the shares in the keys file changed |
| K4 | Verification is never requested at init | and verified the new shares before committing them; the shares in the keys file changed |
| U1 | `vault-unseal`'s keys are not kept, as before this release | the bootstrap kept vault-unseal's own keys; and the kept keys open it again |
| U2 | `--unseal-keys` addresses the recovery endpoint | rotate-keys.sh --unseal-keys rekeys 1-of-1 to 5-of-3 (5 in total) |
| U3 | Unseal mode reads `recovery_keys_b64` | rotate-keys.sh --unseal-keys rekeys 1-of-1 to 5-of-3 (5 in total) |

K2 is the one worth reading. It breaks nothing in the code the assertions
name — the rekey still runs, Vault still accepts every share, the cluster
stays healthy — and it takes eight assertions with it, because the shares
the operator is left holding are not the shares the cluster now wants.
That is the shape of the failure this suite exists for.

U3 is a row worth reading for what it did *not* catch. It was aimed at
the two assertions about handing the wrong key file to the wrong mode,
and neither of them moved — the run was refused anyway, for a different
reason, and the refusal happened to satisfy them. What caught it was the
rekey failing outright. The row records what actually went red rather
than what the mutation was aimed at, because the second is a guess and
the first is an observation.
