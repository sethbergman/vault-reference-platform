variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "vault-reference"
}

variable "node_count" {
  type    = number
  default = 3
}
