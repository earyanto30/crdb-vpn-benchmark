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

### Retrieving Boot Diagnostics Logs

Azure VM boot diagnostics allow you to inspect the VM console output and boot log:

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

---

## In-Place Baseline Reset Mechanism

Between benchmark scenarios, `scripts/run.sh` executes [`playbook/reset-baseline.yml`](playbook/reset-baseline.yml) across all nodes concurrently rather than performing slow and risky OS disk swaps or VM deallocations.

### Why In-Place Reset:
- **Zero Spot VM Eviction Risk**: VMs remain continuously running, eliminating the danger of losing Spot compute capacity during deallocation in competitive Azure regions.
- **Blazing Fast**: Takes **~10–15 seconds** total instead of 3–5 minutes for cloud disk snapshots.
- **Complete Reversion**:
  - Stops and disables `cockroachdb`, `wg-quick@wg0`, and `wireguard-go` systemd services.
  - Force terminates any remaining background processes.
  - Deletes `wg0` network interfaces and cleans WireGuard iptables forwarding rules.
  - Wipes `/var/lib/cockroach` (database data & store), `/etc/cockroach` (certificates & CA keys), and `/etc/wireguard`.
  - Wipes workload driver results, histograms, and driver client certificates.
  - Clears controller-side local temporary staging keys and certificates.
