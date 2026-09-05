variable "rg_location" {
  description = "Azure region for the shared resource group metadata."
  type        = string
  default     = "southeastasia"
}

variable "resource_group_name" {
  description = "Name of the shared Azure resource group."
  type        = string
  default     = "rg-crdbvpnbench-dev"
}

variable "vm_size" {
  description = "Azure VM size applied to all instances."
  type        = string
  default     = "Standard_F2s_v2"
}

variable "admin_username" {
  description = "OS-level admin username created on each VM."
  type        = string
  default     = "evan"
}

variable "ssh_public_key" {
  description = "SSH public key to authorise for the admin user."
  type        = string
  sensitive   = true
}

variable "os_disk_size_gb" {
  description = "OS disk size in GiB."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    project = "cockroachdb-replication"
    env     = "dev"
  }
}

variable "ssh_private_key_path" {
  description = "Local path to the SSH private key used by Ansible to connect to VMs."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "spot_enabled" {
  description = "Enable Azure Spot discount for all VMs. Per-VM toggle via spot_enabled in vm-*.tf (true=Spot 60-90% discount, evictable)."
  type        = bool
  default     = false
}

variable "spot_eviction_policy" {
  description = "Spot eviction policy for all Spot VMs: Deallocate (keep OS disk for restore) or Delete."
  type        = string
  default     = "Deallocate"
}

variable "spot_max_bid_price" {
  description = "Max Spot price USD/hr for all VMs, -1 = pay-as-you-go (no cap, up to Regular price)."
  type        = number
  default     = -1
}
