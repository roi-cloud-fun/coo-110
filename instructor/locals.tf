###############################################################################
# CF-110 lab_env_student -- locals.tf
###############################################################################

locals {
  name_prefix = "cf110-${var.student_id}"

  common_tags = {
    Course      = "CF-110"
    Student     = var.student_id
    Environment = "Lab"
    ManagedBy   = "terraform"
  }

  lambda_log_group = "/aws/lambda/${local.name_prefix}-slow-function"
}
