module "vm_crdb_driver_sea_01" {
  source = "./modules/compute"

  name                                 = "vm-crdb-driver-sea-01"
  location                             = "southeastasia"
  resource_group_name                  = azurerm_resource_group.cdb.name
  subnet_id                            = module.net_lease_sea.subnet_id
  vm_size                              = var.vm_size
  admin_username                       = var.admin_username
  ssh_public_key                       = var.ssh_public_key
  os_disk_size_gb                      = var.os_disk_size_gb
  tags                                 = var.tags
  boot_diagnostics_storage_account_uri = azurerm_storage_account.diag.primary_blob_endpoint

  spot_enabled         = false
  spot_eviction_policy = var.spot_eviction_policy
  spot_max_bid_price   = var.spot_max_bid_price
}
