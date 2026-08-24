#!/usr/bin/env python3
"""Render ansible/roles/vault/templates/vault.hcl.j2 outside Ansible.

Usage:
    render-config.py <group_vars.yml> [key=value ...]

Reads a group_vars file — normally one scripts/terraform-to-ansible.sh
just generated — layers the role defaults underneath it, applies any
key=value overrides, and prints the rendered vault.hcl to stdout.

The point is to test the template against the values the handoff script
actually produces, rather than against values a test made up. A test that
invents its own variables proves the template renders; it does not prove
the two halves of the handoff agree, which is the part that breaks.

Undefined variables raise instead of rendering empty. Jinja2's default
behaviour would turn a missing kms key id into `kms_key_id = ""` and
produce a config that parses fine and cannot unseal.
"""

import sys
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

REPO_ROOT = Path(__file__).resolve().parents[2]
ROLE = REPO_ROOT / "ansible" / "roles" / "vault"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 1

    variables = yaml.safe_load((ROLE / "defaults" / "main.yml").read_text()) or {}
    variables.update(yaml.safe_load(Path(sys.argv[1]).read_text()) or {})

    for override in sys.argv[2:]:
        key, _, value = override.partition("=")
        variables[key] = value

    # Facts Ansible would gather from the host.
    variables.setdefault("inventory_hostname", "vault-0")
    variables.setdefault("ansible_default_ipv4", {"address": "10.0.1.10"})

    # defaults/main.yml defines the TLS paths in terms of
    # inventory_hostname, so they arrive here as literal Jinja2 rather
    # than as values. Ansible resolves that lazily; do the same.
    env = Environment(
        loader=FileSystemLoader(str(ROLE / "templates")),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )
    for key, value in list(variables.items()):
        if isinstance(value, str) and "{{" in value:
            variables[key] = env.from_string(value).render(variables)

    sys.stdout.write(env.get_template("vault.hcl.j2").render(variables))
    return 0


if __name__ == "__main__":
    sys.exit(main())
