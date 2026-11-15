#!/usr/bin/env python3
#
# moto_server.py — moto, with authorization kept and signature checking off
#
# Usage:
#   moto_server.py -p 5000            (any moto.server argument passes through)
#
# WHY NOT `python3 -m moto.server`
#
# Once authorization is switched on, moto checks two things about every
# request: that the SigV4 signature is valid for the access key, and that
# the key's policies permit the action on the resource. The second is what
# tests/state-backend is about. The first cannot pass for Terraform's
# workspace listing, and the reason is worth writing down because it looks
# like a credentials problem and is not one.
#
# Terraform lists the bucket with `?list-type=2&prefix=env:/`, and signs the
# canonical form of that query, `prefix=env%3A%2F`. moto re-signs the
# request to compare, but rebuilds it from werkzeug's `request.url`, which
# has already run the URL through iri_to_uri: percent-encodings are undone
# and re-applied with `:` and `/` treated as safe, so moto signs
# `prefix=env:/` and the two signatures differ. Every listing whose prefix
# needs encoding fails with SignatureDoesNotMatch; the state object's
# GET, HEAD, PUT and DELETE have no such query and pass. Terraform's
# backend performs that listing on every command, so under a verifying
# emulator the narrow identity can never get past `init`.
#
# So this starts moto with the signature comparison replaced by a no-op.
# Authorization is untouched: the access key still has to exist, it still
# identifies the user, and the user's policy is still evaluated against the
# action and the resource ARN. What is given up is the proof that the
# caller holds the secret half of the key, which no assertion in the suite
# relies on -- the suite mints the keys itself a moment earlier.
#
# A no-op rather than a corrected re-signing, because a correction here
# would be a second implementation of SigV4 inside a test, and a test that
# carries its own crypto is a test with a second thing to be wrong about.
import sys

from moto.iam import access_control
from moto.server import main

access_control.IAMRequestBase.check_signature = lambda self: None

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
