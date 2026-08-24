# Vault PKI node certificate tests

```bash
./tests/pki/run-tests.sh
```

Runs in a few seconds. No cluster, no cloud account, no credentials.
Needs `jq` and `openssl`.

## Why these exist

`scripts/issue-node-cert.sh` rewrites the TLS material of a running Vault
node and then signals it to reload. Almost every way that can go wrong
ends the same way: a node that cannot serve TLS. On the active node that
is an outage caused by the thing meant to prevent one.

So most of these assertions are about what the script must *refuse* to
do — install a mismatched cert/key pair, install a certificate for
another host, or touch anything at all when issuance failed.

## What is real and what is faked

**The certificates are real.** `make-fixtures.sh` generates a CA and
leaves with `openssl`, including one that expires inside the renewal
window and one that does not, one for the wrong hostname, and a key that
belongs to a different certificate. The script's checks run against
genuine X.509 material, not strings that look like it.

They are generated rather than committed. A throwaway private key in git
is still a private key in git, and these need specific expiry dates that
would go stale in a fixture file.

The suite asserts the fixtures have the properties it depends on before
using them — a "fresh" certificate that had accidentally expired would
turn the no-op tests green for entirely the wrong reason.

**Vault and systemd are shims.** `fake-bin/` stands in for both, recording
every call. That makes the interesting things checkable: that a reload is
a *reload* and not a restart, that no certificate is issued when none is
needed, and that a minted token is revoked afterwards while a
caller-supplied one is left alone.

**No node is ever reconfigured.** These tests prove the script behaves
correctly, not that Vault accepts what it writes. Nothing here has been
run against a real cluster.

## The one skipped assertion

The private key must be mode `0600`. Windows filesystems ignore `chmod`,
so the suite probes for support and reports `SKIP` rather than passing
silently — a test that reports green while checking nothing is worse than
one that says it did not run. It executes normally in CI.

## Checking the tests still fail

```bash
cp scripts/issue-node-cert.sh /tmp/orig
sed -i 's/systemctl reload vault/systemctl restart vault/' scripts/issue-node-cert.sh
./tests/pki/run-tests.sh   # expect 2 failures
cp /tmp/orig scripts/issue-node-cert.sh
```

Five mutations were checked when these were written — removing the
cert/key pair check, removing the hostname check, renewing on every run
regardless of remaining lifetime, restarting instead of reloading, and
ignoring a failed reload. Each turned between two and five assertions
red. Restore the file afterwards; a mutation left in the working tree is
indistinguishable from a real regression.

## What these do not cover

The bootstrap ordering. Vault PKI cannot issue the certificate the
cluster needs in order to start, so the first certificate always comes
from elsewhere — see the bootstrap section in
[`docs/security.md`](../../docs/security.md). The tests check that the
Ansible role stays off by default and refuses to run on a node with no
existing certificate, but the ordering itself is a property of a real
deployment, not something a shim can demonstrate.
