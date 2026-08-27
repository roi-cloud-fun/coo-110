###############################################################################
# COO-110 Azure demo environment - outputs.tf
###############################################################################

output "resource_group" {
  value = azurerm_resource_group.demo.name
}

output "lb_public_ip" {
  description = "Browse or curl this to show OrderFlow serving from the healthy node."
  value       = azurerm_public_ip.lb.ip_address
}

output "storage_account" {
  value = azurerm_storage_account.orders.name
}

output "identity_principal_id" {
  description = "The managed identity holding Reader but no data-plane role. Chapter 8 and 10 both turn on this."
  value       = azurerm_user_assigned_identity.app.principal_id
}

output "demo_handout" {
  description = "Everything the Azure demo runbook needs, in one block."
  value       = <<-EOT
    COO-110 OrderFlow Azure demo  (${var.location}, subscription ${var.subscription_id})

    RESOURCE GROUP ....... ${azurerm_resource_group.demo.name}

    CHAPTER 6 -- methodology, LB metrics
      LB public IP ....... ${azurerm_public_ip.lb.ip_address}
      Load balancer ...... ${azurerm_lb.demo.name}
      Expect ............. DipAvailability below 100; one backend never joins

    CHAPTER 7 -- compute
      web-a (healthy) .... ${azurerm_linux_virtual_machine.web_a.name}
      web-b (probe blocked) ${azurerm_linux_virtual_machine.web_b.name}
      Expect ............. Resource Health "Available" on BOTH - the rule-out

    CHAPTER 8 -- IAM and access
      Managed identity ... ${azurerm_user_assigned_identity.app.name}
      Principal ID ....... ${azurerm_user_assigned_identity.app.principal_id}
      Expect ............. Reader at 2 scopes, NO Storage Blob Data role

    CHAPTER 9 -- network
      web-b NSG .......... ${azurerm_network_security_group.web_broken.name}
      batch worker ....... ${azurerm_linux_virtual_machine.batch.name}
      private route table  ${azurerm_route_table.private.name}
      VNet CIDR .......... ${var.vnet_cidr}
      Expect ............. custom Deny at priority 100 beats the platform
                           default at 65001; 0.0.0.0/0 next hop = None
      NAT gateway ........ ${var.create_nat_gateway ? "created" : "NOT created (create_nat_gateway = false)"}

    CHAPTER 10 -- storage
      Storage account .... ${azurerm_storage_account.orders.name}
      Container .......... ${azurerm_storage_container.orders.name}
      Shared keys ........ DISABLED - Entra ID auth only, so RBAC is the only path
      Expect ............. az storage account show succeeds,
                           az storage blob download fails 403

    LOG ANALYTICS
      Workspace .......... ${azurerm_log_analytics_workspace.demo.name}
      Flow logs .......... ${var.create_flow_logs ? "enabled with Traffic Analytics" : "NOT enabled (create_flow_logs = false)"}
      Note ............... Traffic Analytics aggregates on a 10-minute interval.
                           AzureNetworkAnalytics_CL stays EMPTY until the first
                           batch lands - allow 20-30 min after deploy.

    TEARDOWN
      terraform destroy -var="subscription_id=${var.subscription_id}"
  EOT
}
