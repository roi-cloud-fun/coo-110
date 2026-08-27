###############################################################################
# COO-110 Azure demo environment - compute.tf
#
# Two near-identical web VMs behind a Standard Load Balancer, plus a batch
# worker stranded in the private subnet.
#
# Same design decision as the AWS side: web-a and web-b run the SAME image and
# the SAME cloud-init. They differ in exactly one way - web-b's NSG carries a
# custom Deny rule that outranks the platform's default probe allowance. That
# controlled comparison is the most useful real-world technique there is, and
# it produces a genuinely degraded load balancer while the service stays up.
###############################################################################

resource "random_password" "vm_admin" {
  length      = 24
  special     = true
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
  min_special = 1
}

# ---------------------------------------------------------------------------
# NICs
# ---------------------------------------------------------------------------

resource "azurerm_network_interface" "web_a" {
  name                = "${local.name}-web-a-nic"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.web.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "web_b" {
  name                = "${local.name}-web-b-nic"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.web.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "batch" {
  name                = "${local.name}-batch-nic"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Dynamic"
  }
}

# NSGs attach to the NIC here rather than the subnet, so web-a and web-b can
# differ while sharing one subnet - which is what makes them comparable.
resource "azurerm_network_interface_security_group_association" "web_a" {
  network_interface_id      = azurerm_network_interface.web_a.id
  network_security_group_id = azurerm_network_security_group.web_healthy.id
}

resource "azurerm_network_interface_security_group_association" "web_b" {
  network_interface_id      = azurerm_network_interface.web_b.id
  network_security_group_id = azurerm_network_security_group.web_broken.id
}

resource "azurerm_network_interface_security_group_association" "batch" {
  network_interface_id      = azurerm_network_interface.batch.id
  network_security_group_id = azurerm_network_security_group.batch.id
}

# ---------------------------------------------------------------------------
# Virtual machines
# ---------------------------------------------------------------------------

resource "azurerm_linux_virtual_machine" "web_a" {
  name                            = "${local.name}-web-a"
  resource_group_name             = azurerm_resource_group.demo.name
  location                        = azurerm_resource_group.demo.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = random_password.vm_admin.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.web_a.id]
  custom_data                     = local.web_cloud_init

  # Chapter 7 reads boot diagnostics. Without this the serial log and screenshot
  # are unavailable and half that demo cannot run.
  boot_diagnostics {}

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  tags = merge(local.common_tags, { Tier = "web", Role = "healthy-control" })
}

resource "azurerm_linux_virtual_machine" "web_b" {
  name                            = "${local.name}-web-b"
  resource_group_name             = azurerm_resource_group.demo.name
  location                        = azurerm_resource_group.demo.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = random_password.vm_admin.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.web_b.id]
  custom_data                     = local.web_cloud_init

  boot_diagnostics {}

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  tags = merge(local.common_tags, { Tier = "web", Role = "probe-blocked" })
}

resource "azurerm_linux_virtual_machine" "batch" {
  name                            = "${local.name}-batch-worker"
  resource_group_name             = azurerm_resource_group.demo.name
  location                        = azurerm_resource_group.demo.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = random_password.vm_admin.result
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.batch.id]

  boot_diagnostics {}

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  tags = merge(local.common_tags, { Tier = "batch", Role = "no-egress" })
}

# ---------------------------------------------------------------------------
# Load balancer  (Chapter 6 metric demo, Chapter 9 probe demo)
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "lb" {
  name                = "${local.name}-lb-pip"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_lb" "demo" {
  name                = "${local.name}-lb"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  sku                 = "Standard"
  tags                = local.common_tags

  frontend_ip_configuration {
    name                 = "frontend"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "demo" {
  name            = "${local.name}-backend"
  loadbalancer_id = azurerm_lb.demo.id
}

resource "azurerm_lb_probe" "demo" {
  name                = "${local.name}-http-probe"
  loadbalancer_id     = azurerm_lb.demo.id
  protocol            = "Http"
  port                = 80
  request_path        = "/health"
  interval_in_seconds = 15
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "demo" {
  name                           = "${local.name}-http"
  loadbalancer_id                = azurerm_lb.demo.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.demo.id]
  probe_id                       = azurerm_lb_probe.demo.id
}

resource "azurerm_network_interface_backend_address_pool_association" "web_a" {
  network_interface_id    = azurerm_network_interface.web_a.id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.demo.id
}

resource "azurerm_network_interface_backend_address_pool_association" "web_b" {
  network_interface_id    = azurerm_network_interface.web_b.id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.demo.id
}

# A Standard LB gives no outbound internet by default, so the web VMs cannot
# reach package repositories without this. Without it cloud-init never installs
# nginx and BOTH nodes look broken, which would destroy the comparison the
# Chapter 9 demo depends on.
resource "azurerm_lb_outbound_rule" "demo" {
  name                    = "${local.name}-outbound"
  loadbalancer_id         = azurerm_lb.demo.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.demo.id

  frontend_ip_configuration {
    name = "frontend"
  }
}
