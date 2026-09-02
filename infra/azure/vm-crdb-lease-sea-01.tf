module "net_lease_sea" {
  source = "./modules/network"

  name                = "vm-crdb-lease-sea-01"
  location            = "southeastasia"
  address_space       = "10.0.0.0/16"
  subnet_prefix       = "10.0.1.0/24"
  resource_group_name = azurerm_resource_group.cdb.name
  tags                = var.tags
}

module "vm_crdb_lease_sea_01" {
  source = "./modules/compute"

  name                = "vm-crdb-lease-sea-01"
  location            = "southeastasia"
  resource_group_name = azurerm_resource_group.cdb.name
  subnet_id           = module.net_lease_sea.subnet_id
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key
  os_disk_size_gb     = var.os_disk_size_gb
  tags                = var.tags
}
