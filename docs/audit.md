# Audit Devices

Audit logs answer the question nothing else in Vault can: **who read that
secret**. Without one, a compromised token leaves no trace of what it
touched.

```bash
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=$PWD/docker/dev/tls/ca.crt
export VAULT_TOKEN=<root token>

./scripts/bootstrap-audit.sh
vault audit list -detailed
```

## Why two devices, and why this is the dangerous part

Vault sends every request and response to all enabled audit devices and
guarantees the entry reaches **at least one**. If it cannot write to any
enabled device, it refuses to service the request.

That is the correct behaviour — a Vault that cannot be audited should not
be answering questions about secrets — and it has a consequence worth
being blunt about:

> **A single audit device turns a full disk into a total outage.**

Enabling audit logging naively makes Vault *less* available, and the
failure arrives at 3am on the day the log partition fills. Two devices on
independent failure domains is what stops routine disk pressure becoming
downtime.

`bootstrap-audit.sh` enables two by default. `--no-second` exists, and
says plainly what it costs.

### The local profile demonstrates the mechanism, not the redundancy

Both devices here are files on the same filesystem. That proves entries
reach both, and proves nothing about surviving a full disk — the same
disk fills for both.

In a real deployment the second device belongs somewhere that fails
separately:

| Device | Fails when |
|---|---|
| `file` on the Vault node | that disk fills |
| `syslog` to a remote collector | the network or collector is down |
| `socket` to a log shipper | the shipper dies |

Two files on one partition is one failure domain wearing two hats.

## What is in the log, and what is not

Sensitive values are hashed with a per-cluster HMAC key rather than
recorded. You can check whether a value matches something you already
know; you cannot read it out. That is what makes these logs safe to ship
to a central collector.

```json
"data": { "value": "hmac-sha256:2f1c...b09e" }
```

The request token is hashed the same way. An audit log containing usable
tokens would be a credential store with extra steps.

`log_raw = true` disables all of this and writes secrets in clear text.
`bootstrap-audit.sh` will not set it and offers no flag for it.

## Rotation

Vault holds the log file open, so rotation is: move the file, then send
`SIGHUP`. Vault closes and reopens the configured path.

```text
/vault/audit/*.log {
    daily
    rotate 30
    compress
    missingok
    postrotate
        kill -HUP $(pidof vault)
    endscript
}
```

Without the signal, Vault keeps writing to the moved inode. The rotated
file grows, the new file stays empty, and the log looks rotated while
nothing lands in it.

### The signal is shared

`SIGHUP` also reloads TLS certificates — see
[`docs/security.md`](security.md). Two consequences:

- A logrotate hook reloads certificates as a side effect. Harmless.
- A certificate Vault cannot read surfaces as a failed reload **during
  log rotation**, which is a confusing place to find it.

`scripts/issue-node-cert.sh` verifies its own reloads, so a certificate
problem is caught there first rather than at midnight.

## Enabling a device is validated

Vault writes a test entry when a device is enabled, so an unwritable path
is rejected immediately:

```console
$ vault audit enable -path=bad file file_path=/nonexistent/dir/audit.log
Error enabling audit device: ... permission denied
```

That is the good case. The alternative — a device that enables cleanly
and then blocks every subsequent request — is the outage this design is
trying to avoid.

## What is tested

`tests/audit/run-tests.sh` covers the script's decisions against a shim:
two devices by default, `--no-second` warning about what it costs,
`--force` refusing to disable the only device, and an enable that returns
success without enabling anything being treated as failure rather than
reported as success.

`tests/integration/run-tests.sh` covers whether any of it works, against
a real cluster:

- a request appears in the log, by path
- the **same** entry reaches the second device
- the secret value is **not** in the log
- the root token is **not** in the log
- values appear as `hmac-sha256:` digests
- moving the file and sending `SIGHUP` resumes writes to the new path,
  with Vault serving throughout
- an unwritable path is rejected at enable time and leaves Vault serving

## What is not covered

**The all-devices-fail outage is documented, not demonstrated.** Proving
it means filling a disk or breaking every device on a running cluster,
and the recovery is manual. The behaviour is HashiCorp's, stated in their
documentation; what is tested here is the mitigation — that two devices
are enabled and both receive entries.

**No log shipping.** Where audit logs go, how long they are kept, and who
can read them are deployment decisions. Nothing here forwards them
anywhere.

**Nothing enables audit devices automatically.** `bootstrap-audit.sh` is
run deliberately, and the Ansible roles do not call it. Enabling audit
logging changes Vault's availability characteristics, and that should be
a decision someone makes rather than a side effect of running a playbook.
