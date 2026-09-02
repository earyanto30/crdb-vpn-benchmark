module "net_replica_ea" {
  source = "./modules/network"

  name                = "vm-crdb-replica-ea-01"
  location            = "eastasia"
  address_space       = "10.0.0.0/16"
  subnet_prefix       = "10.0.1.0/24"
  resource_group_name = azurerm_resource_group.cdb.name
  tags                = var.tags
}

module "vm_crdb_replica_ea_01" {
  source = "./modules/compute"

  name                = "vm-crdb-replica-ea-01"
  location            = "eastasia"
  resource_group_name = azurerm_resource_group.cdb.name
  subnet_id           = module.net_replica_ea.subnet_id
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key
  os_disk_size_gb     = var.os_disk_size_gb
  tags                = var.tags
}
