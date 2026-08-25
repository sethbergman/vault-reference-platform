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

### The secondary belongs on a different failure domain

Two files on one partition is one failure domain wearing two hats: the
same disk fills for both, so the redundancy is nominal.

| Device | Fails when |
|---|---|
| `file` on the Vault node | that disk fills |
| `socket` to a collector | the network or collector is down |
| `syslog` to a remote host | the same, plus the syslog daemon |

The script defaults to a second **file**, because that works with nothing
else running. The local profile and the integration tests use a
**socket** instead, pointed at the `audit-collector` container:

```bash
./scripts/bootstrap-dev-cluster.sh --with-audit
./scripts/bootstrap-audit.sh \
    --second-type socket \
    --second-address audit-collector:9090
```

That pairing — file primary, socket secondary — is what HashiCorp
recommend, and it is not arbitrary. A socket device **alone** can block
Vault when its endpoint goes away. Paired with a file device it cannot,
because the file keeps satisfying the at-least-one guarantee.

It is also the only arrangement in which losing a device demonstrates
anything, which is why the integration suite stops the collector and
checks Vault keeps serving. Two files would have failed together.

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
- stopping the collector leaves Vault serving, healthy, and still
  recording to the file device
- destroying the Vault node outright leaves the shipped trail readable
- recreating the collector does not lose it, because the log lives in a
  volume rather than in a container

## What is not covered

**The all-devices-fail outage is documented, not demonstrated.** Proving
it means breaking *every* device on a running cluster, and the recovery
is manual.

What is demonstrated is the half that matters operationally: the
integration suite stops the audit collector and shows Vault still
accepting writes, still healthy, and still recording to the surviving
device. That is the at-least-one guarantee doing its job, and it is the
reason to run two devices rather than one.

**Off-host shipping.** The collector here writes to a Docker named
volume. That is enough to outlive the Vault node — which is the property
that matters and the one the tests prove — and it is *not* off-host:
anything with access to the Docker daemon can still reach it.

A real deployment points the socket device at a collector somewhere else
entirely. The device configuration does not change; only the address
does:

```bash
./scripts/bootstrap-audit.sh     --second-type socket     --second-address logs.internal:9090
```

What sits behind that address is the deployment's choice. Anything
speaking a TCP stream works — Vector, Fluent Bit, rsyslog, a managed
collector. The properties worth insisting on, in rough order:

| Property | Why |
|---|---|
| Different host | A compromise of the Vault node cannot reach it |
| Append-only or object-locked | Nor can a compromise of the collector rewrite history |
| Different credentials | Vault's identity should not grant deletion of its own audit trail |

The last two are the ones people skip. Shipping a log to a place the
same attacker can edit is a change of address, not of risk.

**Nothing enables audit devices by default.** The `vault_audit` role
exists and is wired into `playbooks/site.yml`, but
`vault_audit_enabled` defaults to `false`.

That default is load-bearing rather than cautious. Turning audit logging
on introduces a dependency that, when it fails, stops Vault answering.
That is correct behaviour, and it is a change somebody should make
knowingly rather than inherit from a playbook run against an existing
cluster.

```yaml
vault_audit_enabled: true
vault_audit_token: "<token with sudo on sys/audit>"

# Recommended: put the second device somewhere that fails separately.
vault_audit_second_type: socket
vault_audit_second_address: logs.internal:9090
```

The role runs against Vault's API rather than its config file, so it
needs a cluster that is already up and unsealed — which is why it is
ordered last.
