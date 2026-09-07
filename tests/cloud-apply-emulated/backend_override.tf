# Replaces terraform/aws's S3 backend with a local one, for this suite.
#
# Copied into terraform/aws/ by run-tests.sh as
# zz_emulated_backend_override.tf and removed afterwards. As with the
# provider override beside it, the _override.tf suffix is load-bearing:
# Terraform merges override files over the configuration, and a backend
# block in one replaces the backend block in the original.
#
# WHY IT IS SEPARATE FROM provider_override.tf
#
# tests/state-backend copies the provider override too, and it wants the
# real S3 backend -- pointing terraform/aws at an emulated bucket and
# checking the state arrives there is the whole of what it does. Folding
# this block into that file would replace the backend under it and leave
# it asserting nothing, quietly, which is the failure mode this
# repository keeps finding in its own tests.
#
# WHY THIS SUITE WANTS A LOCAL BACKEND
#
# `terraform init -backend=false` skips backend initialisation, which is
# enough for `validate` and not for `apply`: apply refuses to run against
# an uninitialised backend. This suite applies. Its state belongs to a
# throwaway emulator that dies with the process, so a local file is the
# honest place for it -- and whether the real backend works is a
# different question, asked by tests/state-backend.

terraform {
  backend "local" {}
}
