# tests/restore-from-object-store

A snapshot in object storage is a restorable snapshot — or it is not, and
nothing here checked until now.

```bash
./tests/restore-from-object-store/run-tests.sh
./tests/restore-from-object-store/run-tests.sh --keep-running
```

Needs `docker compose`, the `vault` CLI, `jq`, `aws`, `curl`, and
`python3` with `moto[server]`. Runs against a real three-node cluster and
an emulated S3 API.

## The gap this closes

This repository was built around one failure: the timer was green and the
backups were not there.

`scripts/snapshot.sh` closes most of it — it inspects a snapshot before
uploading, so a truncated or empty file is refused rather than shipped.
`scripts/dr-drill.sh` proves a snapshot restores, from a local file.

The join between them had never been run. On the cloud profiles the
snapshot goes to S3 and **nothing ever reads one back**. A successful
`aws s3 cp` proves an object exists at a key. It does not prove the
object is a snapshot, that it survived the round trip, or that restoring
it produces the cluster you had. Those are three different claims and
only the last one is a backup.

## What it does

Writes a secret, snapshots a real cluster, uploads through
`snapshot.sh --cloud aws --endpoint <emulator>`, downloads the object,
inspects it, restores it, and then checks **both** halves:

- the secret written *before* the snapshot is back
- the secret written *after* it is gone

The second is what separates a restore from a no-op. A restore that
silently did nothing leaves a healthy cluster that still has both, and
would pass the first check alone.

It also corrupts a byte of the downloaded copy and requires `snapshot
inspect` to refuse it. A guard that accepts damaged input would have
accepted the good input for no reason — the check has to be able to fail
before its passing means anything.

## What a green run does not mean

The S3 API is an emulator. This settles that the object round trips and
that what comes back restores. It does not settle that the instance role
can reach a real bucket, that server-side encryption on a real bucket
leaves the object restorable, or that a multipart upload of a snapshot
larger than anything here behaves the same. See `docs/cloud-apply.md`.

`--endpoint` on `snapshot.sh` exists for this suite. A real run does not
pass it and should not.

## Mutation table

Every row was watched to fail.

| # | Mutation | Caught by |
|---|---|---|
| R1 | A decoy file is uploaded in place of the snapshot | and Vault inspects it as a valid snapshot; the downloaded snapshot restores; and the secret written after it is gone |
| R2 | `--endpoint` is ignored, so the upload never reaches the emulator | snapshot.sh --cloud aws succeeds against the emulator; and an object landed in the bucket |

R1 is the one that matters. Every assertion up to it still passes — the
upload succeeds, an object lands at the key, it is not empty, it
downloads, and its size matches what the bucket reported. Five checks
green on an object that is not a backup. What catches it is reading the
object back and asking Vault whether it is a snapshot, which is precisely
the step that did not exist before this suite.
