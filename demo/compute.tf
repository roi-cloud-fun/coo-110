###############################################################################
# CF-110 demo_environment -  compute.tf
#
# The OrderFlow web tier and its order-processing Lambda.
#
# THE CENTRAL DESIGN DECISION
# --------------------------
# Two near-identical web instances sit behind one ALB. web-a is reachable and
# healthy; web-b is not, because its security group is missing the ALB ingress
# rule. Both run the same AMI, the same user data, the same web server.
#
# That gives the instructor a controlled comparison -  the single most useful
# real-world technique there is. "One works and one does not, and they differ
# in exactly one way" is a far better teaching scenario than a single broken
# resource, and it produces a genuinely non-zero UnHealthyHostCount for the
# Chapter 1 metric demo while the service itself stays up.
#
# To demo a full outage instead (all targets down, ALB returns 503), see the
# "escalating the scenario" section of README.md.
###############################################################################

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "OrderFlow ALB. Accepts HTTP from anywhere, forwards to the web tier."
  vpc_id      = aws_vpc.demo.id

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

  tags = { Name = "${local.name}-alb-sg" }
}

# The HEALTHY half of the comparison -  permits the ALB security group on 80.
resource "aws_security_group" "web_healthy" {
  name        = "${local.name}-web-a-sg"
  description = "OrderFlow web-a. Correctly allows the ALB security group on port 80."
  vpc_id      = aws_vpc.demo.id

  ingress {
    description     = "HTTP from the ALB only."
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-web-a-sg" }
}

# ---------------------------------------------------------------------------
# CHAPTER 4 / CHAPTER 1 DEMO FAULT -  web-b is unreachable from the ALB
# ---------------------------------------------------------------------------
# No ingress rule at all. The web server on web-b is running and serving 200s
# to itself, but the ALB's health probes are dropped at the boundary, so the
# target reports unhealthy with reason Target.Timeout and the rejected probes
# appear in VPC Flow Logs as REJECT records on port 80.
#
# Do NOT add an ingress rule here.
resource "aws_security_group" "web_broken" {
  name        = "${local.name}-web-b-sg"
  description = "OrderFlow web-b. Deliberately missing ingress from the ALB security group."
  vpc_id      = aws_vpc.demo.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-web-b-sg" }
}

resource "aws_security_group" "batch" {
  name        = "${local.name}-batch-sg"
  description = "OrderFlow batch worker in the private subnet. Egress fully open, so the SG is NOT the fault -  the missing route is."
  vpc_id      = aws_vpc.demo.id

  egress {
    description = "All outbound permitted. Ruling the SG out is part of the Chapter 4 demo."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-batch-sg" }
}

# ---------------------------------------------------------------------------
# Web tier
# ---------------------------------------------------------------------------

locals {
  # Both instances run identical user data. Any behavioural difference between
  # them is therefore network or IAM, never the application -  which is exactly
  # the conclusion the Chapter 4 demo needs students to reach.
  web_userdata = <<-USERDATA
    #!/bin/bash
    dnf install -y nginx
    cat > /usr/share/nginx/html/index.html <<'HTML'
    <html><body>
    <h1>OrderFlow</h1>
    <p>node: NODE_LABEL</p>
    <p>status: ok</p>
    </body></html>
    HTML
    sed -i "s/NODE_LABEL/$(hostname)/" /usr/share/nginx/html/index.html
    cat > /usr/share/nginx/html/health <<'HTML'
    ok
    HTML
    systemctl enable --now nginx
  USERDATA
}

resource "aws_instance" "web_a" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.web_healthy.id]
  iam_instance_profile   = aws_iam_instance_profile.web.name
  user_data              = local.web_userdata

  # Detailed monitoring: the Chapter 2 demo reads CPUUtilization at 1-minute
  # granularity. On basic monitoring EC2 publishes every 5 minutes, which makes
  # a live demo look sparse and unconvincing.
  monitoring = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-web-a"
    Tier = "web"
    Role = "healthy-control"
  }
}

