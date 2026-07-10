# Use the account's default VPC/subnet rather than provisioning a new one —
# this is a single box, so a dedicated VPC/NAT gateway would just add cost
# and complexity without a real security benefit here.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Pick the first available subnet deterministically.
data "aws_subnet" "selected" {
  id = sort(data.aws_subnets.default.ids)[0]
}
