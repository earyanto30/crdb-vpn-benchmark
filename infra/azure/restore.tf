# ── Restore VM OS disk from snapshot via OpenTofu (tofu) ───────────────────────
# Usage (incremental snapshot snap-<vm-name> created by modules/compute/main.tf:75):
#   tofu init
#   tofu apply -var="restore_enabled=true" -var="restore_vm_name=vm-crdb-lease-sea-01"
#   # or define in terraform.tfvars: restore_enabled = true / restore_vm_name = "vm-crdb-lease-sea-01"
#   # To list snapshots: tofu state show 'module.vm_crdb_lease_sea_01.azurerm_snapshot.os_disk[0]'
#   # To force snapshot recreation before restore: tofu taint 'module.vm_crdb_lease_sea_01.azurerm_snapshot.os_disk[0]'
#
# This uses null_resource + local-exec with `az` CLI so `tofu apply` is the single
# remote entrypoint (no manual ssh). Requires `az login` and `az` CLI on the
# machine running tofu.

variable "restore_enabled" {
  description = "Set true to restore VM OS disk from snapshot snap-<restore_vm_name>."
  type        = bool
  default     = false
}

variable "restore_vm_name" {
  description = "VM name to restore (must match var.name of a compute module, e.g. vm-crdb-lease-sea-01)."
  type        = string
  default     = "vm-crdb-lease-sea-01"
}

variable "restore_snapshot_name" {
  description = "Override snapshot name. Empty => snap-<restore_vm_name> (default from modules/compute)."
  type        = string
  default     = ""
}

locals {
  _restore_snap_name = var.restore_snapshot_name != "" ? var.restore_snapshot_name : "snap-${var.restore_vm_name}"
}

# Existing snapshot (created by modules/compute)
data "azurerm_snapshot" "restore_src" {
  count               = var.restore_enabled ? 1 : 0
  name                = local._restore_snap_name
  resource_group_name = azurerm_resource_group.cdb.name
}

# Create new managed disk from snapshot (Copy, incremental → full)
resource "azurerm_managed_disk" "restore_disk" {
  count                = var.restore_enabled ? 1 : 0
  name                 = "restored-${var.restore_vm_name}-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  location             = local.all_nodes[var.restore_vm_name].vm.compute.location
  resource_group_name  = azurerm_resource_group.cdb.name
  storage_account_type = "Premium_LRS"
  create_option        = "Copy"
  source_resource_id   = data.azurerm_snapshot.restore_src[0].id
  tags                 = var.tags

  # ignore name/tags changes so timestamp() doesn't force recreation on every apply
  lifecycle {
    ignore_changes = [name, tags]
  }
}

# Swap OS disk remotely via `az` (VM must be deallocated). Triggered only when restore_enabled.
resource "null_resource" "restore_swap" {
  count = var.restore_enabled ? 1 : 0
  triggers = {
    snapshot_id = data.azurerm_snapshot.restore_src[0].id
    disk_id     = azurerm_managed_disk.restore_disk[0].id
    vm_name     = var.restore_vm_name
  }

  provisioner "local-exec" {
    # Deallocate → swap OS disk → start. Uses `az` CLI credentials from `az login`.
    command     = <<-EOT
      set -euo pipefail
      RG="${azurerm_resource_group.cdb.name}"
      VM="${var.restore_vm_name}"
      DISK_ID="${azurerm_managed_disk.restore_disk[0].id}"
      echo "[restore] Deallocating $VM in $RG..."
      az vm deallocate -g "$RG" -n "$VM" --no-wait || az vm deallocate -g "$RG" -n "$VM"
      # wait until deallocated
      echo "[restore] Waiting for deallocation..."
      az vm wait -g "$RG" -n "$VM" --custom "instanceView.statuses[?code=='PowerState/deallocated']" 2>/dev/null || sleep 10
      echo "[restore] Swapping OS disk to $DISK_ID..."
      az vm update -g "$RG" -n "$VM" --os-disk "$DISK_ID" 2>&1 | tail -n 20
      echo "[restore] Starting $VM..."
      az vm start -g "$RG" -n "$VM" --no-wait
      echo "[restore] Done — check: az vm show -g $RG -n $VM --show-details --query powerState -o tsv"
    EOT
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [azurerm_managed_disk.restore_disk]
}

output "restore_snapshot_id" {
  description = "Snapshot used for restore (when restore_enabled)."
  value       = try(data.azurerm_snapshot.restore_src[0].id, null)
}

output "restore_disk_id" {
  description = "New managed disk created from snapshot (when restore_enabled)."
  value       = try(azurerm_managed_disk.restore_disk[0].id, null)
}
