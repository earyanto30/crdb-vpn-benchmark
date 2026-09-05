module "net_replica_japaneast" {
  source = "./modules/network"

  name                = "vm-crdb-replica-japaneast-01"
  location            = "japaneast"
  address_space       = "10.0.0.0/16"
  subnet_prefix       = "10.0.1.0/24"
  resource_group_name = azurerm_resource_group.cdb.name
  tags                = var.tags
}

module "vm_crdb_replica_japaneast_01" {
  source = "./modules/compute"

  name                = "vm-crdb-replica-ea-01"
  location            = "japaneast"
  resource_group_name = azurerm_resource_group.cdb.name
  subnet_id           = module.net_replica_ea.subnet_id
  vm_size             = var.vm_size
  admin_username      = var.admin_username
  ssh_public_key      = var.ssh_public_key
  os_disk_size_gb     = var.os_disk_size_gb
  tags                = var.tags

  # Spot toggle per-VM: true = 60-90% discount, evictable; false = Regular
  spot_enabled         = var.spot_enabled
  spot_eviction_policy = var.spot_eviction_policy
  spot_max_bid_price   = var.spot_max_bid_price
}
