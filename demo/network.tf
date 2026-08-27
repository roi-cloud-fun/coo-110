###############################################################################
# CF-110 demo_environment -  network.tf
#
# VPC for the OrderFlow demo app.
#
#   public-a / public-b  routed to the IGW. Host the ALB and both web tiers.
#   private              INTENTIONALLY has no route to the internet. That
#                        missing route is the Chapter 4 routing demo.
#
# VPC Flow Logs are enabled on the whole VPC and land in CloudWatch Logs, which
# is what the Chapter 4 flow-log demo queries.
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

resource "aws_vpc" "demo" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "demo" {
  vpc_id = aws_vpc.demo.id
  tags   = { Name = "${local.name}-igw" }
}

# An ALB requires subnets in at least two Availability Zones.
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.demo.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.demo.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10)
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${local.name}-private" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.demo.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.demo.id
  }

  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# CHAPTER 4 DEMO FAULT -  private subnet has no egress
# ---------------------------------------------------------------------------
# The private route table below holds a local route ONLY. Even when a NAT
# gateway exists, nothing routes to it.
#
# This fault leaves no trace: no rejected packet, no error, no log entry.
# Traffic addressed outside the VPC CIDR simply has no matching route and is
# discarded. It is found by READING THE ROUTE TABLE, never by looking harder at
# the host -  which is the whole point of pairing it with the ALB fault below,
# where the network records the rejection explicitly.
#
# Do NOT add the 0.0.0.0/0 route here.
resource "aws_eip" "nat" {
  count  = var.create_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "demo" {
  count         = var.create_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${local.name}-nat" }
  depends_on    = [aws_internet_gateway.demo]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.demo.id
  # Deliberately empty. See the block comment above.
  tags = { Name = "${local.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# VPC Flow Logs -> CloudWatch Logs  (Chapter 4 demo evidence)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = local.flow_log_group
  retention_in_days = var.log_retention_days
  tags              = { Name = "${local.name}-flow-logs" }
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name}-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "write-flow-logs"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "demo" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.demo.id
  tags            = { Name = "${local.name}-flow-logs" }
}
