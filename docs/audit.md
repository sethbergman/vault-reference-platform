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

## Tamper evidence

An audit log answers "who read that secret" only for as long as it still
says what Vault sent. The collector originally appended bytes, which
meant anyone able to write to the volume could delete the record of what
they did — and a shorter log is indistinguishable from a quieter day.

Every entry now also produces a line in a parallel chain file:

```text
<seq> <sha256(entry)> <sha256(previous_chain_hash + entry_hash)>
```

Each link covers the one before it, so removing, altering or inserting an
entry breaks every link from that point on.
`scripts/verify-audit-chain.sh` recomputes the chain from the entries
themselves and reports the first sequence number where the two diverge:

```bash
./scripts/verify-audit-chain.sh            # reads from the running containers
./scripts/verify-audit-chain.sh --log a --chain b --anchors c
```

It distinguishes the failures, because they call for different
responses:

| Verdict | What happened |
|---|---|
| chain mismatch at N | an entry at or before N was altered, removed or inserted |
| log longer than chain | the tail was never chained; a crash does this, so does appending by hand |
| chain longer than log | entries were deleted from the log, and the chain still remembers them |
| anchor mismatch | the chain itself was rewritten |

The log is written exactly as before — raw entries, one per line, no
added fields — so anything already consuming it is unaffected. The
integrity data lives beside it, not inside it.

### Why the chain alone is not enough

A hash chain catches whoever cannot recompute it. It does nothing against
whoever can. An attacker with write access to the chain file deletes the
entries recording what they did, recomputes every hash from that point,
and the result verifies perfectly: internally consistent and completely
false.

What breaks that is a copy of the head hash held somewhere the attacker
is not. The `audit-anchor` service periodically records the chain head to
its own volume, with the audit volume mounted **read-only**. Neither
container can write where the other reads. Once the head for sequence N
is recorded elsewhere, any later rewrite of entries at or before N
produces a different head, and the two disagree.

This is asserted rather than assumed: `tests/audit-chain` builds a trail,
anchors it, deletes an entry, recomputes the whole chain, and checks that
the result **passes** verification without anchors and **fails** with
them. If the first half ever stops holding, chaining alone became
sufficient and the reasoning here needs revisiting.

Anchoring is periodic, not per-entry. Entries written since the last
anchor are covered by the chain but not yet by an anchor, so
`ANCHOR_INTERVAL` is the window in which a thorough attacker can still
rewrite history undetected. Shorter is safer and noisier.

Why chaining alone is not tamper evidence, and what the anchors change
about that, is written up in
[A hash chain is not tamper evidence][chain].

[chain]: https://sethbergman.github.io/posts/hash-chain-is-not-tamper-evidence/

### What this still is not

A separate volume on one host is a real separation, and it is not the
same thing as a separate host. Anything with access to the Docker daemon
can reach both volumes, so the local profile demonstrates the mechanism
rather than providing the guarantee.

The anchor format is three fields of text precisely so that shipping it
somewhere else is not a redesign. That is the next section.

## Shipping the anchors somewhere that cannot delete them

An anchor on the same host is a copy an attacker who reached the host can
edit. `scripts/ship-anchors.sh` writes each one to an S3 bucket under a
COMPLIANCE object-lock retention, which nothing can shorten or remove —
not the operator who wrote it, not the account root, not whoever holds
the credential the shipper runs with.

```bash
terraform -chdir=terraform/aws/audit-anchors apply
./scripts/ship-anchors.sh --bucket <name> --cluster prod-1
```

`terraform/aws/audit-anchors` is a root module of its own, for the reason
`terraform/aws/bootstrap` is: a `terraform destroy` of the cluster must
not be able to delete the record of what that cluster did.

Each anchor is a separate object, keyed by sequence number. That is not
tidiness. Object lock protects an *object*, so a single file holding
every anchor is rewritten by one PUT — the exact operation the lock has
to prevent.

Shipping into a bucket without object lock is refused rather than warned
about. Object lock can only be enabled at bucket creation, so by the time
anchors are landing in an ordinary bucket the fix is a new bucket and a
re-ship, and everything written in between was never protected.
`--allow-unlocked` exists for reading along without provisioning one, and
it says what it gave up.

### Three ways to erase an anchor, and what stops each

| Attack | S3 | What stops it |
|---|---|---|
| Delete the version | refused by the lock | COMPLIANCE retention |
| Overwrite the key | **permitted** — writes a new version | `--fetch` reads the version shipped first |
| Delete without a version id | **permitted** — writes a delete marker | the IAM policy; `--fetch` reads past it and reports it |

