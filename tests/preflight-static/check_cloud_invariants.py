#!/usr/bin/env python3
"""Cross-resource invariants the first real Azure apply cost us.

Each of these was a defect on 2026-09-28, each was detectable from the
source alone, and none was reachable by `terraform test` against mocked
providers -- which checks that a configuration says what it means to say,
not that the cloud will accept what it means.

They are written as general rules rather than as re-detections of what
broke. A check that only recognises the exact resource names from that
session would pass the next module somebody writes, which is the module
that will have the same bug.

Prints one line per finding, and OK lines for the checks that hold, so a
vacuous pass is visible: a rule that finds nothing to check says so.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(sys.argv[1])
findings = []
checked = []


def fail(rule, detail):
    findings.append(f"{rule}: {detail}")


def note(rule, detail):
    checked.append(f"{rule}: {detail}")


def tf_files(module):
    return sorted(module.glob("*.tf"))


def module_text(module):
    return "\n".join(p.read_text() for p in tf_files(module))


def resource_bodies(text, kind):
    """Every `resource "<kind>" "<name>" { ... }` body, by name.

    Brace-counted rather than regexed to a closing line: a nested block
    ending in `}` at any indent would end the match early, and the
    resources here are full of nested blocks.
    """
    out = {}
    for m in re.finditer(r'resource\s+"%s"\s+"([^"]+)"\s*\{' % re.escape(kind), text):
        name = m.group(1)
        i = m.end()
        depth = 1
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        out[name] = text[m.end():i - 1]
    return out


# Every root module that could have an azurerm provider.
MODULES = [p for p in sorted(ROOT.glob("terraform/*")) if p.is_dir()]
MODULES += [p for p in sorted(ROOT.glob("terraform/*/*")) if p.is_dir() and list(p.glob("*.tf"))]
MODULES = [m for m in MODULES if list(m.glob("*.tf"))]


# --- 1 -------------------------------------------------------------------
# An account that refuses shared keys has to be reached through Entra, and
# the provider's own data-plane calls default to a key: the Blob Service
# poll that finishes creating the account, and creating a container in it.
RULE = "storage_use_azuread"
seen = 0
for mod in MODULES:
    text = module_text(mod)
    if "shared_access_key_enabled" not in text:
        continue
    accounts = resource_bodies(text, "azurerm_storage_account")
    keyless = [n for n, b in accounts.items()
               if re.search(r"shared_access_key_enabled\s*=\s*false", b)]
    if not keyless:
        continue
    seen += 1
    prov = re.search(r'provider\s+"azurerm"\s*\{(.*?)\n\}', text, re.S)
    body = prov.group(1) if prov else ""
    if not re.search(r"storage_use_azuread\s*=\s*true", body):
        fail(RULE, f"{mod.relative_to(ROOT)} has a key-refusing storage account "
                   f"({', '.join(keyless)}) and no storage_use_azuread on the provider")
if seen:
    note(RULE, f"{seen} module(s) with a key-refusing account")
else:
    fail(RULE, "no key-refusing storage account anywhere — this rule checked nothing")


# --- 2 -------------------------------------------------------------------
# Owner is a control-plane role and carries no data-plane access. Creating
# a container in a key-refusing account goes through the data plane, so it
# needs a role assignment for whoever runs the apply -- and has to be
# ordered after it, which nothing in the references says.
RULE = "container needs a data-plane role, and to wait for it"
seen = 0
for mod in MODULES:
    text = module_text(mod)
    accounts = resource_bodies(text, "azurerm_storage_account")
    if not any(re.search(r"shared_access_key_enabled\s*=\s*false", b)
               for b in accounts.values()):
        continue
    containers = resource_bodies(text, "azurerm_storage_container")
    if not containers:
        continue
    seen += 1
    roles = resource_bodies(text, "azurerm_role_assignment")
    operator = [n for n, b in roles.items()
                if "Storage Blob Data" in b
                and "data.azurerm_client_config.current.object_id" in b]
    if not operator:
        fail(RULE, f"{mod.relative_to(ROOT)} creates a container in a key-refusing "
                   "account with no Storage Blob Data role for the signed-in identity")
        continue
    for cname, cbody in containers.items():
        dep = re.search(r"depends_on\s*=\s*\[([^\]]*)\]", cbody, re.S)
        if not dep or not any(f"azurerm_role_assignment.{r}" in dep.group(1)
                              for r in operator):
            fail(RULE, f"{mod.relative_to(ROOT)}: container {cname} does not "
                       f"depends_on the operator's role assignment "
                       f"({', '.join(operator)})")
if seen:
    note(RULE, f"{seen} module(s) creating a container in a key-refusing account")
else:
    fail(RULE, "no container in a key-refusing account — this rule checked nothing")


# --- 3 -------------------------------------------------------------------
# azurerm_storage_account does not know about the separate CMK resource,
# reads back a customer_managed_key block it never declared, and plans to
# remove it. The two then undo each other on alternate applies, silently,
# while nothing fails.
RULE = "an account with a separate CMK must ignore that block"
seen = 0
for mod in MODULES:
    text = module_text(mod)
    cmks = resource_bodies(text, "azurerm_storage_account_customer_managed_key")
    if not cmks:
        continue
    seen += 1
    for cname, cbody in cmks.items():
        ref = re.search(r"storage_account_id\s*=\s*azurerm_storage_account\.(\w+)\.id", cbody)
        if not ref:
            fail(RULE, f"{mod.relative_to(ROOT)}: {cname} does not name the account it encrypts")
            continue
        acct = resource_bodies(text, "azurerm_storage_account").get(ref.group(1), "")
        life = re.search(r"lifecycle\s*\{(.*?)\n  \}", acct, re.S)
        if not life or "customer_managed_key" not in life.group(1):
            fail(RULE, f"{mod.relative_to(ROOT)}: account {ref.group(1)} has a separate "
                       "CMK resource and no ignore_changes = [customer_managed_key]")
if seen:
    note(RULE, f"{seen} module(s) with a customer-managed key")
else:
    note(RULE, "no separate customer-managed key in any module")


# --- 4 -------------------------------------------------------------------
# A Key Vault that denies by default refuses the nodes at the firewall
# however correct their access policy is -- and a virtual network rule
# matches nothing without the service endpoint on the same subnet.
RULE = "a deny-by-default Key Vault must admit the node subnet"
seen = 0
for mod in MODULES:
    text = module_text(mod)
    vaults = resource_bodies(text, "azurerm_key_vault")
    for vname, vbody in vaults.items():
        acl = re.search(r"network_acls\s*\{(.*?)\n  \}", vbody, re.S)
        if not acl or not re.search(r'default_action\s*=\s*"Deny"', acl.group(1)):
            continue
        seen += 1
        allowed = re.search(r"virtual_network_subnet_ids\s*=\s*\[([^\]]*)\]",
                            acl.group(1), re.S)
        subnets = re.findall(r"azurerm_subnet\.(\w+)\.id",
                             allowed.group(1) if allowed else "")
        if not subnets:
            fail(RULE, f"{mod.relative_to(ROOT)}: {vname} denies by default and names "
                       "no subnet — every node fails to start with ForbiddenByFirewall")
            continue
        declared = resource_bodies(text, "azurerm_subnet")
        for s in subnets:
            body = declared.get(s, "")
            if "Microsoft.KeyVault" not in body:
                fail(RULE, f"{mod.relative_to(ROOT)}: subnet {s} is admitted to {vname} "
                           "but carries no Microsoft.KeyVault service endpoint, so the "
                           "rule matches nothing")
if seen:
    note(RULE, f"{seen} deny-by-default Key Vault(s)")
else:
    note(RULE, "no deny-by-default Key Vault in any module")


# --- 5 -------------------------------------------------------------------
# In an inventory plugin's configuration the top-level keys are the
# plugin's own options. Anything that is not one is ignored without a
# word -- ansible_ssh_common_args was, so every connection skipped the
# ProxyCommand and ssh tried to resolve a resource id as a hostname.
RULE = "no connection variables at the top level of a plugin config"
seen = 0
for inv in sorted((ROOT / "ansible" / "inventory").glob("*.yml")):
    text = inv.read_text()
    if not re.search(r"^plugin:\s*\S", text, re.M):
        continue
    seen += 1
    for m in re.finditer(r"^(ansible_\w+)\s*:", text, re.M):
        fail(RULE, f"ansible/inventory/{inv.name}: {m.group(1)} is not a plugin option, "
                   "so it reaches no host. It belongs under compose:, "
                   "hostvar_expressions: or group_vars")
if seen:
    note(RULE, f"{seen} plugin configuration(s)")
else:
    fail(RULE, "no inventory plugin configuration found — this rule checked nothing")


# --- 6 -------------------------------------------------------------------
# A leaf signed at boot and a leaf issued from the control machine have to
# be interchangeable, which CLAUDE.md states and nothing checked. They
# diverged: one learned to emit IP: for an address and the other did not,
# leaving a load balancer SAN that matches nothing.
RULE = "both certificate issuers build the same SANs"
PAIR = [ROOT / "scripts" / "generate-cloud-certs.sh",
        ROOT / "scripts" / "issue-bootstrap-cert.sh"]
if all(p.exists() for p in PAIR):
    shapes = {}
    for p in PAIR:
        t = p.read_text()
        base = re.search(r'SAN="IP:\$\{(\w+)\},DNS:\$\{(\w+)\},DNS:\$\{(\w+)\}'
                         r',DNS:localhost,IP:127\.0\.0\.1"', t)
        # Normalised: the variable names differ between the two by design
        # (ip/node vs LOCAL_IPV4/INSTANCE_ID); the shape must not.
        shapes[p.name] = "IP,DNS,DNS,DNS:localhost,IP:127.0.0.1" if base else "unreadable"
        if not re.search(r"\^\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$", t):
            fail(RULE, f"scripts/{p.name} does not choose IP: over DNS: for an extra SAN "
                       "that is an address; a DNS entry holding an address matches nothing")
    if len(set(shapes.values())) != 1:
        fail(RULE, f"the two issuers build different base SAN sets: {shapes}")
    elif "unreadable" in shapes.values():
        fail(RULE, f"could not read the base SAN set from both issuers: {shapes}")
    else:
        note(RULE, "both build IP, DNS, cluster servername, localhost, 127.0.0.1")
else:
    fail(RULE, "one of the two certificate issuers is missing")


# --- 7 -------------------------------------------------------------------
# The Vault CLI reads $HOME/.vault to find its token helper before running
# any subcommand -- including `vault status`, which needs no token. With
# ProtectHome=true that open fails with EACCES and the CLI exits before it
# has spoken to Vault, so the calling script reports whatever it was
# trying to do as impossible:
#
#   snapshot:  "Could not reach Vault at https://127.0.0.1:8200"
#   pki renew: a renewal timer that has never renewed anything
#
# Three units set it and all three were broken by it, on a real cluster,
# undetected because the local profile runs Vault in Docker with no
# systemd at all.
#
# tmpfs is the replacement rather than read-only: both let the CLI run,
# and tmpfs hides the contents of every home directory instead of exposing
# them for reading.
RULE = "no unit sets ProtectHome=true"
units = sorted((ROOT / "ansible").glob("roles/*/templates/*.service.j2"))
if not units:
    fail(RULE, "no systemd unit templates found — this rule checked nothing")
else:
    offenders = []
    for u in units:
        for i, line in enumerate(u.read_text().splitlines(), 1):
            if line.strip() == "ProtectHome=true":
                offenders.append(f"{u.relative_to(ROOT)}:{i}")
    if offenders:
        fail(RULE, "ProtectHome=true stops the Vault CLI before it starts; "
                   "use tmpfs: " + ", ".join(offenders))
    else:
        note(RULE, f"{len(units)} unit template(s), none of them")


# --- 8 -------------------------------------------------------------------
# Every restart of the Vault service has to be throttled to one host.
#
# Ansible's linear strategy runs a task on every host at once, up to the
# fork count, so an unthrottled `state: restarted` takes the whole cluster
# down together. A three-node Raft cluster with no node running has no
# leader and no quorum; a cluster that auto-unseals comes back by itself,
# which is why this survived a real apply unnoticed.
#
# The rule is about the Vault service specifically. Restarting
# vault-snapshot.timer costs nothing, so it is not covered -- and naming
# the service rather than matching every `state: restarted` is what keeps
# this a rule about availability rather than a rule about spelling.
RULE = "every Vault restart is throttled to one host"


def task_chunks(text):
    """Split a task or handler file into one chunk per list item.

    Ansible tasks are YAML list items, so a chunk starts at a `- ` and
    runs to the next one at the same indent. Text rather than a YAML
    parse because this suite's stated requirements are bash and python3,
    and PyYAML is not among them.
    """
    chunks, current, indent = [], [], None
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("- ") and (indent is None or len(line) - len(stripped) == indent):
            if current:
                chunks.append("\n".join(current))
            current, indent = [line], len(line) - len(stripped)
        elif current:
            current.append(line)
    if current:
        chunks.append("\n".join(current))
    return chunks


task_files = sorted((ROOT / "ansible").glob("roles/*/*/main.yml"))
task_files += sorted((ROOT / "ansible").glob("playbooks/*.yml"))
restarts = []
unthrottled = []
for f in task_files:
    for chunk in task_chunks(f.read_text()):
        if "state: restarted" not in chunk:
            continue
        # `name: vault` and not vault-snapshot.timer, vault-agent, ...
        if not re.search(r"^\s+name:\s+vault\s*$", chunk, re.M):
            continue
        restarts.append(f.relative_to(ROOT))
        if not re.search(r"^\s+throttle:\s*1\s*$", chunk, re.M):
            unthrottled.append(f.relative_to(ROOT))

if not restarts:
    fail(RULE, "no task restarts the vault service — this rule checked nothing")
elif unthrottled:
    fail(RULE, "restarts every node at once, which is an outage on a live "
               "cluster: " + ", ".join(str(u) for u in unthrottled))
else:
    note(RULE, f"{len(restarts)} restart(s), all throttle: 1")


for line in checked:
    print(f"OK {line}")
for line in findings:
    print(f"BAD {line}")
sys.exit(1 if findings else 0)
