# Scheduled snapshot tests

```bash
./tests/snapshot/run-tests.sh
```

Runs in about two seconds. No cluster, no cloud account, no credentials.
Needs `jq`.

## Why these exist

`docs/disaster-recovery.md` described hourly snapshots long before
anything scheduled them, and `scripts/snapshot.sh` was referenced by
nothing — not CI, not Terraform, not cloud-init, not Ansible. Meanwhile
`scripts/dr-drill.sh` has been testing the *restore* path since
[#10](https://github.com/sethbergman/vault-reference-platform/pull/10),
against snapshots that in a real deployment nothing was creating.

A backup job is the worst place for a quiet failure. It runs unattended
on a timer, and every interesting failure mode ends with "and nobody
notices until the restore". So the cases here are deliberately the ones
that produce a **green timer and no usable backup**:

- an empty or truncated snapshot that uploads cleanly
- a `403` from blob storage that `curl` reports as success
- an unsealed node that the script mistakes for a sealed one
- every node uploading, or no node uploading

## What is real and what is faked

**The script under test is real.** No copy, no reimplementation.

**The tools it calls are shims.** `fake-bin/` holds stand-ins for `vault`,
`aws`, and `curl` that record every invocation and answer with whatever
the scenario needs. That makes the assertions that matter possible: not
just "did it succeed" but *"did it upload"* and, more importantly, **"did
it not upload"**.

The suite asserts up front that the shims actually shadow any real tools
on `PATH`. If that resolution failed, every case below would pass
vacuously.

Scenario variables (`FAKE_*`) are exported rather than set as a command
prefix. The shims are grandchildren of the test shell, and a
`VAR=x run_snapshot` prefix does not reach them — a mistake that silently
turns a scenario into the default one.

**Nothing is uploaded anywhere, and no snapshot of real data is taken.**

## The bug these found

`scripts/snapshot.sh` originally read the seal state as:

```bash
SEALED="$(jq -r '.sealed // true' <<< "$STATUS_JSON")"
```

jq's `//` operator treats `false` as empty, the same as `null`. So
`.sealed // true` returns `true` for an **unsealed** node:

```console
$ echo '{"sealed":false}' | jq -r '.sealed // true'
true
```

Every node would have reported itself sealed, exited 0, and taken no
snapshot — on every node, every hour, indefinitely, with a green systemd
timer the whole time. The script would have been a no-op that looked
healthy.

The same idiom is safe two lines above for `ha_mode`, because that field
is a string and never `false`. That is exactly what makes it easy to miss
in review.

## Checking the tests still fail

A green test that cannot go red is worse than no test. Break something
and confirm:

```bash
cp scripts/snapshot.sh /tmp/snap.orig
sed -i 's/if has("sealed") then .sealed else true end/.sealed \/\/ true/' \
  scripts/snapshot.sh
./tests/snapshot/run-tests.sh   # expect ~31 failures
cp /tmp/snap.orig scripts/snapshot.sh
```

Eight mutations were checked when these were written, each turning
between one and thirty-one assertions red:

| Mutation | Failures |
| --- | --- |
| Reintroduce the `jq //` seal bug | 31 |
| Let standbys snapshot too | 3 |
| Skip snapshot verification | 4 |
| Ignore the Azure HTTP status code | 3 |
| Leave the local snapshot on disk | 2 |
| Never revoke the minted token | 1 |
| Drop the zero-byte check | 3 |
| Revoke a token we did not mint | 1 |

Restore the file afterwards. A mutation left in the working tree is
indistinguishable from a real regression — one of these runs timed out
mid-mutation while this suite was being written, and the strand was only
caught by re-grepping for every target.

## What this does not prove

That a snapshot restores. `tests/upgrade` and `scripts/dr-drill.sh` cover
the restore path against a real local cluster; this suite covers the
capture and upload path against shims.

Neither cloud profile has been applied to a real account, so the S3 and
blob uploads have never run against real storage — the emulated apply
covers the Terraform profile, not the snapshot path that uses it. The
status-code and credential handling are asserted; the endpoints' actual
behaviour is not.

## What the shims got wrong

Worth recording, because it is the clearest argument in this repository
for having integration tests at all.

`snapshot.sh` decided whether it was the leader by reading `ha_mode` from
`vault status -format=json`. That field does not exist there — the CLI
renders "HA Mode: active" for its *text* output only. Every node
therefore concluded it was not the leader and took no snapshot: three
green timers, hourly, and zero backups.

This suite did not catch it, because the shim emitted `ha_mode` too. The
shim agreed with the bug, so the tests were checking that the script
correctly read a field that only the shim provided.

`tests/integration` found it on the first run against a real cluster.
Leadership now comes from `sys/leader`'s `is_self`, the shim models the
real response shape, and the cases above pin it.

The lesson is not "shims are bad" — they catch things a real cluster
cannot reproduce on demand. It is that a shim written from the same
assumption as the code confirms the assumption rather than testing it.
