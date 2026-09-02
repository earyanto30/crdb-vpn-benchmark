output "vnet_name" {
  description = "Name of the VNet."
  value       = azurerm_virtual_network.cdb.name
}

output "vnet_id" {
  description = "ID of the VNet."
  value       = azurerm_virtual_network.cdb.id
}

output "subnet_name" {
  description = "Name of the subnet."
  value       = azurerm_subnet.cdb.name
}

output "subnet_id" {
  description = "ID of the subnet (to wire into compute module)."
  value       = azurerm_subnet.cdb.id
}

output "nsg_name" {
  description = "Name of the NSG."
  value       = azurerm_network_security_group.cdb.name
}

output "network" {
  description = "Network details for this VM (backwards compat)."
  value = {
    vnet      = azurerm_virtual_network.cdb.name
    vnet_id   = azurerm_virtual_network.cdb.id
    subnet    = azurerm_subnet.cdb.name
    subnet_id = azurerm_subnet.cdb.id
    nsg       = azurerm_network_security_group.cdb.name
  }
}
