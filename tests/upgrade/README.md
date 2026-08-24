# Rolling upgrade tests

```bash
./tests/upgrade/run-tests.sh
```

Runs in about 30 seconds. No cluster, no cloud account, no SSH access.

## Why these exist

`scripts/vault-upgrade.sh` drives real hosts over SSH and systemd. The
local profile is containers, which have neither, so until now nothing
exercised it — the same gap `scripts/dr-drill.sh` had before
[#10](https://github.com/sethbergman/vault-reference-platform/pull/10).

That matters because the script's failure modes are quiet and expensive.
An upgrade that skips checksum verification installs whatever it
downloaded onto every node. One that doesn't stop on an unhealthy node
takes out a second node and, with it, quorum.

## What is real and what is faked

**Artifact handling is real.** The checksum path is exercised against an
actual archive: a good checksum proceeds, a bad one aborts *and touches
no node at all*.

The archive is built locally rather than downloaded from HashiCorp. The
script only cares that the download is a zip, that its checksum matches,
and that a file named `vault` is inside — a synthetic archive exercises
all three identically. Fetching the real 150MB release took nearly four
minutes, which is a lot of CI time, and a lot of waiting when checking
that these tests actually fail.

**Rolling sequencing runs against shims.** `tests/upgrade/fake-bin/`
contains stand-ins for `ssh` and `scp` that record every command and
answer with whatever the scenario needs. That makes the ordering
testable:

- the leader is stepped down before it is stopped
- a standby is not stepped down
- the binary is staged before the service goes down
- each node is confirmed healthy before the next is stopped
- an unhealthy node aborts the run instead of continuing

**What this does not prove:** that systemd restarts Vault, that `scp`
lands the binary where it should, or that a real node rejoins the
cluster. Only a real upgrade against real hosts shows that.

## These found two bugs when first written

Worth recording, because both were invisible until something ran the
script:

- **`SSH_USER="${USER}"` crashed under `set -u`.** `$USER` is not
  exported on CI runners, in containers, or under cron, so the script
  died on line 48 before doing anything. Now falls back to `id -un`.
- **A missing `jq` silently changed the results.** `is_leader()` decides
  with `... | jq -e '.is_self == true'`; with no `jq` that pipeline just
  fails, no node is ever stepped down, and the "a standby is not stepped
  down" assertion passes for entirely the wrong reason. The suite now
  checks its dependencies up front and refuses to run without them.

## Assertions have to be able to fail

Two traps this suite hit while being written, both of which produce
green runs that mean nothing:

1. **`grep` on a missing file succeeds.** Assertions shaped as "X did not
   happen" pass trivially when the script died before contacting any
   node. `require_log` guards those.
2. **`VAR=x func` does not export.** Scenario variables set that way
   reached the shell function but not the `bash "$UPGRADE_SH"` child, so
   the scenario silently didn't apply and the abort-path tests passed
   against a perfectly healthy rollout. `run_upgrade` now forwards them
   explicitly.

The check for both is the same: break the thing on purpose and confirm
the suite goes red. These have been checked that way:

| Mutation | Caught |
|---|---|
| Checksum verification skipped entirely | ✅ |
| Unhealthy node warns instead of aborting | ✅ |
| Leader never stepped down | ✅ |

Worth repeating for anything added later.
