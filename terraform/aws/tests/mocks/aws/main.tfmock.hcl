# Shared provider mocks, referenced by every test file via
#   mock_provider "aws" { source = "./tests/mocks/aws" }
# so the fake world is defined once rather than copied per file.
#
# Two kinds of entry here:
#
#   mock_data     — data sources the configuration reads.
#   mock_resource — computed attributes that the AWS provider validates
#                   the *shape* of. Terraform's generated mock values are
#                   random strings, which fail provider-side ARN parsing,
#                   so anything read back as an ARN needs a realistic
#                   stand-in.
#
# Account 123456789012 is AWS's documentation placeholder.

mock_data "aws_availability_zones" {
  defaults = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }
}

mock_data "aws_ami" {
  defaults = {
    id = "ami-0123456789abcdef0"
  }
}

# The provider parses these as JSON documents.
mock_data "aws_iam_policy_document" {
  defaults = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

mock_resource "aws_iam_policy" {
  defaults = {
    arn = "arn:aws:iam::123456789012:policy/mock-policy"
  }
}

mock_resource "aws_iam_role" {
  defaults = {
    arn = "arn:aws:iam::123456789012:role/mock-role"
  }
}

mock_resource "aws_iam_instance_profile" {
  defaults = {
    arn = "arn:aws:iam::123456789012:instance-profile/mock-profile"
  }
}

mock_resource "aws_kms_key" {
  defaults = {
    arn    = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
    key_id = "12345678-1234-1234-1234-123456789012"
  }
}

mock_resource "aws_s3_bucket" {
  defaults = {
    arn = "arn:aws:s3:::mock-vault-snapshots"
  }
}

mock_resource "aws_lb" {
  defaults = {
    arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/mock/1234567890abcdef"
    dns_name = "mock-vault.elb.us-east-1.amazonaws.com"
  }
}

mock_resource "aws_lb_target_group" {
  defaults = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/mock/1234567890abcdef"
  }
}

# Not an ARN, but the provider still checks the prefix.
mock_resource "aws_launch_template" {
  defaults = {
    id = "lt-0123456789abcdef0"
  }
}
