output "compute" {
  description = "Key connection details for this VM."
  value = {
    hostname       = azurerm_linux_virtual_machine.cdb.name
    location       = azurerm_linux_virtual_machine.cdb.location
    public_ip      = azurerm_public_ip.cdb.ip_address
    fqdn           = azurerm_public_ip.cdb.fqdn
    dns_label      = azurerm_public_ip.cdb.domain_name_label
    private_ip     = azurerm_network_interface.cdb.private_ip_address
    admin_username = azurerm_linux_virtual_machine.cdb.admin_username
    vm_size        = azurerm_linux_virtual_machine.cdb.size
  }
}

# Backwards compat alias for older root outputs that expected .connection
output "connection" {
  description = "Alias for compute ( backwards compat )."
  value = {
    hostname       = azurerm_linux_virtual_machine.cdb.name
    location       = azurerm_linux_virtual_machine.cdb.location
    public_ip      = azurerm_public_ip.cdb.ip_address
    fqdn           = azurerm_public_ip.cdb.fqdn
    dns_label      = azurerm_public_ip.cdb.domain_name_label
    private_ip     = azurerm_network_interface.cdb.private_ip_address
    admin_username = azurerm_linux_virtual_machine.cdb.admin_username
    vm_size        = azurerm_linux_virtual_machine.cdb.size
  }
}
