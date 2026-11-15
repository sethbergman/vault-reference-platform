#!/usr/bin/env python3
#
# state_identity.py — the narrow identity the state-backend suite runs as,
#                     and the recording that says what it needed
#
# Usage:
#   state_identity.py create  <endpoint> <policy.json> <user>
#                             [--without ACTION] [--object-prefix NAME]
#   state_identity.py enforce <endpoint>
#   state_identity.py derive  <recording.jsonl> <bucket>
#
# `create` prints `<access_key_id> <secret_access_key>` on stdout and nothing
# else, so the caller can read it with `read`. Everything else goes to stderr.
#
# WHAT THIS DOES
#
# `create` makes an IAM user in the emulator whose only permission is the
# state policy terraform/aws/bootstrap emits -- as emitted, or with one
# action removed (--without), or with every object ARN moved under another
# cluster's prefix (--object-prefix). It has to run BEFORE `enforce`: moto
# lets requests through unauthenticated until told otherwise, which is what
# makes setup possible at all, and POSTing 0 to /moto-api/reset-auth ends
# that for every request afterwards. So the suite creates every identity it
# will need, then enforces once.
#
# `derive` reads moto's request recording and names the IAM action each S3
# request needed, printing the distinct set sorted, one per line. A request
# shape it cannot name is a failure rather than a skip: it means Terraform's
# backend has started asking the bucket something this file does not know
# about, and the policy has to be looked at rather than assumed.
#
# WHY THE POLICY CAN BE HANDED TO THE EMULATOR AS WRITTEN
#
# moto authorizes S3 against names of its own (moto/s3/responses.py,
# ACTION_MAP), and for much of S3 they are not IAM's: a bucket HEAD is
# checked as `s3:HeadBucket`, which IAM does not have, and the bucket
# sub-resources do not line up either. That is why tests/least-privilege-apply
# hands the emulator `s3:*` and leaves the apply policy's 22 S3 actions
# unverified.
#
# Terraform's S3 backend makes FIVE request shapes -- recorded on 2026-11-14
# against Terraform 1.15.9 with use_lockfile = true, across init, plan, two
# applies, a contested lock, destroy and `state list`; 39 requests, nothing
# else, and not one of them to KMS:
#
#   GET    /bucket?list-type=2&prefix=env:/   s3:ListBucket    (moto: ListBucket)
#   HEAD   /bucket/<key>                      s3:GetObject     (moto: GetObject)
#   GET    /bucket/<key>[.tflock]             s3:GetObject     (moto: GetObject)
#   PUT    /bucket/<key>[.tflock]             s3:PutObject     (moto: PutObject)
#   DELETE /bucket/<key>.tflock               s3:DeleteObject  (moto: DeleteObject)
#
# For those five, moto's names and IAM's coincide. So the policy goes to the
# emulator exactly as the module emits it, no translation anywhere, and the
# emulator answers the real question -- including the resource: moto
# evaluates S3 requests against `arn:aws:s3:::bucket/key`, so the scoping to
# one cluster's prefix is checked as written, which is the one thing the
# apply policy's `Resource: "*"` cannot offer.
#
# `derive` is the other half of that bargain. It names requests by shape,
# deliberately no wider than the five above, so that a sixth shape fails
# here instead of being quietly covered by a name that happened to match.
import json
import re
import sys
from urllib.parse import urlparse

import boto3
import requests


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def create(argv):
    endpoint, policy_path, user = argv[:3]
    without = None
    prefix = None
    rest = argv[3:]
    while rest:
        flag, value, rest = rest[0], rest[1], rest[2:]
        if flag == "--without":
            without = value
        elif flag == "--object-prefix":
            prefix = value
        else:
            die(f"unknown option {flag}")

    doc = json.load(open(policy_path, encoding="utf-8"))
    statements = []
    for s in doc["Statement"]:
        s = dict(s)
        s["Action"] = list(s["Action"])
        if without and without in s["Action"]:
            s["Action"].remove(without)
            print(f"{user}: removed {without}", file=sys.stderr)
            without = None
        if prefix:
            # arn:aws:s3:::bucket/<cluster>/* -> arn:aws:s3:::bucket/<prefix>/*
            # Bucket-level ARNs have no slash and are left alone.
            m = re.match(r"^(arn:aws:s3:::[^/]+)/.+$", s["Resource"])
            if m:
                s["Resource"] = f"{m.group(1)}/{prefix}/*"
                print(f"{user}: objects scoped to {s['Resource']}", file=sys.stderr)
        if s["Action"]:
            statements.append(s)
    if without:
        die(f"{without} is not in {policy_path}, so removing it proves nothing")

    iam = boto3.client("iam", endpoint_url=endpoint, region_name="us-east-1",
                       aws_access_key_id="setup", aws_secret_access_key="setup")
    iam.create_user(UserName=user)
    iam.put_user_policy(
        UserName=user, PolicyName="reach-the-state",
        PolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": statements}))
    key = iam.create_access_key(UserName=user)["AccessKey"]
    print(f"{key['AccessKeyId']} {key['SecretAccessKey']}")


def enforce(argv):
    (endpoint,) = argv
    r = requests.post(f"{endpoint}/moto-api/reset-auth", data=b"0", timeout=10)
    r.raise_for_status()
    print("authorization is on for every request from here", file=sys.stderr)


def name_action(method, path, query, bucket):
    """The IAM action one recorded S3 request needed, or None."""
    rest = path[len(bucket) + 1:]  # path is /bucket[/key]
    if rest in ("", "/"):
        if method == "GET" and "list-type=2" in query:
            return "s3:ListBucket"
        return None
    if "versionId=" in query:
        return None  # s3:GetObjectVersion territory; not something seen yet
    return {
        "HEAD": "s3:GetObject",
        "GET": "s3:GetObject",
        "PUT": "s3:PutObject",
        "DELETE": "s3:DeleteObject",
    }.get(method)


def service_of(entry):
    auth = entry["headers"].get("Authorization", "")
    if "Credential=" not in auth:
        return None
    return auth.split("Credential=")[1].split(",")[0].split("/")[3]


def derive(argv):
    recording, bucket = argv
    needed = set()
    unknown = []
    for line in open(recording, encoding="utf-8"):
        if not line.strip():
            continue
        entry = json.loads(line)
        if service_of(entry) != "s3":
            continue
        url = urlparse(entry["url"])
        if not url.path.startswith(f"/{bucket}"):
            continue
        action = name_action(entry["method"], url.path, url.query, bucket)
        if action is None:
            unknown.append(f"{entry['method']} {url.path}?{url.query}")
        else:
            needed.add(action)
    if unknown:
        for u in unknown:
            print(f"UNKNOWN REQUEST SHAPE: {u}", file=sys.stderr)
        sys.exit(2)
    if not needed:
        die("the recording holds no S3 requests for this bucket; was recording on?")
    print("\n".join(sorted(needed)))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        die("usage: state_identity.py create|enforce|derive ... (see the header)")
    {"create": create, "enforce": enforce, "derive": derive}.get(
        sys.argv[1], lambda _: die(f"unknown subcommand {sys.argv[1]}"))(sys.argv[2:])
