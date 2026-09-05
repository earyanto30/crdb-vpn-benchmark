variable "name" {
  description = "VM name (becomes the VM resource name and prefixes for derived resources)."
  type        = string
}

variable "location" {
  description = "Azure region for this VM."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the shared Azure resource group."
  type        = string
}

variable "subnet_id" {
  description = "ID of the subnet to attach the NIC to (from network module)."
  type        = string
}

variable "vm_size" {
  description = "Azure VM size."
  type        = string
}

variable "admin_username" {
  description = "OS-level admin username created on the VM."
  type        = string
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
  default     = {}
}

variable "spot_enabled" {
  description = "Enable Azure Spot discount for this VM (true=Spot, false=Regular). Toggle per-VM."
  type        = bool
  default     = false
}

variable "spot_eviction_policy" {
  description = "Spot eviction policy: Deallocate (keep disk) or Delete (ephemeral)."
  type        = string
  default     = "Deallocate"
  validation {
    condition     = contains(["Deallocate", "Delete"], var.spot_eviction_policy)
    error_message = "spot_eviction_policy must be Deallocate or Delete."
  }
}

variable "spot_max_bid_price" {
  description = "Max spot price in USD/hr, -1 means pay-as-you-go (no cap)."
  type        = number
  default     = -1
}
