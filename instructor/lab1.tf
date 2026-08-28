###############################################################################
# CF-110 lab_env_student -- lab1.tf   (Lab 1: AWS Compute and Storage)
#
# Injected faults, task by task:
#   Task 2  Lambda timeout    -- 30s timeout, function sleeps up to 45s
#   Task 3  S3 AccessDenied   -- role can ListBucket but NOT GetObject
#   Task 4  EBS gp2 volume    -- gp2 so BurstBalance exists as a metric
#
# Task 1 (EC2 system status check failure) is NOT injectable -- see README.md.
# The instance below is real and its status checks are queryable, so the Task 1
# commands run; students will simply find the checks passing.
###############################################################################

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Task 1 -- EC2 instance students investigate
# -----------------------------------------------------------------------------
# INJECTED FAULT (Lab 2 Task 4): the absence of an ingress block here is
# deliberate, not an oversight. This SG is attached to the one instance in the
# stack, which is also the ALB's only target. With no ingress rule the ALB's
# health probes are dropped before they arrive, every target reports unhealthy
# with reason Target.Timeout, and the rejected probes show up in VPC Flow Logs
# as REJECT records. Adding ingress here silently removes the Task 4 fault.
resource "aws_security_group" "lab1_instance" {
  name        = "${local.name_prefix}-app-sg"
  description = "CF-110 app server. Egress only -- no ingress, which is the Lab 2 Task 4 fault. Session Manager provides access."
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "Outbound to SSM, CloudWatch and package repositories."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-app-sg" }

  # Required to migrate a stack that was built before this SG was renamed from
  # -lab1-sg to -app-sg. A rename forces replacement, and the default
  # destroy-then-create order deadlocks: AWS refuses to delete the old group
  # while the instance's ENI still references it, so the apply spins on
  # DependencyViolation until it times out. Creating first lets the instance
  # move to the new group before the old one is deleted.
  #
  # Safe here only because the rename also changes the name -- there is no
  # duplicate-name conflict between the old group and the new one. A future
  # change to this SG that keeps the same `name` would collide, and would need
  # name_prefix instead.
  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lab1_instance" {
  name               = "${local.name_prefix}-lab1-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "lab1_ssm" {
  role       = aws_iam_role.lab1_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "lab1_instance" {
  name = "${local.name_prefix}-lab1-profile"
  role = aws_iam_role.lab1_instance.name
}

# ---------------------------------------------------------------------------
# THE lab instance. One per student, and it carries every role the labs need:
#   Lab 1 Task 1  its status checks are read (the rule-out)
#   Lab 1 Task 4  the gp2 burst volume attaches to it
#   Lab 2 Task 1  its instance profile is MyAppRole, which students trace
#   Lab 2 Task 4  it is the ALB target whose SG blocks the health probe
#
# It runs nginx and serves 200 to itself, which is what makes the Task 4
# diagnosis land: the server works, the probes never arrive.
resource "aws_instance" "lab1_target" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.lab1_instance.id]
  iam_instance_profile   = aws_iam_instance_profile.myapp.name

  user_data = <<-USERDATA
    #!/bin/bash
    dnf install -y nginx
    echo "CF-110 lab app server for student ${var.student_id} - OK" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  USERDATA

  # Detailed monitoring: Task 1 reads StatusCheckFailed_System at 1-minute
  # granularity. On basic monitoring EC2 publishes every 5 minutes, which makes
  # the metric look sparse and the investigation misleading.
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
    Name        = "${local.name_prefix}-app"
    Application = "payments-api"
    Owner       = "cloudops"
  }
}

# -----------------------------------------------------------------------------
# Task 4 -- gp2 volume. gp2 not gp3, because BurstBalance only exists on gp2.
# -----------------------------------------------------------------------------
resource "aws_ebs_volume" "lab1_burst" {
  availability_zone = aws_instance.lab1_target.availability_zone
  size              = 1
  type              = "gp2"
  encrypted         = true
  tags              = { Name = "${local.name_prefix}-burst-volume" }
}

