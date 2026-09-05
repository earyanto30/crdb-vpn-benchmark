# ── Resource Group (shared across all VMs) ───────────────────────────────────
# Resources in Azure can reside in any region regardless of the RG location.
resource "azurerm_resource_group" "cdb" {
  name     = var.resource_group_name
  location = var.rg_location
  tags     = var.tags
}

# ── Shared Storage Account for Boot Diagnostics ──────────────────────────────
# Persists boot logs and serial console output outside the per-VM lifecycle
resource "azurerm_storage_account" "diag" {
  name                     = "crdbvpnbenchdiag"
  resource_group_name      = azurerm_resource_group.cdb.name
  location                 = azurerm_resource_group.cdb.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = var.tags
}
