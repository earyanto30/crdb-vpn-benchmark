locals {
  # Single source of truth for all nodes. To add a new VM, add one entry here
  # and create its corresponding vm-crdb-*.tf module file.
  #
  # Naming (rg-crdbvpnbench-dev):
  #   vm-crdb-lease-sea-01   — CRDB leaseholder n1 (SEA, WireGuard server / crdb_main)
  #   vm-crdb-replica-ea-01  — CRDB replica n2 (EA, peer / crdb_join)
  #   vm-crdb-driver-sea-01  — workload driver (co-located SEA, WireGuard peer only)
  crdb_nodes = {
    "vm-crdb-lease-sea-01"  = { net = module.net_lease_sea, vm = module.vm_crdb_lease_sea_01 }
    "vm-crdb-replica-ea-01" = { net = module.net_replica_ea, vm = module.vm_crdb_replica_ea_01 }
  }

  driver_nodes = {
    "vm-crdb-driver-sea-01" = { vm = module.vm_crdb_driver_sea_01 }
  }

  all_nodes = merge(local.crdb_nodes, {
    for k, v in local.driver_nodes : k => { net = module.net_lease_sea, vm = v.vm }
  })

  server_name     = "vm-crdb-lease-sea-01"
  crdb_peer_names = [for n in sort(keys(local.crdb_nodes)) : n if n != local.server_name]
  wg_peer_names   = local.crdb_peer_names

  cockroach_hosts = {
    for name, pair in local.crdb_nodes : name => {
      ansible_host = coalesce(pair.vm.compute.fqdn, pair.vm.compute.public_ip)
      ansible_user = pair.vm.compute.admin_username
      public_ip    = pair.vm.compute.public_ip
      fqdn         = pair.vm.compute.fqdn
      location     = pair.vm.compute.location
    }
  }

  driver_hosts = {
    for name, pair in local.driver_nodes : name => {
      ansible_host = coalesce(pair.vm.compute.fqdn, pair.vm.compute.public_ip)
      ansible_user = pair.vm.compute.admin_username
      public_ip    = pair.vm.compute.public_ip
      fqdn         = pair.vm.compute.fqdn
      location     = pair.vm.compute.location
    }
  }
}

output "ansible_inventory" {
  description = "YAML-format Ansible inventory for the CockroachDB hosts."
  value = yamlencode({
    all = {
      children = {
        cockroachdb = {
          hosts = local.cockroach_hosts
          vars = {
            ansible_ssh_private_key_file = var.ssh_private_key_path
            ansible_ssh_common_args      = "-o StrictHostKeyChecking=no"
          }
        }
        workload_driver = {
          hosts = local.driver_hosts
          vars = {
            ansible_ssh_private_key_file = var.ssh_private_key_path
            ansible_ssh_common_args      = "-o StrictHostKeyChecking=no"
          }
        }
        driver = {
          hosts = local.driver_hosts
          vars = {
            ansible_ssh_private_key_file = var.ssh_private_key_path
            ansible_ssh_common_args      = "-o StrictHostKeyChecking=no"
          }
        }
        wireguard_server = {
          hosts = {
            for name in [local.server_name] : name => {}
          }
        }
        wireguard_peers = {
          hosts = {
            for name in local.wg_peer_names : name => {}
          }
        }
        crdb_main = {
          hosts = {
            for name in [local.server_name] : name => {}
          }
        }
        crdb_join = {
          hosts = {
            for name in local.crdb_peer_names : name => {}
          }
        }
      }
    }
  })
}
