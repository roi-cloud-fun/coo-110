###############################################################################
# COO-110 Azure demo environment - network.tf
#
# VNet for the OrderFlow demo app.
#
#   snet-web      hosts the two web VMs behind the load balancer
#   snet-private  INTENTIONALLY has no route to the internet. That missing
#                 route is the Chapter 9 routing demo, and it is the direct
#                 analogue of the AWS private route table with no 0.0.0.0/0.
###############################################################################

resource "azurerm_resource_group" "demo" {
  name     = "${var.name_prefix}-rg"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "demo" {
  name                = "${var.name_prefix}-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 0)]
}

resource "azurerm_subnet" "private" {
  name                 = "snet-private"
  resource_group_name  = azurerm_resource_group.demo.name
  virtual_network_name = azurerm_virtual_network.demo.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 10)]
}

# ---------------------------------------------------------------------------
# CHAPTER 9 DEMO FAULT - private subnet has no egress
# ---------------------------------------------------------------------------
# The route table below carries a single route that black-holes everything
# leaving the VNet. Azure has no implicit "no route" state the way an AWS route
# table does - every subnet inherits default system routes - so the equivalent
# fault is expressed as an explicit route to "None".
#
# The teaching point is identical to the AWS side: the failure is SILENT. No
# NSG denies it, nothing is logged as blocked, the packet simply has nowhere to
# go. It is found by reading the effective routes, never by looking harder at
# the VM.
#
# Do NOT change this to a NAT gateway route.
resource "azurerm_route_table" "private" {
  name                = "${var.name_prefix}-private-rt"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.common_tags

  route {
    name           = "blackhole-default"
    address_prefix = "0.0.0.0/0"
    next_hop_type  = "None"
  }
}

resource "azurerm_subnet_route_table_association" "private" {
  subnet_id      = azurerm_subnet.private.id
  route_table_id = azurerm_route_table.private.id
}

# Optional NAT gateway, so the fix can be applied live. Off by default.
resource "azurerm_public_ip" "nat" {
  count               = var.create_nat_gateway ? 1 : 0
  name                = "${var.name_prefix}-nat-pip"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_nat_gateway" "demo" {
  count               = var.create_nat_gateway ? 1 : 0
  name                = "${var.name_prefix}-nat"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  sku_name            = "Standard"
  tags                = local.common_tags
}

resource "azurerm_nat_gateway_public_ip_association" "demo" {
  count                = var.create_nat_gateway ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.demo[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

# ---------------------------------------------------------------------------
# Network security groups
# ---------------------------------------------------------------------------

# The HEALTHY half of the comparison. Permits the load balancer's health probes
# via the AzureLoadBalancer service tag, and HTTP from the VNet.
resource "azurerm_network_security_group" "web_healthy" {
  name                = "${var.name_prefix}-web-a-nsg"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.common_tags

  security_rule {
    name                       = "AllowAzureLoadBalancerProbe"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHttpFromVnet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

# ---------------------------------------------------------------------------
# CHAPTER 9 DEMO FAULT - web-b never receives the load balancer's probes
# ---------------------------------------------------------------------------
# A custom Deny rule at priority 100 sits BELOW the platform's default
# AllowAzureLoadBalancerInBound rule (priority 65001), so it wins. nginx on
# web-b is running and serves 200 to itself; the probes are dropped before they
# arrive, so the instance never enters the backend pool.
#
# This is the Azure analogue of the AWS target security group with no ingress
# from the ALB security group - and it teaches something the AWS version does
# not: in Azure the platform ALREADY allows probe traffic by default, so a
# broken probe almost always means a custom rule at a lower priority number is
# overriding it. Priority is the thing to read first.
#
# Do NOT raise this rule's priority number or delete it.
resource "azurerm_network_security_group" "web_broken" {
  name                = "${var.name_prefix}-web-b-nsg"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.common_tags

  security_rule {
    name                       = "DenyHttpInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "batch" {
  name                = "${var.name_prefix}-batch-nsg"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.common_tags

  # Egress is deliberately wide open. Ruling the NSG out is part of the
  # Chapter 9 elimination sequence - the fault is the route table.
  security_rule {
    name                       = "AllowAllOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
