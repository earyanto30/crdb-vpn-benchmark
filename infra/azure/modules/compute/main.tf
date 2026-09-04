# ── Per-VM Public IP ───────────────────────────────────────────────────────────
# Auto-derived DNS label for Azure-managed FQDN: <var.name>-<6-char-random>.<region>.cloudapp.azure.com
# 6 chars => ~2B combos, keepers ensures stability until var.name changes.
resource "random_string" "dns_suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
  keepers = {
    name = var.name
  }
}

resource "azurerm_public_ip" "cdb" {
  name                = "pip-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = substr(lower("${var.name}-${random_string.dns_suffix.result}"), 0, 63)
  tags                = var.tags
}

# ── Per-VM Network Interface ──────────────────────────────────────────────────
resource "azurerm_network_interface" "cdb" {
  name                = "nic-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.cdb.id
  }
}

# ── Per-VM Linux Virtual Machine ──────────────────────────────────────────────
resource "azurerm_linux_virtual_machine" "cdb" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = var.tags

  network_interface_ids = [
    azurerm_network_interface.cdb.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  # Ubuntu 24.04 LTS (Noble Numbat) — Azure image reference
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Disable password authentication; SSH key only
  disable_password_authentication = true
}

# ── OS Disk Snapshot (after VM) ───────────────────────────────────────────────
# Incremental snapshot of the managed OS disk, created after VM is provisioned.
# One snapshot per VM (snap-<name>), re-used on subsequent applies unless tainted.
resource "azurerm_snapshot" "os_disk" {
  count                 = var.create_snapshot ? 1 : 0
  name                  = "snap-${var.name}"
  location              = var.location
  resource_group_name   = var.resource_group_name
  create_option         = "Copy"
  source_resource_id    = azurerm_linux_virtual_machine.cdb.os_disk[0].id
  incremental_enabled   = true
  tags                  = var.tags
}
