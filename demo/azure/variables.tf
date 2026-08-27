###############################################################################
# COO-110 Azure demo environment - variables.tf
###############################################################################

variable "subscription_id" {
  description = "Azure subscription to deploy into. Get it with: az account show --query id -o tsv"
  type        = string
}

variable "location" {
  description = "Azure region. Keep it close to the room - Resource Health and metrics both lag slightly further away."
  type        = string
  default     = "eastus"
}

variable "name_prefix" {
  description = "Prefix for every resource. Distinct from the AWS demo's cf110-demo- so the two stacks are never confused in a shared console session."
  type        = string
  default     = "coo110-demo"
}

variable "vnet_cidr" {
  description = <<-DESC
    CIDR for the demo VNet.

    Deliberately 10.90.0.0/16 - distinct from the AWS demo VPC (10.80.0.0/16)
    and the AWS student labs (10.60.0.0/16). A flow-log or IP-flow query written
    for one range must not silently return nothing against another; that failure
    mode is itself a teaching point in both clouds.
  DESC
  type        = string
  default     = "10.90.0.0/16"
}

variable "vm_size" {
  description = "VM size. B-series is burstable and cheap; these VMs serve one nginx page."
  type        = string
  default     = "Standard_B1s"
}

variable "admin_username" {
  description = "Local admin username on the demo VMs. Access is via Azure Bastion or the serial console, never SSH from the internet - no public SSH is opened."
  type        = string
  default     = "azureuser"
}

# ---------------------------------------------------------------------------
# Cost and blast-radius controls
# ---------------------------------------------------------------------------

variable "create_nat_gateway" {
  description = <<-DESC
    Create a NAT gateway so the private subnet could reach the internet.

    Chapter 9's routing demo presents identically either way - the private route
    table has no default route regardless. Leave this false unless you intend to
    apply the fix live in front of the room.
  DESC
  type        = bool
  default     = false
}

variable "create_flow_logs" {
  description = <<-DESC
    Enable NSG flow logs into the demo storage account.

    This is what makes the Chapter 9 evidence step work - the Azure analogue of
    VPC Flow Logs. It requires Network Watcher to be enabled in the region,
    which Azure usually does automatically but some subscriptions disable.

    Check first:
      az network watcher list --query "[?location=='eastus'].name" -o tsv
  DESC
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the Log Analytics workspace. Short by design - this is a demo, not an archive. 30 is the minimum Azure allows."
  type        = number
  default     = 30
}