The second and third rows are the ones worth knowing before trusting any
of this, because "object lock" sounds like it covers them and does not.

A **delete marker** destroys nothing, which is exactly why the lock
permits it — and a marked key is absent from `list-objects-v2` and 404s
on `head-object`. The credential that ships anchors can therefore make
every one of them invisible without deleting a byte, and a shipper built
on the object APIs reports *no anchors found*: indistinguishable from
"nothing was ever anchored", at the moment the distinction matters most.

So `ship-anchors.sh` lists versions rather than objects, on both paths.
`--fetch` recovers the anchors from underneath the markers and reports
the markers as the attack they are; the conflict check reads versions too,
because a marked key that looked unshipped would let a rewritten chain
arrive as a fresh anchor with no conflict raised at all. The IAM policy
the module emits denies `s3:DeleteObject` so the marker cannot be written
in the first place. Neither measure is sufficient alone — a policy can be
detached, and a fetch that reports a marker is still a fetch somebody has
to run.

### Verifying against what was shipped

```bash
./scripts/ship-anchors.sh --bucket <name> --cluster prod-1 \
    --fetch /tmp/shipped-anchors
./scripts/verify-audit-chain.sh --anchors /tmp/shipped-anchors
```

Fetching is separate from shipping because it is the half you run during
an incident, on a machine that is not the compromised one, with a
credential that only reads. Bundling them would mean verifying with the
same key that writes.

`--fetch` exits non-zero if any anchor has a delete marker over it, and
writes the file anyway — the anchors are intact underneath, and you want
both the evidence and the alarm. Reporting the attempt only on stderr
would let a scheduled verification record a success on the one event
these anchors exist to surface.

Re-shipping a chain that has been rewritten does not overwrite what is
already there. It reports a conflict, names the sequence, and exits
non-zero — the finding this whole arrangement exists to produce.

### What shipping does not fix

The collector still runs beside Vault. This moves the evidence out of
reach, not the collection of it: an attacker on the host can stop the
collector, and an entry never collected is never anchored. What they
cannot do is edit or quietly remove what already left.

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

`tests/audit-anchor-worm/run-tests.sh` covers the far end: it applies
`terraform/aws/audit-anchors` against an emulated AWS API, ships anchors
the real collector and anchor service produced, and then attacks them —
deleting the version, overwriting the key, writing a delete marker, and
re-shipping a rewritten chain. It also checks the two cases where a
green run would otherwise mean nothing: that the emulator really does
permit the overwrite and the marker, so the guards against them are
being exercised rather than sitting behind a refusal.

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

`ship-anchors.sh` closes the half of this that is about the evidence.
Once an anchor is in a locked bucket, an attacker holding every
credential this repository uses cannot edit or remove it, and
`tests/audit-anchor-worm` demonstrates each of the three attacks above
against a bucket Terraform built.

It does not close the half about collection. The collector still runs on
the Vault host, so a compromise there can stop it, and entries that never
reach the collector are never chained and never anchored — no property of
the destination recovers those. Shipping makes the trail *up to the
compromise* durable and tamper-evident; it does not extend the trail past
it.

And the demonstration is against an emulated AWS API, not an account. It
shows that the requests are built and answered as the design assumes. It
does not show that S3 enforces COMPLIANCE retention for real, that the
IAM policy is the one AWS evaluates, or that a bucket in a second account
is reachable by the credential that would need to reach it — the second
account being the arrangement that makes any of this a genuine
separation. See `docs/roadmap.md`.

A real deployment points the socket device at a collector somewhere else
entirely. The device configuration does not change; only the address
does:

```bash
./scripts/bootstrap-audit.sh     --second-type socket     --second-address logs.internal:9090
```

What sits behind that address is the deployment's choice. Anything
speaking a TCP stream works — Vector, Fluent Bit, rsyslog, a managed
collector. The properties worth insisting on, in rough order:

| Property | Why | Here |
|---|---|---|
| Different host | A compromise of the Vault node cannot reach it | not demonstrated — needs a second host |
| Append-only or object-locked | Nor can a compromise of the collector rewrite history | `terraform/aws/audit-anchors`, against an emulated API |
| Different credentials | Vault's identity should not grant deletion of its own audit trail | the IAM policy that module emits, statically |

The last two are the ones people skip. Shipping a log to a place the
same attacker can edit is a change of address, not of risk.

They are also the two that turn out to be reachable without a second
machine, which is why the anchors were shipped before the collector was
moved. Ordering them the other way round — a collector on a second host,
writing to storage the same credential can empty — buys the property that
is easiest to see and the weaker of the two.

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
