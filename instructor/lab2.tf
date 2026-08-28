###############################################################################
# CF-110 lab_env_student -- lab2.tf   (Lab 2: AWS IAM and Network)
#
# Injected faults, task by task:
#   Task 1  IAM AccessDenied      -- MyAppRole can ListBucket, not GetObject
#   Task 2  AssumeRole failure    -- TargetRole trusts a principal that is NOT
#                                    SourceRole, so the assumption is denied
#   Task 3  No private egress     -- see network.tf; private route table has no
#                                    0.0.0.0/0 route to the NAT gateway
#   Task 4  ALB health check fail -- target SG does not allow the ALB SG on 80
###############################################################################

# -----------------------------------------------------------------------------
# Task 1 -- EC2 role that is denied s3:GetObject
# -----------------------------------------------------------------------------
resource "aws_iam_role" "myapp" {
  name               = "${local.name_prefix}-MyAppRole"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name_prefix}-MyAppRole" }
}

resource "aws_iam_role_policy" "myapp_s3" {
  name = "S3ListOnly"
  role = aws_iam_role.myapp.id
  # INJECTED FAULT: s3:GetObject absent. Students find this with the Policy
  # Simulator and confirm it against the CloudTrail AccessDenied event.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = aws_s3_bucket.lab1_target.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "myapp_ssm" {
  role       = aws_iam_role.myapp.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "myapp" {
  name = "${local.name_prefix}-MyAppRole-profile"
  role = aws_iam_role.myapp.name
}

# -----------------------------------------------------------------------------
# Task 2 -- cross-account assumption that fails on the trust policy
# -----------------------------------------------------------------------------
resource "aws_iam_role" "source_role" {
  name               = "${local.name_prefix}-SourceRole"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name_prefix}-SourceRole" }
}

resource "aws_iam_role_policy" "source_can_assume" {
  name = "AllowAssumeTarget"
  role = aws_iam_role.source_role.id
  # SourceRole is permitted to try. The denial comes from the TARGET side --
  # which is the point: students must read both halves of the trust
  # relationship, not just the caller's policy.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = aws_iam_role.target_role.arn
    }]
  })
}

# INJECTED FAULT: TargetRole's trust policy names the account root of a
# DIFFERENT principal path -- it trusts the lab1 EC2 role, not SourceRole. An
# AssumeRole call from SourceRole therefore returns AccessDenied, and the fix is
# a one-line trust policy correction naming SourceRole's ARN.
data "aws_iam_policy_document" "target_trust_broken" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.lab1_instance.arn]
    }
  }
}

resource "aws_iam_role" "target_role" {
  name               = "${local.name_prefix}-TargetRole"
  assume_role_policy = data.aws_iam_policy_document.target_trust_broken.json
  tags               = { Name = "${local.name_prefix}-TargetRole" }
}

resource "aws_iam_role_policy" "target_readonly" {
  name = "S3Read"
  role = aws_iam_role.target_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.lab1_target.arn, "${aws_s3_bucket.lab1_target.arn}/*"]
    }]
  })
}

# -----------------------------------------------------------------------------
# Task 3 -- the private subnet with no egress
# -----------------------------------------------------------------------------
# No instance runs here. The task is deliberately diagnosed entirely from subnet
# and VPC objects, which is the realistic case for a scheduled or autoscaled
# workload that is not running when the ticket is raised. This SG exists so that
# students have a real object to rule out in step 2 -- it is fully open on
# egress, so it is NOT the fault. The missing 0.0.0.0/0 route is.
resource "aws_security_group" "lab2_private" {
  name        = "${local.name_prefix}-private-sg"
  description = "CF-110 Lab 2 private subnet workload. Egress is fully open, so the SG is NOT the fault -- the missing route is."
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "All outbound permitted. Ruling the SG out is part of the exercise."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-private-sg" }
}


# -----------------------------------------------------------------------------
# Task 4 -- ALB whose health checks fail
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "CF-110 Lab 2 ALB. Accepts 80 from anywhere, forwards to targets."
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "HTTP from anywhere."
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-alb-sg" }
}

# The Task 4 injected fault does not live here. There is one instance in the
# stack -- cf110-NN-app -- and it is the ALB's only target, so the SG that
# drops the health probes is its own: aws_security_group.lab1_instance, named
# cf110-NN-app-sg, which has egress only and NO ingress at all. That is what
# students read in Task 4 step 3, and the rejected probes it produces are the
# REJECT records the flow-log query returns.


resource "aws_lb" "lab" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = { Name = "${local.name_prefix}-alb" }
}

resource "aws_lb_target_group" "lab" {
  name     = "${local.name_prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.lab.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${local.name_prefix}-tg" }
}

resource "aws_lb_target_group_attachment" "lab" {
  target_group_arn = aws_lb_target_group.lab.arn
  target_id        = aws_instance.lab1_target.id
  port             = 80
}

resource "aws_lb_listener" "lab" {
  load_balancer_arn = aws_lb.lab.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lab.arn
  }
}
