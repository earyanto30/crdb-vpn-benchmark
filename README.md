# CockroachDB Cross-Region Replication & VPN Benchmark

This repository benchmarks CockroachDB cross-region replication performance under three distinct network architectures across Azure regions:
1. **Direct Scenario**: Inter-node replication traffic travels across the public internet with direct routing.
2. **Kernel WireGuard Scenario**: Inter-node replication traffic is routed and encrypted through Linux kernel WireGuard tunnels.
3. **Userspace WireGuard-Go Scenario**: Inter-node replication traffic is routed and encrypted through userspace `wireguard-go` tunnels.

---

## Architecture & Infrastructure

- **Multi-Region Azure Topology**:
  - `vm-crdb-lease-sea-01` (`n1`): Southeast Asia (Singapore) — Primary leaseholder node & WireGuard server.
  - `vm-crdb-replica-ea-01` (`n2`): East Asia (Hong Kong) — Replica node & WireGuard peer.
  - `vm-crdb-replica-japaneast-01` (`n3`): Japan East (Tokyo) — Replica node & WireGuard peer.
  - `vm-crdb-driver-sea-01`: Southeast Asia (Singapore) — Dedicated workload benchmark driver co-located with `n1`.
- **Infrastructure as Code**: OpenTofu (`infra/azure/`).
- **Configuration Management**: Ansible playbooks (`playbook/`).
- **End-to-End Orchestrator**: `scripts/run.sh`.

---

## Running the Benchmark Pipeline

The entire benchmark pipeline across all three scenarios is automated by [`scripts/run.sh`](scripts/run.sh).

### Prerequisites
- OpenTofu (`tofu`) >= 1.6.0
- Ansible (`ansible-playbook`)
- Azure CLI (`az`) authenticated with `az login`
- Python 3 with `pyyaml` (`pip install pyyaml`)
- SSH key pair configured in `~/.ssh/id_ed25519` (or specified in `infra/azure/terraform.tfvars`)

### Execution
Run the orchestrator script:
```bash
./scripts/run.sh
```

### State Checkpointing & Resume
The orchestrator maintains an execution checkpoint file (`.pipeline_state`). If interrupted (e.g. network disconnect or machine reboot), simply rerun:
```bash
./scripts/run.sh
```
The script will resume from the last incomplete step.

To discard previous state and start fresh from Step 1:
```bash
./scripts/run.sh --reset
```

> [!NOTE]
> `scripts/run.sh` validates local state against Azure reality on startup. If `.pipeline_state` claims that infrastructure was provisioned (`tofu_apply`) but no VMs exist in Azure (e.g. destroyed out-of-band), the script will safely halt and prompt you to run `./scripts/run.sh --reset`.

---

## Troubleshooting & Boot Diagnostics

### Persistent Boot Diagnostics Storage
VM boot diagnostics are configured to write to a dedicated, shared storage account (`crdbvpnbenchdiag`) defined in `infra/azure/main.tf`. Because this storage account exists outside the lifecycle of individual VMs, boot logs and serial console output are preserved across disk swaps, OS restores, and VM deallocations.

### Retrieving Boot Diagnostics Logs

#### 1. When the VM exists in Azure (running or deallocated)
Azure CLI automatically reads the VM's diagnostic profile to determine where logs are stored. No special flags are required for named vs. Azure-managed storage accounts:

```bash
# Get serial console / boot log for a specific VM
az vm boot-diagnostics get-boot-log \
  --resource-group rg-crdbvpnbench-dev \
  --name vm-crdb-lease-sea-01

# Retrieve boot logs for all VMs in the resource group
for vm in vm-crdb-lease-sea-01 vm-crdb-replica-ea-01 vm-crdb-replica-japaneast-01 vm-crdb-driver-sea-01; do
  echo "=== Boot Log for $vm ==="
  az vm boot-diagnostics get-boot-log -g rg-crdbvpnbench-dev -n "$vm"
done
```

#### 2. When the VM has been destroyed or is unreachable via ARM
Even if a VM resource has been destroyed or deleted, the boot diagnostics logs remain stored as blobs in the `crdbvpnbenchdiag` storage account:

```bash
# List all diagnostic blob containers in the persistent storage account
az storage container list \
  --account-name crdbvpnbenchdiag \
  --auth-mode login \
  --query "[].name" -o tsv

# Container names follow the format: bootdiagnostics-<vm_name>-<vm_id>
# Download the raw serial console log:
az storage blob download \
  --account-name crdbvpnbenchdiag \
  --container-name "bootdiagnostics-vm-crdb-lease-sea-01-<uuid>" \
  --name "vm-crdb-lease-sea-01.<uuid>.console.log" \
  --file "lease-sea-01-console.log" \
  --auth-mode login
```

---

## Snapshot & Restore Mechanism

Between benchmark scenarios, `scripts/run.sh` restores each node's OS disk back to a clean baseline snapshot using Azure CLI (`az`).

### SSH-Readiness Gating
To prevent capturing snapshots during early guest OS boot (before `sshd` is active and SSH host keys have been generated), `infra/azure/modules/compute/main.tf` introduces an explicit readiness gate:
- `null_resource.wait_for_ssh` attempts SSH connectivity for up to 300 seconds.
- `azurerm_snapshot.os_disk` explicitly depends on `null_resource.wait_for_ssh`.
- If SSH does not become ready within 300 seconds, provisioning fails loudly rather than capturing an unbooted or unreachable OS disk.
