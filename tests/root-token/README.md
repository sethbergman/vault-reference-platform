# Root token tests

Run with:

```bash
./tests/root-token/run-tests.sh
./tests/root-token/run-tests.sh --keep-running
```

A few minutes. Stands up its own cluster and tears it down. Needs
`docker compose`, the `vault` CLI and `jq`.

## What this is about

`vault operator init` mints a root token because a new cluster has no
other way in. It answers to no policy, expires at no time, and ends up in
the shell history of everyone who exported it. Vault's guidance is to
revoke it once the auth methods are configured and generate a new one on
demand.

This repository said nothing about that, and for a security reference
silence is not neutral — it reads as "keep it".

It also *could not* have said otherwise, because
`bootstrap-dev-cluster.sh` discarded the recovery keys. With a seal
stanza those are what `generate-root` and `rekey` need, so revoking the
root token was a one-way door and the advice would have been destructive
to whoever followed it. Keeping them had to come first.

[`docs/security.md`](../../docs/security.md#the-root-token) carries the
procedure.

## What it checks

The whole lifecycle: the keys are kept at 0600 and gitignored, the root
token is revoked, an AppRole token carries on administering the cluster,
and a new root comes back from a quorum of shares as a different
credential.

Three refusals are exercised **in the state where they should refuse** —
no `--verify-with` at all, a `--verify-with` that is itself root, and one
entitled to nothing — each paired with an assertion that no refusal
revoked the root token on its way out.

## Mutation table

Every row run and watched to fail. Baseline is 16 passed, 0 failed.

| Deliberate break | Caught by | Result |
|---|---|---|
| the keys file is discarded after being written | the recovery keys were kept; and written 0600; with at least a threshold of shares; a new root token was generated from a quorum of recovery keys; and it really carries the root policy; and it is a different token | 10 / 6 |
| the keys file is written world-readable | and written 0600 | 15 / 1 |
| the policy check is dropped, so any live token is proof | revoking refuses a token entitled to nothing; and no refusal revoked the root token on its way out; revoke-root-token.sh completed with a valid non-root token | 12 / 4 |
| the root-token check on `--verify-with` is dropped | revoking refuses when the proof offered is itself root; revoking refuses a token entitled to nothing; and no refusal revoked the root token on its way out; revoke-root-token.sh completed | 12 / 4 |

One assertion in that row survives, and it is worth naming rather than
tidying away: *and gitignored* still passes with the file gone, because
`git check-ignore` asks whether the **path** would be ignored, not
whether anything is there. It is a correct assertion about the ignore
rule and it says nothing about the keys — which is exactly the kind of
distinction a mutation surfaces and a green run hides.

The third row is the one that matters. Dropping the policy check restores
the guard this suite was written against: the original implementation ran
`vault read sys/health`, which is unauthenticated, so it accepted any
token at all. That row is the difference between a check and a decoration
— see the end of [`docs/roadmap.md`](../../docs/roadmap.md).

### A mutation that proved nothing, and what it cost

The first attempt at the discarded-keys row deleted the `jq` that writes
the file. That left the `chmod` on the next line pointing at a file which
no longer existed, so under `set -e` the bootstrap died and the run
failed at *the cluster came up* — a real assertion catching a real
breakage, and nothing whatever about whether the keys assertion works.

The rerun removes the file *after* a successful write, which leaves the
bootstrap intact and takes away only the thing under test. It is the same
mistake made in `tests/state-backend`'s table, for the same reason:
breaking the code somewhere upstream of the assertion tests the upstream
thing.

## What it does not prove

Any of this on a cloud profile, where the seal is KMS rather than
Transit. The ceremony and the source of the keys are the same, but no
cloud profile has been applied.
