###############################################################################
# CF-110 demo_environment -  variables.tf
###############################################################################

variable "region" {
  description = "Region to deploy the demo environment into."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for every resource name. Kept distinct from the student labs' cf110-<student-id>- prefix so the two are never confused in a console list."
  type        = string
  default     = "cf110-demo"
}

variable "vpc_cidr" {
  description = "CIDR for the demo VPC. Deliberately different from the student lab's 10.60.0.0/16 -  a flow-log query written for one range must not silently return zero rows against the other."
  type        = string
  default     = "10.80.0.0/16"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

# ---------------------------------------------------------------------------
# Cost and blast-radius controls
# ---------------------------------------------------------------------------

variable "create_nat_gateway" {
  description = <<-DESC
    Create a NAT gateway for the private subnet. Roughly $1.10 per day, the
    single largest line item in this stack.

    Chapter 4's routing demo presents identically either way -  the private
    route table is missing its default route regardless. Set this to false
    unless you intend to demonstrate applying the fix live.
  DESC
  type        = bool
  default     = false
}

variable "create_cloudtrail" {
  description = <<-DESC
    Create a CloudTrail trail scoped to S3 data events on the demo bucket.

    This is what makes the Chapter 3 and Chapter 5 CloudTrail demos work.
    S3 object-level calls are DATA events and are not recorded by default, so
    without this a live `lookup-events` for GetObject returns nothing and the
    demo appears broken.

    Management events (AssumeRole, IAM changes) are already visible in
    CloudTrail Event history for 90 days without any trail, so this trail
    deliberately does NOT duplicate them -  that keeps it cheap.
  DESC
  type        = bool
  default     = true
}

variable "create_config_rules" {
  description = <<-DESC
    Create AWS Config rules for the Chapter 1 tools-overview demo.

    IMPORTANT: this creates RULES ONLY. It does not create a configuration
    recorder or delivery channel, because AWS allows exactly ONE recorder per
    region per account and most training accounts already have one. Creating a
    second fails with MaxNumberOfConfigurationRecordersExceededException.

    Rules evaluate against whatever recorder already exists. If the account has
    no recorder at all, the rules deploy but never evaluate and show as
    "No results available" -  set this to false in that case, or enable Config
    manually in the console first.

    Verify before enabling:
      aws configservice describe-configuration-recorder-status
  DESC
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention for every CloudWatch log group this stack creates. Short by design -  this is a demo environment, not an archive."
  type        = number
  default     = 7
}

variable "lambda_invoke_rate" {
  description = "How often EventBridge invokes the order processor. A history of successes and timeouts must exist before the instructor opens the console, so this runs on a schedule rather than on demand."
  type        = string
  default     = "rate(1 minute)"
}
