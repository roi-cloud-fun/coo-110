###############################################################################
# COO-110 Azure demo environment - observability.tf
#
# Log Analytics, NSG flow logs, and an Azure Monitor workbook-equivalent
# dashboard. The Azure counterparts of CloudWatch Logs, VPC Flow Logs and the
# CloudWatch dashboard in the AWS demo stack.
#
# THE ONE TO WATCH IS FLOW LOGS
# -----------------------------
# NSG flow logs write to a STORAGE ACCOUNT, not to Log Analytics. Enabling them
# alone gives you JSON blobs and nothing queryable - the KQL table
# AzureNetworkAnalytics_CL only exists when Traffic Analytics is switched on as
# well, which is what the workspace association below does.
#
# That is the Azure version of a trap the AWS labs already teach: a query
# against a table that was never populated returns zero rows and reports
# success, which is indistinguishable from a healthy system.
###############################################################################

resource "azurerm_log_analytics_workspace" "demo" {
  name                = "${local.name}-law"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.common_tags
}

# ---------------------------------------------------------------------------
# NSG flow logs + Traffic Analytics  (Chapter 9 evidence step)
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "flowlogs" {
  count                    = var.create_flow_logs ? 1 : 0
  name                     = replace("${local.name}flow${random_string.suffix.result}", "-", "")
  resource_group_name      = azurerm_resource_group.demo.name
  location                 = azurerm_resource_group.demo.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = local.common_tags
}

# Network Watcher is normally auto-created by Azure per region, in a resource
# group called NetworkWatcherRG. Referencing it rather than creating it avoids
# a conflict on subscriptions where it already exists - which is most of them.
data "azurerm_network_watcher" "demo" {
  count               = var.create_flow_logs ? 1 : 0
  name                = "NetworkWatcher_${var.location}"
  resource_group_name = "NetworkWatcherRG"
}

resource "azurerm_network_watcher_flow_log" "web_b" {
  count                     = var.create_flow_logs ? 1 : 0
  name                      = "${local.name}-web-b-flowlog"
  network_watcher_name      = data.azurerm_network_watcher.demo[0].name
  resource_group_name       = data.azurerm_network_watcher.demo[0].resource_group_name
  location                  = azurerm_resource_group.demo.location
  target_resource_id        = azurerm_network_security_group.web_broken.id
  storage_account_id        = azurerm_storage_account.flowlogs[0].id
  enabled                   = true
  version                   = 2

  retention_policy {
    enabled = true
    days    = 7
  }

  # Without this block the logs land in blob storage and never reach KQL.
  traffic_analytics {
    enabled               = true
    workspace_id          = azurerm_log_analytics_workspace.demo.workspace_id
    workspace_region      = azurerm_log_analytics_workspace.demo.location
    workspace_resource_id = azurerm_log_analytics_workspace.demo.id
    interval_in_minutes   = 10
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Diagnostic settings - route platform logs into the workspace
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "lb" {
  name                       = "${local.name}-lb-diag"
  target_resource_id         = azurerm_lb.demo.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.demo.id

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "storage_blob" {
  name                       = "${local.name}-blob-diag"
  target_resource_id         = "${azurerm_storage_account.orders.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.demo.id

  # StorageRead is what surfaces the denied blob reads in Chapter 10 - the
  # Azure analogue of enabling S3 data events on a CloudTrail trail.
  enabled_log {
    category = "StorageRead"
  }

  enabled_metric {
    category = "Transaction"
  }
}

# ---------------------------------------------------------------------------
# Alerts - the signals a real on-call would page on
# ---------------------------------------------------------------------------

resource "azurerm_monitor_metric_alert" "lb_health" {
  name                = "${local.name}-lb-degraded"
  resource_group_name = azurerm_resource_group.demo.name
  scopes              = [azurerm_lb.demo.id]
  description         = "OrderFlow load balancer has an unhealthy backend. Chapter 6 demo: this is the metric that confirms the hypothesis."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Network/loadBalancers"
    metric_name      = "DipAvailability"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 100
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Dashboard - one screen covering every chapter's signal
# ---------------------------------------------------------------------------

resource "azurerm_portal_dashboard" "demo" {
  name                = "${local.name}-orderflow"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  tags                = local.common_tags

  dashboard_properties = jsonencode({
    lenses = [{
      order = 0
      parts = [
        {
          position = { x = 0, y = 0, colSpan = 6, rowSpan = 2 }
          metadata = {
            type = "Extension/HubsExtension/PartType/MarkdownPart"
            settings = { content = { settings = {
              title   = "OrderFlow - COO-110 Azure demo"
              content = "Deployed broken on purpose. Mirrors the AWS demo stack fault for fault.\n\n- **Ch 6** LB health\n- **Ch 7** VM Resource Health\n- **Ch 8** RBAC control vs data plane\n- **Ch 9** NSG priority + route table\n- **Ch 10** storage RBAC"
            } } }
          }
        },
        {
          position = { x = 6, y = 0, colSpan = 6, rowSpan = 4 }
          metadata = {
            type   = "Extension/HubsExtension/PartType/MonitorChartPart"
            inputs = []
            settings = { content = { options = { chart = {
              title    = "Load balancer backend availability - Ch 6"
              titleKind = 1
              metrics = [{
                resourceMetadata = { id = azurerm_lb.demo.id }
                name             = "DipAvailability"
                aggregationType  = 4
                namespace        = "microsoft.network/loadbalancers"
              }]
            } } } }
          }
        },
      ]
    }]
  })
}
