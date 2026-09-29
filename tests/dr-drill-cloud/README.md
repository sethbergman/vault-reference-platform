# Cloud DR drill tests

`scripts/dr-drill-cloud.sh` restores a real cloud cluster from a snapshot
and then argues that the restore took. These tests drive it against shims.

```bash
./tests/dr-drill-cloud/run-tests.sh
```

Runs in about fifteen seconds. No cluster, no cloud account, no money.

## Why this exists

The drill is the only thing in this repository that has ever restored a
cloud cluster. It runs by hand, once per cluster, on a day somebody has a
cluster to spend — and there is no second run to catch it being wrong. A
drill that reports four passes against a cluster it never really restored
is worse than no drill at all: it converts an unknown into a wrong answer,
and the wrong answer is the reassuring one.

It shipped without a suite, on the strength of one green run against
Azure. The AWS half had never been run and could not have worked:

- **It pointed at the load balancer.** `terraform/aws/lb.tf` probes
  `/v1/sys/health?standbyok=true` precisely so that standbys stay in the
  target group — that is checklist item 4, and it is deliberate. The
  listener is TCP, so connections spread across all three nodes, and Vault
  redirects a snapshot request to the leader's `api_addr`, which
  `user-data.sh.tftpl` sets to the node's private address. Two attempts in
  three would have failed from outside the VPC, which is the same failure
  Azure produced and the reason the Azure half tunnels to the leader.
- **It never set `VAULT_CACERT`.** TLS terminates at Vault under a private
  CA, so every call would have failed verification long before reaching
  any of the above — and the only way past that is the flag this
  repository forbids.

Neither was visible from reading the script; both are visible from reading
the load balancer's health check next to it.

A third turned up while writing the suite. The Azure half asked **instance
0** who the leader was. Scale set instance ids are assigned once and never
reused downwards, so every reconciliation increments them and a scale set
that has replaced a node has no instance 0 at all — the 2026-09-28 apply
finished with instance `000005` on a three-instance scale set. It worked
on the 29th because the cluster had been rebuilt from scratch that
morning.

## The shims are stateful

`fake-bin/vault` remembers the canary, what the snapshot contained, and
whether a restore has happened. That is not decoration: the thing under
test is a **sequence**, and a shim that answers each call in isolation
cannot express a restore that succeeds and changes nothing — which is the
exact failure the drill exists to catch, and the one an exit code cannot
see.

It models the real tool's output rather than the output the drill wants,
which is the rule the integration suite exists to enforce. So
`status -format=json` carries `type` and not `seal_type`, and carries no
`ha_mode` at all, because the real command has neither. A shim that
emitted a field Vault does not have would agree with a bug forever, and
that is not hypothetical here: it is how this repository shipped a
snapshot job that took no snapshots.

`fake-bin/az` models a scale set with instances **4, 5 and 6**, for the
reason above. A shim numbering from zero would agree with a drill that
assumed instance 0 exists.

`fake-bin/aws` and `fake-bin/az` really do bind the local port, because
the drill really does wait on it with a socket connect. A shim that logged
the call and returned would leave `wait_for_port` timing out and every
case passing or failing for the wrong reason. They bind 18200 and 18201,
so this suite wants those two ports to itself.

## What each group is for

| Group | Pins |
|---|---|
| Arguments | That it refuses to start without a cloud, a token, a CA or a sane read budget — and that nothing reaches the cloud first |
| AWS | That it forwards a port to the **leader**, via the autoscaling group, and that every Vault call goes through that port with the CA attached |
| Azure | That it asks the scale set which instances exist, and tunnels through the Bastion to the leader's |
| The sequence | That the canary precedes the snapshot, the token follows it, and the restore comes last |
| What each check catches | One case per check, each with the failure that check exists to find |
| Consent | That anything but the cloud's name restores nothing |
| `--from-file` | That a supplied snapshot is not quietly replaced by a fresh one |
| Failures on the way in | That an empty or unsavable snapshot stops the drill **before** it restores |

Two assertions are worth reading rather than skimming.

**"Every Vault call goes through the forwarded port"** is the positive form
of "it does not use the load balancer". Asserting the absence of the load
balancer's DNS name would pass a drill that used its IP address, or a
second load balancer, or no address at all. Counting the calls that went
anywhere other than `127.0.0.1:1820[01]` cannot be satisfied that way.

**Both values of `sealed` are pinned.** `jq`'s `//` is the alternative
operator and it treats `false` as absent, so `.sealed // empty` reads as
nothing on a healthy cluster: the check could only ever fail when
everything was fine. It did exactly that, twice, on 2026-09-29. Asserting
only the `true` case would not have caught it.

## Mutation table

Every row was watched failing. Each mutation is something the assertions
do not name — breaking the code in exactly the way a test greps for proves
only that grep works.

| Mutation | First caught by | Failures |
|---|---|---|
| The second port forward targets any node rather than the leader | `it then re-targets the port forward at the leader` | 4 |
| `VAULT_ADDR` becomes the load balancer after the forward opens | `every Vault call goes through the forwarded port` | 1 |
| The CA is no longer exported | `every Vault call carries the CA` | 1 |
| `jq -r "${path} // empty"` — `//` back on a boolean | `sealed=false is read, not mistaken for absent` | 5 |
| The confirmation is skipped | `anything but the cloud name aborts` | 3 |
| `ANY_NODE=0` — Azure scale sets number from zero | `it asks the scale set which instances exist` | 8 |
| The post-snapshot token is a constant rather than minted | `a token minted after the snapshot no longer works` | 12 |

An eighth was tried and is not in the table: replacing
`vault kv metadata delete` with `vault kv delete`. No assertion catches
it, and no assertion should — a soft delete and a metadata delete are both
undone by a storage-level restore, so the drill reaches the same
conclusion either way. The reason to keep the metadata delete is that it
models a disaster the restore is actually needed for; a soft delete is
recoverable with `vault kv undelete` and nothing here would notice. That
is a property of the scenario rather than of the checks, which is why it
is written down here instead of asserted.

## What it does not prove

That the drill restores anything. It proves the drill issues the commands
you expected, in the order you expected, and reaches the conclusions you
expected from the answers it gets — nothing more. Only a cluster can
settle the rest, which is what `docs/cloud-apply.md` items 6 and 7 are
for, and which has happened once, on Azure, on 2026-09-29.

In particular the AWS path is **unproven against AWS**. Every assertion
here about SSM port forwarding describes a command this suite believes is
right. The `--parameters` shorthand was checked against a real
`aws-cli/2.22` — it parses — but no real `aws ssm start-session` has ever
carried this drill.
