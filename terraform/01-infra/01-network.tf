###############################################################################
# VPC — shared by both clusters, same shape as the original EKS lab.
#
# Written out as plain resources rather than terraform-aws-modules/vpc: the
# community module reaches for NAT gateway EIP association, flow logs and
# availability-zone lookups that the emulator answers only partially, and the
# explicit version is what the README needs to explain anyway.
#
# Floci substitutes its own Docker-network CIDR when a declared VPC CIDR
# collides with an existing Docker network, and warns when it does. 10.100.0.0/16
# is free on this host, so the declared and actual CIDRs agree.
###############################################################################
resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "advana-ws-mgmt-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "stig-cloud-lab-igw" }
}

# Two AZs because an Application Load Balancer requires subnets in two of them.
# Floci pins the EKS node itself to <region>a regardless.
locals {
  azs = ["${var.region}a", "${var.region}b"]

  private_subnets = {
    "${var.region}a" = cidrsubnet(var.vpc_cidr, 8, 1) # 10.100.1.0/24
    "${var.region}b" = cidrsubnet(var.vpc_cidr, 8, 2) # 10.100.2.0/24
  }

  public_subnets = {
    "${var.region}a" = cidrsubnet(var.vpc_cidr, 8, 11) # 10.100.11.0/24
    "${var.region}b" = cidrsubnet(var.vpc_cidr, 8, 12) # 10.100.12.0/24
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.lab.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name                              = "stig-cloud-lab-private-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.lab.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name                     = "stig-cloud-lab-public-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "stig-cloud-lab-public" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# The original lab put a NAT gateway here so private nodes could pull images.
# Locally the k3s containers pull through the host's Docker daemon, so the NAT
# gateway would be inert cost-shaped metadata. The private route table is kept
# so the topology still reads the same.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "stig-cloud-lab-private" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
