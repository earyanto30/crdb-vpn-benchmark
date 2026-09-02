# ── Per-VM Virtual Network ─────────────────────────────────────────────────────
# Each VM lives in its own region, so it gets its own VNet.
resource "azurerm_virtual_network" "cdb" {
  name                = "vnet-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

# ── Per-VM Subnet ──────────────────────────────────────────────────────────────
resource "azurerm_subnet" "cdb" {
  name                 = "snet-${var.name}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.cdb.name
  address_prefixes     = [var.subnet_prefix]
}

# ── Per-VM Network Security Group ──────────────────────────────────────────────
resource "azurerm_network_security_group" "cdb" {
  name                = "nsg-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-wireguard"
    priority                   = 105
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "51820"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-cockroachdb"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["26257", "8080"]
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "cdb" {
  subnet_id                 = azurerm_subnet.cdb.id
  network_security_group_id = azurerm_network_security_group.cdb.id
}
