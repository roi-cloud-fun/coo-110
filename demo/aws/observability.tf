###############################################################################
# CF-110 demo_environment -  observability.tf
#
# The diagnostic surface the whole course teaches: CloudTrail, CloudWatch
# dashboards and alarms, and optionally AWS Config rules.
#
# THE IMPORTANT ONE IS CLOUDTRAIL DATA EVENTS
# -------------------------------------------
# S3 object-level calls (GetObject, PutObject) are DATA events. They are NOT
# recorded by default -  not by Event history, not by a standard trail. A live
# `lookup-events` for a denied GetObject therefore returns nothing, and the
# demo looks broken when it is actually working correctly.
#
# The trail below fixes that for the demo bucket specifically. It logs data
# events ONLY: management events are already in Event history for 90 days
# without any trail, so duplicating them would add cost for nothing.
###############################################################################

# ---------------------------------------------------------------------------
# CloudTrail -  S3 data events on the orders bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "trail" {
  count         = var.create_cloudtrail ? 1 : 0
  bucket        = "${local.name}-trail-${random_string.bucket_suffix.result}"
  force_destroy = true
  tags          = { Name = "${local.name}-trail-bucket" }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count                   = var.create_cloudtrail ? 1 : 0
  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "trail_bucket" {
  count = var.create_cloudtrail ? 1 : 0

  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail[0].arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/${local.name}-trail"]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/${local.name}-trail"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  count  = var.create_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  policy = data.aws_iam_policy_document.trail_bucket[0].json
}

resource "aws_cloudtrail" "demo" {
  count                      = var.create_cloudtrail ? 1 : 0
  name                       = "${local.name}-trail"
  s3_bucket_name             = aws_s3_bucket.trail[0].id
  enable_logging             = true
  is_multi_region_trail      = false
  enable_log_file_validation = true

  # Data events only -  see the header note. Management events come free from
  # Event history, so logging them here would duplicate cost with no benefit.
  advanced_event_selector {
    name = "OrderFlow bucket data events"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = ["${aws_s3_bucket.orders.arn}/"]
    }
  }

  tags       = { Name = "${local.name}-trail" }
  depends_on = [aws_s3_bucket_policy.trail]
}

# ---------------------------------------------------------------------------
# CloudWatch alarms -  the signals a real on-call would actually page on
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-alb-unhealthy-hosts"
  alarm_description   = "OrderFlow has at least one unhealthy target behind the ALB. Chapter 1 demo: this is the metric that confirms the hypothesis."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.demo.arn_suffix
    TargetGroup  = aws_lb_target_group.demo.arn_suffix
  }

  tags = { Name = "${local.name}-alb-unhealthy-hosts" }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-order-processor-errors"
  alarm_description   = "OrderFlow order processor is failing. Chapter 2 demo: pair this with Duration to show that the errors ARE the timeouts."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.order_processor.function_name
  }

  tags = { Name = "${local.name}-order-processor-errors" }
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "${local.name}-order-processor-duration"
  alarm_description   = "Order processor approaching its 30s ceiling. Threshold sits at 25s deliberately -  it fires BEFORE the timeout, which is the alarm you actually want."
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 25000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.order_processor.function_name
  }

  tags = { Name = "${local.name}-order-processor-duration" }
}

# ---------------------------------------------------------------------------
# CloudWatch dashboard -  one screen covering every chapter's signal
# ---------------------------------------------------------------------------
# Deliberately ordered to match the teaching sequence, so the instructor can
# work left to right down the day: ALB health (Ch1/Ch4), Lambda (Ch2),
# EC2 (Ch2), EBS (Ch5), then the flow-log query (Ch4).

