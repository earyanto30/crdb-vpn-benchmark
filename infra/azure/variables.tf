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
