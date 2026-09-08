# tests/audit-anchor-worm

Audit chain anchors shipped to storage that refuses to delete them.

`tests/audit-chain` proves the anchors catch a chain rewritten to be
self-consistent. It proves it against an anchor file on the same Docker
host as the trail — which is the thing [`docs/audit.md`](../../docs/audit.md)
has always said is not the guarantee, because whoever reaches the daemon
reaches both volumes.

This suite is the far end. It applies `terraform/aws/audit-anchors`
against an implementation of the AWS API (moto), ships anchors the real
collector and anchor service produced, and then attacks them the ways an
attacker holding the shipping credential actually can.

```bash
./tests/audit-anchor-worm/run-tests.sh
```

Requires `terraform`, `python3` with `moto[server]`, `curl`, `aws` and
`sha256sum`. Takes about two minutes, costs nothing, and creates nothing
outside a local process.

## What a green run does not mean

An emulator implements the API, not the service. This does not show that
S3 enforces COMPLIANCE retention in an account, that the IAM policy the
module writes is the one AWS evaluates, or that a bucket in a second
account is reachable by the credential that would need to reach it.

It also does not make the *collection* off-host. The collector still runs
beside Vault, so an attacker there can stop it, and an entry never
collected is never anchored. What this closes is the other half: what
already left cannot be edited, and cannot be quietly removed.

## Object lock covers less than the name suggests

Two of the three ways to erase an anchor are permitted by S3, and the
suite asserts that they are permitted — because a guard against something
the emulator refuses outright is a guard that has never been exercised.

| Attack | S3 | What stops it |
|---|---|---|
| Delete the version | refused | COMPLIANCE retention |
| Overwrite the key | permitted, as a new version | `--fetch` reads the version shipped first |
| Delete with no version id | permitted, as a delete marker | the IAM policy; `--fetch` reads past it and reports it |

The delete marker is the one worth knowing about. It destroys nothing,
which is why the lock permits it, and a marked key is absent from
`list-objects-v2` and 404s on `head-object`. So the credential that ships
anchors can make every one of them invisible without deleting a byte, and
a shipper built on those two calls reports *no anchors found* —
indistinguishable from "nothing was ever anchored" at the moment the
distinction matters most.

## Mutation table

Every row was watched to fail. A mutation breaks the code with something
the assertion does not name; if the suite stays green, the assertion
cannot catch it and the row says so rather than being quietly dropped.

| # | Mutation | Caught by |
|---|---|---|
| M1 | Key uses `%d` instead of `%012d`, so sequence 12 sorts before 9 | in ascending sequence order |
| M2 | `--fetch` keeps the newest version of each key rather than the oldest | and returns no part of the forgery; and still carries the hash that was shipped |
| M3 | Conflict check compares against `[0]` (newest) rather than `[-1]` (shipped first) | against the anchor shipped first |
| M4 | Existence check uses `head-object`, as the first draft did | and reports a conflict; and says nothing was overwritten; shipping the same anchors again succeeds |
| M5 | `--fetch` reads the key rather than the version id | and reports the marker as an attack; and still wrote the anchors it recovered; fetching after the overwrite succeeds |
| M6 | An unlocked bucket warns instead of refusing | shipping to a bucket without object lock fails; and nothing was uploaded before it refused |
| M7 | Module asks for `GOVERNANCE` retention | the retention mode is COMPLIANCE; and a default retention in COMPLIANCE mode |
| M8 | Objects shipped with no retention flags at all | and are undeletable anyway, from the retention the shipper set |
| M9 | Policy omits `s3:ListBucketVersions` | the shipping policy can list versions, not only objects |
| M10 | A conflicting anchor falls through to the upload | and wrote no second version of the anchor it conflicted on |

### Three of these proved nothing the first time

M3, M8 and M10 left the suite entirely green on the first pass. Each was
a real gap, and each is worth recording because the reasons differ.

**M10** was the sharpest. `ship-anchors.sh` prints *Nothing was
overwritten* when it reports a conflict, and no assertion tested it:
`--fetch` reads the version shipped first, so it returns the original
whether or not a second version was written over it. The claim in the
message could have been false and every check would still have passed.
Counting versions on the conflicting key is what made it falsifiable.

**M3** could not fail because every key in the conflict test had exactly
one version, so `[0]` and `[-1]` addressed the same object. The
distinction only matters once an attacker has written a *newer* anchor
matching their rewritten chain — which is their obvious next move, since
the conflict is what gives them away. The suite now writes that forgery
and checks the conflict is still reported.

**M8** was different in kind: it changed nothing because the property
held anyway. Anchors shipped without explicit retention are still covered
by the bucket's *default* retention rule, which the module configures. So
the per-object flags are redundant against a bucket the module built —
and they are the only protection in a bucket somebody created by hand
with `--object-lock-enabled-for-bucket` and no default rule. The suite
now builds exactly that bucket, because against the module's own the
assertion passes for the wrong reason.

### Two mutations worth reading for what they did not break

M4 broke four checks but **not** *shipping the rewritten anchors fails* —
the conflict still exited non-zero through a different path. M5 broke
five, including one in a section it was not aimed at. Neither is a
problem; both are reminders that a mutation table records what was
observed, not what was predicted.