resource "aws_cloudwatch_dashboard" "demo" {
  dashboard_name = "${local.name}-orderflow"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 2,
        properties = {
          markdown = "# OrderFlow -  CF-110 demo environment\nDeployed broken on purpose. Widgets are ordered to match the chapter sequence: **ALB health** (Ch 1, 4) | **Lambda** (Ch 2) | **EC2** (Ch 2) | **EBS** (Ch 5) | **Flow logs** (Ch 4)."
        }
      },
      {
        type = "metric", x = 0, y = 2, width = 12, height = 6,
        properties = {
          title  = "ALB target health -  Ch 1 hypothesis, Ch 4 diagnosis"
          region = var.region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.demo.arn_suffix, "TargetGroup", aws_lb_target_group.demo.arn_suffix, { label = "Healthy" }],
            [".", "UnHealthyHostCount", ".", ".", ".", ".", { label = "Unhealthy" }]
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type = "metric", x = 12, y = 2, width = 12, height = 6,
        properties = {
          title  = "Order processor duration vs its 30s ceiling -  Ch 2"
          region = var.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.order_processor.function_name, { stat = "Maximum", label = "Max" }],
            ["...", { stat = "Average", label = "Average" }]
          ]
          annotations = {
            horizontal = [
              { label = "30s timeout", value = 30000, color = "#d62728" },
              { label = "alarm at 25s", value = 25000, color = "#ff7f0e" }
            ]
          }
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 8, height = 6,
        properties = {
          title  = "Order processor invocations and errors -  Ch 2"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.order_processor.function_name],
            [".", "Errors", ".", "."]
          ]
        }
      },
      {
        type = "metric", x = 8, y = 8, width = 8, height = 6,
        properties = {
          title  = "Web tier CPU -  Ch 2 (a and b should look identical)"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.web_a.id, { label = "web-a (healthy)" }],
            [".", ".", ".", aws_instance.web_b.id, { label = "web-b (unreachable)" }]
          ]
        }
      },
      {
        type = "metric", x = 16, y = 8, width = 8, height = 6,
        properties = {
          title  = "gp2 BurstBalance and queue depth -  Ch 5"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/EBS", "BurstBalance", "VolumeId", aws_ebs_volume.burst.id, { stat = "Average", label = "BurstBalance %" }],
            [".", "VolumeQueueLength", ".", ".", { stat = "Average", label = "Queue length" }]
          ]
        }
      },
      {
        type = "log", x = 0, y = 14, width = 24, height = 6,
        properties = {
          title  = "Rejected health-check probes on port 80 -  Ch 4 evidence"
          region = var.region
          view   = "table"
          # NOTE: no srcAddr filter. A filter written for the wrong CIDR returns
          # zero rows while reporting success, which is indistinguishable from a
          # healthy system. Query broad, confirm rows exist, then narrow.
          query = "SOURCE '${local.flow_log_group}' | fields @timestamp, srcAddr, dstAddr, dstPort, action | filter dstPort = 80 and action = 'REJECT' | sort @timestamp desc | limit 20"
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# AWS Config rules -  OPTIONAL, off by default. Read this before enabling.
# ---------------------------------------------------------------------------
# RULES ONLY. No configuration recorder, no delivery channel.
#
# AWS permits exactly ONE configuration recorder per region per account, and
# most training accounts already have one. Creating a second fails with
# MaxNumberOfConfigurationRecordersExceededException, which would take the
# whole apply down with it.
#
# These rules evaluate against whatever recorder already exists. If the account
# has none, they deploy but never evaluate and display "No results available" - 
# harmless, but pointless. Check first:
#
#   aws configservice describe-configuration-recorder-status
#
# Each rule below is chosen to flag something this environment genuinely gets
# wrong, so the Chapter 1 tools overview has real findings to show rather than
# an empty compliance screen.

resource "aws_config_config_rule" "sg_open_ports" {
  count       = var.create_config_rules ? 1 : 0
  name        = "${local.name}-restricted-common-ports"
  description = "Flags security groups permitting unrestricted access on common ports. The OrderFlow ALB SG allows 0.0.0.0/0 on 80, so this reports NON_COMPLIANT by design."

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  input_parameters = jsonencode({ blockedPort1 = "80" })
}

resource "aws_config_config_rule" "s3_public_read" {
  count       = var.create_config_rules ? 1 : 0
  name        = "${local.name}-s3-no-public-read"
  description = "Confirms the orders bucket is not publicly readable. Expected COMPLIANT -  a useful contrast against the NON_COMPLIANT rule above."

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }
}

resource "aws_config_config_rule" "ebs_encrypted" {
  count       = var.create_config_rules ? 1 : 0
  name        = "${local.name}-ebs-volumes-encrypted"
  description = "Confirms attached EBS volumes are encrypted. Expected COMPLIANT -  every volume in this stack sets encrypted = true."

  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }
}
