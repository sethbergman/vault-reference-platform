#!/usr/bin/env python3
#
# setup_identity.py — create the narrow IAM identity the suite applies as
#
# Usage:
#   setup_identity.py <endpoint> <policy.json> [--without ACTION]
#
# Prints `<access_key_id> <secret_access_key>` on stdout and nothing else, so
# the caller can read it with `read`. Everything else goes to stderr.
#
# WHAT THIS DOES
#
# Creates an IAM user whose only permission is the policy file, mints an
# access key for it, and then switches the emulator's authorization on. moto
# lets the first N actions through unauthenticated so that setup like this
# can happen; POSTing 0 to /moto-api/reset-auth ends that.
#
# --without removes one action, which is how the suite checks that its own
# positive result means anything.
#
# WHY s3:* IS ADDED
#
# moto names S3 actions from botocore OPERATION names rather than IAM action
# names. A bucket HEAD is checked as `s3:HeadBucket`, which IAM does not have
# at all, and the bucket sub-resources do not line up either. Handing the
# emulator the real S3 statement would fail on names that are correct.
#
# So S3 is excluded from what this run proves, explicitly and in one place,
# rather than by writing emulator names into a policy meant for AWS. The S3
# half of that file is derived from the recorded requests and is NOT verified
# here; docs/least-privilege.md says so.
import json
import sys

import boto3
import requests

endpoint, policy_path = sys.argv[1:3]
without = None
if len(sys.argv) > 4 and sys.argv[3] == "--without":
    without = sys.argv[4]

doc = json.loads(open(policy_path, encoding="utf-8").read())
actions = sorted({a for s in doc["Statement"] for a in s["Action"]})
if without:
    if without not in actions:
        sys.exit(f"{without} is not in {policy_path}, so removing it proves nothing")
    actions.remove(without)
    print(f"removed {without}", file=sys.stderr)

# Not in the shipped policy. See WHY s3:* IS ADDED above.
actions = [a for a in actions if not a.startswith("s3:")] + ["s3:*"]

iam = boto3.client("iam", endpoint_url=endpoint, region_name="us-east-1",
                   aws_access_key_id="setup", aws_secret_access_key="setup")
iam.create_user(UserName="terraform-apply")
iam.put_user_policy(
    UserName="terraform-apply", PolicyName="apply-the-vault-profile",
    PolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Action": actions, "Resource": "*"}]}))
key = iam.create_access_key(UserName="terraform-apply")["AccessKey"]

r = requests.post(f"{endpoint}/moto-api/reset-auth", data=b"0", timeout=10)
r.raise_for_status()
print(f"authorization is on; {len(actions)} actions allowed", file=sys.stderr)

print(f"{key['AccessKeyId']} {key['SecretAccessKey']}")
