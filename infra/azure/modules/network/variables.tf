variable "name" {
  description = "VM name (prefixes VNet/Subnet/NSG names)."
  type        = string
}

variable "location" {
  description = "Azure region for networking resources."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the shared Azure resource group."
  type        = string
}

variable "address_space" {
  description = "CIDR address space for this VM's VNet."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_prefix" {
  description = "CIDR prefix for this VM's subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
