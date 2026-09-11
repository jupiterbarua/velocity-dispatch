# Dedicated (but deliberately minimal) VPC for this module, replacing the
# account's default VPC. One public subnet, one AZ — this box is a single
# non-HA Spot instance, so there's nothing an extra AZ or a private
# subnet would buy here; see network.tf's comment for the fuller
# reasoning on skipping NAT/private subnets. Everything below is either
# free (VPC, subnet, IGW, route table) or already accounted for elsewhere
# (the Spot instance itself, in main.tf).

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# Single AZ (the first one AWS reports as available in this region) — a
# multi-AZ layout only pays off once you have something to spread across
# it, and this module has exactly one instance.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
