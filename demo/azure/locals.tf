###############################################################################
# COO-110 Azure demo environment - locals.tf
###############################################################################

locals {
  name = var.name_prefix

  common_tags = {
    Course      = "COO-110"
    Environment = "Demo"
    Purpose     = "instructor-demo"
    ManagedBy   = "terraform"
    Application = "OrderFlow"
  }

  # Both web VMs run identical cloud-init. Any behavioural difference between
  # them is therefore network or identity, never the application - which is
  # exactly the conclusion the Chapter 9 demo needs the room to reach.
  web_cloud_init = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - nginx
    write_files:
      - path: /var/www/html/index.html
        content: |
          <html><body>
          <h1>OrderFlow</h1>
          <p>node: NODE_LABEL</p>
          <p>status: ok</p>
          </body></html>
      - path: /var/www/html/health
        content: |
          ok
    runcmd:
      - sed -i "s/NODE_LABEL/$(hostname)/" /var/www/html/index.html
      - systemctl enable --now nginx
  CLOUDINIT
  )
}
