###############################################################################
# CF-110 demo_environment -  versions.tf
#
# Instructor demo environment for CF-110 AWS Troubleshooting Deep Dive.
#
# WHAT THIS IS
# ------------
# One coherent application -  "OrderFlow", a small order-processing service - 
# deployed broken on purpose, with the full AWS observability stack wired up
# around it: VPC Flow Logs, CloudTrail (including S3 data events), CloudWatch
# dashboards and alarms, and optional AWS Config rules.
#
# It exists so an instructor can run every chapter demo live against real
# infrastructure instead of reading placeholder commands off a slide. It is
# NOT the student lab environment -  that is `../lab_environment/`, deployed
# once per student. This is deployed once, by the instructor, for the front of
# the room.
#
# WHY IT IS SEPARATE FROM THE STUDENT LAB
# ---------------------------------------
# 1. Demos happen during chapters, before students touch the labs. Sharing a
#    stack would mean demoing against an environment students later modify.
# 2. This stack carries account-level resources (a CloudTrail trail, optionally
#    Config rules) that must not be multiplied per student.
# 3. Its VPC CIDR is 10.80.0.0/16, deliberately distinct from the student lab's
#    10.60.0.0/16, so a flow-log query written for one cannot silently return
#    zero rows against the other.
#
# Faults are INTENTIONAL. Do not "fix" them in Terraform -  the demo runbook in
# README.md walks the instructor through diagnosing each one live.
###############################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}
