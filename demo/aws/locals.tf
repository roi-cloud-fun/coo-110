###############################################################################
# CF-110 demo_environment -  locals.tf
###############################################################################

locals {
  name = var.name_prefix

  common_tags = {
    Course      = "CF-110"
    Environment = "Demo"
    Purpose     = "instructor-demo"
    ManagedBy   = "terraform"
    Application = "OrderFlow"
  }

  # Log group names are referenced from the dashboard and the demo runbook, so
  # they are defined once here rather than inline.
  flow_log_group   = "/${local.name}/vpc-flow-logs"
  lambda_log_group = "/aws/lambda/${local.name}-order-processor"
  trail_log_group  = "/${local.name}/cloudtrail"
  web_log_group    = "/${local.name}/orderflow-web"
}
