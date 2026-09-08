# tests/key-rotation

Rotating the barrier key, and re-issuing the recovery key shares.

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

## What a green run does not mean

Seal migration is not covered. Moving a cluster between seal types with
`-migrate` is the operation most likely to produce a cluster that will
not unseal, and nothing here exercises it. Neither is a Shamir rekey:
this cluster uses a Transit seal, so its shares are recovery keys and the
unseal-key path has no coverage.

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

K2 is the one worth reading. It breaks nothing in the code the assertions
name — the rekey still runs, Vault still accepts every share, the cluster
stays healthy — and it takes eight assertions with it, because the shares
the operator is left holding are not the shares the cluster now wants.
That is the shape of the failure this suite exists for.
