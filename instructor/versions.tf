###############################################################################
# CF-110 AWS and Azure Troubleshooting Deep Dive -- lab_env_student
#
# Per-student AWS stack for Labs 1 and 2 (Day 1, AWS). One apply per student:
#
#   terraform apply -var="student_id=01"
#
# WHAT THIS MODULE IS
# -------------------
# CF-110 is a *troubleshooting* course. Unlike CF-109, where students build
# monitoring on a healthy instance, here the environment ships BROKEN ON
# PURPOSE. Every resource below either carries an injected fault or exists so a
# student can prove where the fault is not.
#
# Labs 3 and 4 are Azure and are NOT covered by this module -- see README.md.
#
# NOT hand-written by generate_setup_artifacts.py: that generator emitted a
# CodeCommit/CodePipeline/CodeBuild/EKS tree (the IO-107 SDLC template) because
# the gap analyzer reports zero gaps for CF-110 -- the labs document their own
# infrastructure in prose, so nothing registers as "missing". The generated tree
# is archived at ../_archive/lab_environment_WRONG_generated_sdlc_template_2026-08-20.
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
