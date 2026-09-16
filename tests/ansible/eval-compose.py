#!/usr/bin/env python3
"""Evaluate a dynamic inventory's `compose` block the way Ansible does.

`compose` values are Jinja2 expressions, not strings. A literal has to be
quoted inside the expression -- `ansible_user: ec2-user` is an undefined
variable, and an undefined variable composes to nothing rather than to an
error, so the setting silently does not exist and Ansible falls back to
the local username.

Nothing offline catches that. `tests/ansible` checked the file was valid
YAML, which it is either way, and the plugin itself only runs with
credentials in front of a real EC2 API.

So render each expression against a host the way aws_ec2 would, and print
`name<TAB>value` for the caller to assert on. The hostvars below are the
subset of a describe_instances entry these expressions read; add to them
rather than reaching for a real API.

Usage:
    eval-compose.py <inventory.yml>
"""

import io
import sys

import yaml
from jinja2 import Environment

# Shaped like amazon.aws.aws_ec2's per-host vars: boto3 keys converted to
# snake_case, tags as a dict.
HOSTVARS = {
    "instance_id": "i-0123456789abcdef0",
    "private_ip_address": "10.0.2.15",
    "private_dns_name": "ip-10-0-2-15.ec2.internal",
    "placement": {"availability_zone": "us-east-1a"},
    "tags": {"Name": "vault-reference-vault", "VaultCluster": "vault-reference"},
}


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().split('Usage:')[-1].strip(), file=sys.stderr)
        return 2

    with io.open(sys.argv[1], encoding='utf-8') as handle:
        inventory = yaml.safe_load(handle) or {}

    compose = inventory.get('compose') or {}
    if not compose:
        print('no compose block', file=sys.stderr)
        return 1

    env = Environment()
    for name, expression in compose.items():
        # undefined_to_none=False makes an undefined name raise here
        # rather than render as empty, which is the whole point: Ansible
        # would drop the variable, and a test that accepted an empty
        # string would agree with the bug.
        value = env.compile_expression(expression, undefined_to_none=False)(**HOSTVARS)
        print('%s\t%s' % (name, value))
    return 0


if __name__ == '__main__':
    sys.exit(main())
