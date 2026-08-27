###############################################################################
# CF-110 demo_environment -  outputs.tf
#
# `terraform output -raw demo_handout` prints every identifier the demo runbook
# needs, ready to paste. Nothing in the runbook uses a placeholder.
###############################################################################

output "alb_dns_name" {
  description = "Browse or curl this to show OrderFlow serving from the healthy node."
  value       = aws_lb.demo.dns_name
}

output "alb_dimension" {
  description = "The LoadBalancer dimension value for CloudWatch metric queries (app/name/id)."
  value       = aws_lb.demo.arn_suffix
}

output "target_group_arn" {
  value = aws_lb_target_group.demo.arn
}

output "orders_bucket" {
  value = aws_s3_bucket.orders.bucket
}

output "dashboard_url" {
  description = "Open this first -  it is the single screen the whole demo works from."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.demo.dashboard_name}"
}

output "demo_handout" {
  description = "Everything the demo runbook needs, in one block."
  value       = <<-EOT
    CF-110 OrderFlow demo environment  (region ${var.region}, account ${data.aws_caller_identity.current.account_id})

    OPEN THIS FIRST
      Dashboard ............ https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.demo.dashboard_name}

    CHAPTER 1 -- methodology, ALB metrics
      ALB DNS .............. ${aws_lb.demo.dns_name}
      ALB dimension ........ ${aws_lb.demo.arn_suffix}
      Target group ......... ${aws_lb_target_group.demo.arn}
      Expect ............... HealthyHostCount 1, UnHealthyHostCount 1

    CHAPTER 2 -- compute
      web-a (healthy) ...... ${aws_instance.web_a.id}
      web-b (unreachable) .. ${aws_instance.web_b.id}
      Lambda ............... ${aws_lambda_function.order_processor.function_name}
      Lambda log group ..... ${local.lambda_log_group}
      Expect ............... status checks ok/ok; Lambda @duration pinned at 30000 on ~1 in 3

    CHAPTER 3 -- IAM and access
      App role ............. ${aws_iam_role.app.arn}
      Reporting role ....... ${aws_iam_role.reporting.arn}
      Settlement role ...... ${aws_iam_role.settlement.arn}
      Web role ............. ${aws_iam_role.web.arn}
      Expect ............... SettlementRole trusts the WEB role, not ReportingRole

    CHAPTER 4 -- network
      Batch worker ......... ${aws_instance.batch.id}
      Private subnet ....... ${aws_subnet.private.id}
      Private route table .. ${aws_route_table.private.id}
      VPC CIDR ............. ${var.vpc_cidr}
      Flow log group ....... ${local.flow_log_group}
      web-b SG ............. ${aws_security_group.web_broken.id}
      ALB SG ............... ${aws_security_group.alb.id}
      Expect ............... private route table has ONE route; REJECTs on port 80
      NAT gateway .......... ${var.create_nat_gateway ? "created" : "NOT created (create_nat_gateway = false)"}

    CHAPTER 5 -- storage
      Orders bucket ........ ${aws_s3_bucket.orders.bucket}
      Sample object ........ s3://${aws_s3_bucket.orders.bucket}/orders/2026-08-26-orders.csv
      gp2 volume ........... ${aws_ebs_volume.burst.id}
      Expect ............... s3 ls allowed, s3 cp AccessDenied, no bucket policy

    CLOUDTRAIL
      Trail ................ ${var.create_cloudtrail ? "${local.name}-trail (S3 data events on the orders bucket)" : "NOT created (create_cloudtrail = false)"}
      Note ................. data events lag by up to ~15 minutes before they
                             appear in lookup-events. Trigger a denied GetObject
                             at the START of the session, then come back to it.

    AWS CONFIG
      Rules ................ ${var.create_config_rules ? "created (evaluate against the account's existing recorder)" : "NOT created (create_config_rules = false)"}

    TEARDOWN
      terraform destroy -var="create_nat_gateway=${var.create_nat_gateway}"
  EOT
}
