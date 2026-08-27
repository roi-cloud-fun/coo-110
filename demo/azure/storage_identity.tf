###############################################################################
# COO-110 Azure demo environment - storage_identity.tf
#
# Chapter 8 (IAM and access) and Chapter 10 (storage) demo faults.
#
# THE CENTRAL AZURE LESSON, AND WHY IT BEATS THE AWS VERSION
# ----------------------------------------------------------
# The managed identity below is granted **Reader** on the storage account. That
# is a CONTROL-PLANE role: it can see the account exists, read its settings,
# list containers through ARM - and cannot read a single byte of blob data.
# Reading blobs with Entra ID needs a DATA-PLANE role such as Storage Blob Data
# Reader.
#
# This is the same shape as the AWS fault (s3:ListBucket granted, s3:GetObject
# not), but it is sharper: in AWS the missing permission is visibly absent from
# the policy. In Azure the identity holds a role whose name sounds entirely
# sufficient, the assignment list looks generous, and the read still fails with
# 403 AuthorizationPermissionMismatch.
#
# An identity with Contributor on a storage account can delete the whole
# account and still not read one blob. That surprises experienced engineers.
###############################################################################

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_user_assigned_identity" "app" {
  name                = "${local.name}-orderflow-identity"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.common_tags
}

resource "azurerm_storage_account" "orders" {
  name                     = replace("${local.name}orders${random_string.suffix.result}", "-", "")
  resource_group_name      = azurerm_resource_group.demo.name
  location                 = azurerm_resource_group.demo.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  # Entra ID auth only - shared keys disabled. This forces the demo down the
  # RBAC path rather than letting a connection string paper over the fault, and
  # it matches how a governed environment is actually configured.
  shared_access_key_enabled = false

  blob_properties {
    delete_retention_policy {
      days = 1
    }
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "orders" {
  name                  = "orders"
  storage_account_id    = azurerm_storage_account.orders.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# CHAPTER 8 / 10 DEMO FAULT - control-plane role only
# ---------------------------------------------------------------------------
# Reader lets the identity describe the storage account. It does NOT let it
# read blobs. The fix is to add Storage Blob Data Reader, scoped as narrowly as
# the workload allows - ideally the container, not the account.
#
# Do NOT add a Storage Blob Data role here.
resource "azurerm_role_assignment" "app_reader" {
  scope                = azurerm_storage_account.orders.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# ---------------------------------------------------------------------------
# CHAPTER 8 DEMO - scope hierarchy
# ---------------------------------------------------------------------------
# The identity gets Reader at the RESOURCE GROUP scope too. Azure RBAC inherits
# downward, so this is additive and harmless - but it gives the instructor two
# assignments at two different scopes to compare, which is what makes the
# "check the scope, not just the role" point concrete.
resource "azurerm_role_assignment" "app_rg_reader" {
  scope                = azurerm_resource_group.demo.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Fixture blobs. The demo lists these successfully through ARM and then fails
# to read one - the same asymmetry the AWS demo turns on.
resource "azurerm_storage_blob" "orders_csv" {
  name                   = "2026-08-27-orders.csv"
  storage_account_name   = azurerm_storage_account.orders.name
  storage_container_name = azurerm_storage_container.orders.name
  type                   = "Block"
  source_content         = "order_id,region,amount,status\n881204,us-east,412.00,settled\n881205,eu-west,89.50,pending\n"
}

resource "azurerm_storage_blob" "orders_readme" {
  name                   = "README.txt"
  storage_account_name   = azurerm_storage_account.orders.name
  storage_container_name = azurerm_storage_container.orders.name
  type                   = "Block"
  source_content         = "OrderFlow order exports. COO-110 Azure demo environment.\n"
}
