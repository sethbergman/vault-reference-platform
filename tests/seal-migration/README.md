# tests/seal-migration

Moving a real three-node cluster between Transit auto-unseal and Shamir,
in both directions.

```bash
./tests/seal-migration/run-tests.sh
./tests/seal-migration/run-tests.sh --keep-running
```

Needs `docker compose`, the `vault` CLI, `jq` and `curl`. Slow — it
migrates the cluster twice and restarts every node several times.

## Why a real cluster

`docs/roadmap.md` calls changing seal type the operation most likely to
leave a cluster that will not unseal. It cannot be shimmed: a stand-in
`vault` reports whatever the script hoped for, and the whole question is
what the real barrier does when the thing protecting it changes.

## What the procedure turned out to be

Four steps, and four of them are not the obvious reading. All of this
came from running it, not from the documentation.

| | |
|---|---|
| Do **not** stop the standbys | On three nodes that leaves one, which is not a quorum, so no leader is elected and the migration never finalises. The first attempt produced a cluster that was unsealed, leaderless and half-migrated |
| **Every** node needs `-migrate` | Not just the active one. A plain unseal returns `500 migrate option not provided and seal migration is in progress` |
| It is not over when the last node unseals | `migration` stays `true` until a leader finalises it |
| Do not restart inside that window | A node restarted while `migration` is true will not auto-unseal even with a working seal stanza. It says so only in the logs |

That last one matters most, because the obvious way to check a migration
to auto-unseal worked — restart a node, see if it comes back on its own —
is the thing that breaks it if you do it too early. The node then looks
broken rather than early.

## Two assertions are about Vault, not the script

`scripts/migrate-seal.sh` is shaped around two behaviours, so the suite
pins them directly:

- a plain unseal really is refused mid-migration
- a config change plus a restart really does enter migration mode

If either stops being true, the script's unseal loop is carrying weight
it no longer needs, and this suite is what should say so rather than the
loop quietly guarding nothing.

## What a green run does not mean

This is the compose profile. The "restart" is a container restart and the
config edit happens inside the image; on a real node it is an edit to
`/etc/vault.d/vault.hcl` and a `systemctl restart`, which nothing here
performs. The sequence is the same and the mechanics are not.

No seal type other than Transit and Shamir is covered. Migrating between
two *cloud* KMS providers — the case where an organisation changes cloud
— has the same shape and no coverage here.

## Mutation table

Every row was watched to fail.

| # | Mutation | Caught by |
|---|---|---|
| S1 | Unseal without `-migrate`, as you would if you believed only the active node needed it | migrate-seal.sh --to shamir succeeds; and the secret written before it is still readable (5 in total) |
| S2 | Declare the migration finalised without waiting for it | and the migration finalised rather than being left in progress; and the secret survived both migrations (8 in total) |
| S3 | Refuse an in-progress migration instead of resuming it | migrate-seal.sh --to transit finishes an interrupted migration; a restarted node unseals itself with no shares supplied (5 in total) |

Each mutation takes down more assertions than the one it was aimed at,
which is what you would expect here: the suite runs one cluster through a
sequence, so breaking an early step strands everything after it. The
first named assertion in each row is the one the mutation was aimed at.

S3 is worth reading. The resume path exists because the suite found its
absence: the first version of the script refused a half-migrated cluster
with *already on transit*, because the nodes reported the target type
while being only halfway there. A stuck migration is exactly the state an
operator needs the tool for — it is what an interrupted run leaves, and
what you are looking at when a node was restarted too early.
