# Network for both clusters. They share one VPC deliberately: the workload
# cluster reaches the observability cluster's internal NLB over private
# addresses, so remote-write / Loki / Tempo traffic never leaves the VPC and
# needs no peering, no TLS termination and no public exposure.
#
# One NAT gateway, not one per AZ. A second NAT would buy AZ-independent egress
# for a lab that is torn down the same day, at roughly the cost of everything
# else here combined.

locals {
  # Public subnets exist only to host the NAT gateway and the two internet-facing
  # NLBs (Grafana, Argo CD). Nothing schedules into them.
  public_cidrs  = [for i, _ in var.azs : cidrsubnet(var.cidr_block, 8, i)]
  private_cidrs = [for i, _ in var.azs : cidrsubnet(var.cidr_block, 8, i + 10)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true # EKS private endpoint resolution depends on this

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = var.name })
}

resource "aws_subnet" "public" {
  for_each = { for i, az in var.azs : az => i }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = local.public_cidrs[each.value]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name}-public-${each.key}"
    # Lets the in-tree AWS cloud provider pick these for internet-facing LBs.
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  for_each = { for i, az in var.azs : az => i }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = local.private_cidrs[each.value]

  tags = merge(var.tags, {
    Name = "${var.name}-private-${each.key}"
    # internal-elb: without this the observability ingress NLB sits <pending>.
    "kubernetes.io/role/internal-elb" = "1"
    # Karpenter discovers where to launch nodes by tag rather than by ID, so the
    # NodePool manifests stay free of environment-specific subnet IDs.
    "karpenter.sh/discovery" = var.karpenter_discovery_value
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat" })
}

# The NAT must live in a *public* subnet. In a private one it routes to itself
# and every egress path silently black-holes.
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[var.azs[0]].id
  tags          = merge(var.tags, { Name = var.name })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = merge(var.tags, { Name = "${var.name}-private" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