resource "aws_volume_attachment" "lab1_burst" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.lab1_burst.id
  instance_id = aws_instance.lab1_target.id
}

# -----------------------------------------------------------------------------
# Task 2 -- Lambda with an injected timeout fault
# -----------------------------------------------------------------------------
data "archive_file" "lambda_slow" {
  type        = "zip"
  source_file = "${path.module}/scripts/lambda_slow.py"
  output_path = "${path.module}/.build/lambda_slow.zip"
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

resource "aws_iam_role" "lambda_slow" {
  name               = "${local.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_slow.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda_slow" {
  name              = local.lambda_log_group
  retention_in_days = 7
}

resource "aws_lambda_function" "slow" {
  function_name    = "${local.name_prefix}-slow-function"
  role             = aws_iam_role.lambda_slow.arn
  handler          = "lambda_slow.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_slow.output_path
  source_code_hash = data.archive_file.lambda_slow.output_base64sha256

  # INJECTED FAULT: the function sleeps up to 45s against a 30s ceiling.
  #
  # 30 seconds is not arbitrary. The Lab 1 Task 2 Logs Insights query filters on
  # @duration > 25000, so the timeout must sit just above 25s or that query
  # returns zero rows while appearing to work. Verified 2026-08-20.
  timeout = 30

  depends_on = [aws_cloudwatch_log_group.lambda_slow]
}

# Invoke every minute so CloudWatch Logs holds a mix of successes and timeouts
# before the student ever opens the console.
resource "aws_cloudwatch_event_rule" "lambda_drumbeat" {
  name                = "${local.name_prefix}-lambda-drumbeat"
  description         = "Invokes the Lab 1 Lambda every minute so timeout history exists at lab start."
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "lambda_drumbeat" {
  rule = aws_cloudwatch_event_rule.lambda_drumbeat.name
  arn  = aws_lambda_function.slow.arn
}

resource "aws_lambda_permission" "drumbeat" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slow.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_drumbeat.arn
}

# -----------------------------------------------------------------------------
# Task 3 -- S3 bucket plus a role that is denied GetObject
# -----------------------------------------------------------------------------
resource "random_string" "bucket_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_s3_bucket" "lab1_target" {
  bucket        = "${local.name_prefix}-target-${random_string.bucket_suffix.result}"
  force_destroy = true
  tags          = { Name = "${local.name_prefix}-target-bucket" }
}

resource "aws_s3_bucket_public_access_block" "lab1_target" {
  bucket                  = aws_s3_bucket.lab1_target.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "lab1_data" {
  for_each = {
    "data/transactions.csv" = "id,amount,status\n1,120.00,settled\n2,89.50,pending\n"
    "data/README.txt"       = "CF-110 Lab 1 Task 3 target data for student ${var.student_id}.\n"
  }
  bucket       = aws_s3_bucket.lab1_target.id
  key          = each.key
  content      = each.value
  content_type = "text/plain"
}

# The role a student assumes. It can LIST the bucket but not GET objects, so
# `aws s3 ls` succeeds while `aws s3 cp` returns AccessDenied. That asymmetry is
# the whole diagnostic: the failure is action-level, not bucket-level.
data "aws_iam_policy_document" "cross_account_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "cross_account" {
  name               = "${local.name_prefix}-CrossAccountRole"
  assume_role_policy = data.aws_iam_policy_document.cross_account_assume.json
  tags               = { Name = "${local.name_prefix}-CrossAccountRole" }
}

resource "aws_iam_role_policy" "cross_account_s3" {
  name = "S3ListOnly"
  role = aws_iam_role.cross_account.id
  # INJECTED FAULT: s3:GetObject is deliberately absent.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = aws_s3_bucket.lab1_target.arn
    }]
  })
}
