###############################################################################
# CF-110 lab_env_student -- variables.tf
###############################################################################

variable "student_id" {
  description = "Short student identifier, e.g. 01. Prefixes every resource so one shared account hosts the whole class without collisions."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{1,8}$", var.student_id))
    error_message = "student_id must be 1-8 lowercase alphanumeric characters -- it becomes part of an S3 bucket name, which allows only lowercase letters and digits."
  }
}

variable "region" {
  description = "AWS region for the lab stack."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR for the per-student lab VPC. Each student gets their own VPC so Lab 2's routing faults cannot affect anyone else."
  type        = string
  default     = "10.60.0.0/16"
}

variable "instance_type" {
  description = "Instance type for the single lab instance (cf110-NN-app), which serves Lab 1 Task 1, the Lab 1 Task 4 volume, the Lab 2 Task 1 instance profile and the Lab 2 Task 4 ALB target."
  type        = string
  default     = "t3.micro"
}

variable "create_nat_gateway" {
  description = "Create a NAT gateway for Lab 2 Task 3. When true the NAT exists but the private route table deliberately has NO route to it -- that missing route IS the fault students diagnose. Set false to save ~$1/day if you are only running Lab 1."
  type        = bool
  default     = true
}
