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

variable "create_snapshot" {
  description = "Create incremental snapshot of OS disk after VM creation."
  type        = bool
  default     = true
}
