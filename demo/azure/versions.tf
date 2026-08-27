###############################################################################
# COO-110 Azure demo environment - versions.tf
#
# The Azure half of the instructor demo set. Deliberately MIRRORS the AWS
# environment in ../demo_environment/ fault for fault, so the same five
# investigations can be run in both clouds back to back.
#
# WHY THIS EXISTS
# ---------------
# Chapters 6-10 teach Azure troubleshooting but have no labs. Lecturing 110
# slides is a poor substitute for showing the same fault a student has already
# diagnosed in AWS, now in Azure, with different tooling and identical logic.
# The teaching claim of the whole day is "the method transfers" - this stack is
# what makes that claim demonstrable rather than asserted.
#
# THE MAPPING
# -----------
#   Chapter  AWS demo                      Azure equivalent here
#   6        ALB UnHealthyHostCount        LB health probe + Azure Monitor
#   7        EC2 status checks (rule-out)  VM Resource Health + boot diagnostics
#   8        IAM trust / policy simulator  RBAC scope: control vs data plane
#   9        VPC Flow Logs REJECT          NSG rules + Network Watcher IP flow
#   10       S3 ListBucket-not-GetObject   Storage RBAC + firewall
#
# Faults are INTENTIONAL. Do not "fix" them here - the runbook in README.md
# walks the instructor through diagnosing each one live.
###############################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      # A demo stack should tear down cleanly in one command even if someone
      # created something inside the group by hand during the session.
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}