resource "aws_instance" "web_b" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[1].id
  vpc_security_group_ids = [aws_security_group.web_broken.id]
  iam_instance_profile   = aws_iam_instance_profile.web.name
  user_data              = local.web_userdata
  monitoring             = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-web-b"
    Tier = "web"
    Role = "unreachable-from-alb"
  }
}

# Batch worker stranded in the private subnet -  Chapter 4 routing demo.
resource "aws_instance" "batch" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.batch.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-batch-worker"
    Tier = "batch"
    Role = "no-egress"
  }
}

# ---------------------------------------------------------------------------
# CHAPTER 5 DEMO -  gp2 volume so BurstBalance exists as a metric
# ---------------------------------------------------------------------------
# BurstBalance is published for gp2 only. A 1 GiB volume sits exactly on the
# 100 IOPS floor (gp2 grants 3 IOPS/GiB with a 100 minimum), which is what
# makes the "size buys sustained performance" point concrete.
resource "aws_ebs_volume" "burst" {
  availability_zone = aws_instance.web_a.availability_zone
  size              = 1
  type              = "gp2"
  encrypted         = true
  tags              = { Name = "${local.name}-orders-data-volume" }
}

resource "aws_volume_attachment" "burst" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.burst.id
  instance_id = aws_instance.web_a.id
}

# ---------------------------------------------------------------------------
# Application Load Balancer  (Chapter 1 metric demo, Chapter 4 health demo)
# ---------------------------------------------------------------------------

resource "aws_lb" "demo" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "demo" {
  name     = "${local.name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.demo.id

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${local.name}-tg" }
}

resource "aws_lb_target_group_attachment" "web_a" {
  target_group_arn = aws_lb_target_group.demo.arn
  target_id        = aws_instance.web_a.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "web_b" {
  target_group_arn = aws_lb_target_group.demo.arn
  target_id        = aws_instance.web_b.id
  port             = 80
}

resource "aws_lb_listener" "demo" {
  load_balancer_arn = aws_lb.demo.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.demo.arn
  }
}

# ---------------------------------------------------------------------------
# CHAPTER 2 DEMO FAULT -  order processor with an intermittent timeout
# ---------------------------------------------------------------------------

data "archive_file" "order_processor" {
  type        = "zip"
  source_file = "${path.module}/scripts/order_processor.py"
  output_path = "${path.module}/.build/order_processor.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = local.lambda_log_group
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "order_processor" {
  function_name    = "${local.name}-order-processor"
  role             = aws_iam_role.lambda.arn
  handler          = "order_processor.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.order_processor.output_path
  source_code_hash = data.archive_file.order_processor.output_base64sha256

  # INJECTED FAULT: the handler's simulated downstream call sometimes takes
  # longer than this ceiling.
  #
  # 30 seconds is not arbitrary. The demo runbook filters on @duration > 25000,
  # so the timeout must sit just above 25s or that query returns zero rows
  # while appearing to work. If you change this, change the query too.
  timeout     = 30
  memory_size = 128

  environment {
    variables = {
      ORDERS_BUCKET = aws_s3_bucket.orders.bucket
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# Invoke on a schedule so a mix of successes and timeouts already exists in
# CloudWatch Logs before the instructor opens the console.
resource "aws_cloudwatch_event_rule" "lambda_drumbeat" {
  name                = "${local.name}-order-drumbeat"
  description         = "Invokes the OrderFlow processor so timeout history exists at demo time."
  schedule_expression = var.lambda_invoke_rate
}

resource "aws_cloudwatch_event_target" "lambda_drumbeat" {
  rule = aws_cloudwatch_event_rule.lambda_drumbeat.name
  arn  = aws_lambda_function.order_processor.arn
}

resource "aws_lambda_permission" "drumbeat" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.order_processor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_drumbeat.arn
}
