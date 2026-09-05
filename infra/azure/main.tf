# ── Resource Group (shared across all VMs) ───────────────────────────────────
# Resources in Azure can reside in any region regardless of the RG location.
resource "azurerm_resource_group" "cdb" {
  name     = var.resource_group_name
  location = var.rg_location
  tags     = var.tags
}
