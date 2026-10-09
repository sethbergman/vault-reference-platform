# Replaces terraform/aws's S3 backend with a local one, for this suite.
#
# Copied into terraform/aws/ by run-tests.sh as
# zz_leastpriv_backend_override.tf and removed afterwards.
#
# WHY THE BACKEND IS NOT PART OF WHAT THIS PROVES
#
# The state backend needs its own permissions — s3:GetObject, s3:PutObject
# and DynamoDB or S3 native locking on the state bucket — and they belong to
# a different identity question: who may read and write the state, which is
# not who may create the infrastructure. Pointing this suite at the real
# backend would mix the two and make a failure ambiguous.
#
# So the state goes to a local file that dies with the emulator, and
# examples/policies/aws-terraform-apply.json carries no backend permissions
# at all. docs/least-privilege.md says so, and says what to add if the
# identity is also the one running `init`.

terraform {
  backend "local" {}
}
